import Foundation
import MLX
import MLXLMCommon

/// Verifies proposed copied text with the cleanup model. A proposal never becomes
/// output unless the model's own sampler selects it; the first disagreement is
/// emitted normally and all later speculative cache entries are discarded.
enum DraftGeneration {
    /// Access only inside the owning ModelContainer's serialized `perform`.
    /// Reuse causal input keys only; earlier answer tokens are just proposals.
    final class PromptCache: @unchecked Sendable {
        fileprivate var layers: [KVCache]?
        fileprivate var tokens: [Int] = []
        fileprivate var draft: [Int] = []
    }

    static func generate(input: LMInput, draft: [Int], parameters: GenerateParameters,
                         context: ModelContext, sampler suppliedSampler: (any LogitSampler)? = nil, blockSize: Int = 4,
                         promptCache: PromptCache? = nil) throws -> GenerateResult {
        precondition(parameters.kvBits == nil)
        let model = context.model
        let previousDraft = promptCache?.draft ?? []
        let cache = promptCache?.layers ?? model.newCache(parameters: parameters)
        precondition(cache.allSatisfy(\.isTrimmable))
        precondition(input.image == nil && input.video == nil && cache.allSatisfy { $0.maxSize == nil })
        let inputTokens = input.text.tokens.asArray(Int.self)
        var shared = 0
        if let promptCache {
            let available = min(inputTokens.count - 1, cache.map(\.offset).min() ?? 0)
            for (previous, next) in zip(promptCache.tokens, inputTokens) {
                guard previous == next, shared < available else { break }
                shared += 1
            }
            for layer in cache { _ = layer.trim(layer.offset - shared) }
            // If prefill fails, none of the newly claimed prefix can be reused.
            promptCache.tokens = []; promptCache.layers = cache
        }
        let sampler = suppliedSampler ?? parameters.sampler()
        var processor = parameters.processor()
        processor?.prompt(input.text.tokens)
        func sample(_ logits: MLXArray) -> Int {
            let adjusted = processor?.process(logits: logits) ?? logits
            let token = sampler.sample(logits: adjusted)
            processor?.didSample(token: token)
            return token.item(Int.self)
        }
        let started = ContinuousClock.now
        let logits: MLXArray
        let remaining = LMInput(text: input.text[shared...])
        switch try model.prepare(remaining, cache: cache, windowSize: parameters.prefillStepSize) {
        case .tokens(let remainder): logits = model(remainder[text: .newAxis], cache: cache, state: nil).logits
        case .logits(let output): logits = output.logits
        }
        var next = sample(logits[0..., -1, 0...])
        promptCache?.tokens = inputTokens
        let promptTime = elapsed(started)
        let generationStart = ContinuousClock.now
        let eos = Set(context.configuration.extraEOSTokens.compactMap { context.tokenizer.convertTokenToId($0) })
        func isEnd(_ token: Int) -> Bool {
            token == context.tokenizer.eosTokenId || token == context.tokenizer.unknownTokenId || eos.contains(token)
        }
        var tokens: [Int] = []
        let limit = parameters.maxTokens ?? 2048
        defer { Stream().synchronize() }
        while tokens.count < limit, !isEnd(next) {
            try Task.checkCancellation()
            tokens.append(next)
            guard tokens.count < limit else { break }
            let proposalLimit = min(blockSize, limit - tokens.count - 1)
            let previous = continuation(after: tokens, in: previousDraft, limit: proposalLimit)
            let proposal = previous.isEmpty ? continuation(after: tokens, in: draft, limit: proposalLimit) : previous
            let output = model(MLXArray([next] + proposal)[.newAxis], cache: cache)
            var accepted = 0
            // Sample only the prefix actually consumed, in the same order and
            // shape as ordinary generation. Discarded proposals must not advance
            // the RNG or repetition context (including for seeded requests).
            for index in 0...proposal.count {
                next = sample(output[0..., index, 0...])
                guard index < proposal.count, next == proposal[index], !isEnd(next) else { break }
                tokens.append(next)
                accepted += 1
            }
            // Each layer owns its cache offset; trimming just one leaves a
            // plausible-looking but incorrect continuation in subsequent layers.
            for layer in cache { _ = layer.trim(proposal.count - accepted) }
        }
        try Task.checkCancellation()
        promptCache?.draft = tokens
        return GenerateResult(inputText: input.text, tokens: tokens, output: context.tokenizer.decode(tokens: tokens),
            promptTime: promptTime, generateTime: elapsed(generationStart))
    }

    static func continuation(after output: [Int], in draft: [Int], limit: Int) -> [Int] {
        guard limit > 0, !output.isEmpty else { return [] }
        for length in stride(from: min(4, output.count), through: 1, by: -1) {
            guard draft.count >= length else { continue }
            let suffix = output.suffix(length)
            for index in 0...(draft.count - length) where draft[index..<(index + length)].elementsEqual(suffix) {
                let start = index + length
                if start < draft.count { return Array(draft[start..<min(draft.count, start + limit)]) }
            }
        }
        return []
    }

    private static func elapsed(_ start: ContinuousClock.Instant) -> Double {
        let d = start.duration(to: .now).components
        return Double(d.seconds) + Double(d.attoseconds) / 1e18
    }
}
