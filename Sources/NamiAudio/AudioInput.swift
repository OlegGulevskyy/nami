@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import NamiCore

public enum AudioInputError: Error, LocalizedError {
    case permissionDenied, invalidFormat, conversionFailed, overflow, tooLong, deviceUnavailable, deviceSelectionFailed
    public var errorDescription: String? {
        switch self {
        case .permissionDenied: "Enable microphone access for Nami (or your terminal when using the CLI) in System Settings → Privacy & Security → Microphone."
        case .invalidFormat: "No usable audio input format."
        case .conversionFailed: "Audio conversion failed."
        case .overflow: "Audio consumer fell behind; recording was cancelled rather than dropping samples."
        case .tooLong: "Use a recording no longer than 60 seconds."
        case .deviceUnavailable: "Your selected microphone is unavailable. Reconnect it or choose another microphone."
        case .deviceSelectionFailed: "Could not use the selected microphone. Reconnect it or choose another microphone."
        }
    }
}

/// Converter is used serially on the audio tap, or synchronously by file loading.
private final class PCMConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let output: AVAudioFormat
    init(input: AVAudioFormat) throws {
        guard input.sampleRate > 0, input.channelCount > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                  sampleRate: AudioChunk.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output)
        else { throw AudioInputError.invalidFormat }
        self.output = output
        self.converter = converter
        converter.downmix = true
    }

    func convert(_ input: AVAudioPCMBuffer?, end: Bool = false) throws -> [Float] {
        let supplied = SampleCursor()
        var samples: [Float] = []
        while true {
            let capacity: AVAudioFrameCount = 4096
            guard let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else {
                throw AudioInputError.conversionFailed
            }
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { _, state in
                if supplied.count == 0, let input {
                    supplied.count = 1
                    state.pointee = .haveData
                    return input
                }
                state.pointee = end ? .endOfStream : .noDataNow
                return nil
            }
            if let error { throw error }
            if let channel = buffer.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            }
            switch status {
            case .error: throw AudioInputError.conversionFailed
            case .inputRanDry, .endOfStream: return samples
            case .haveData: continue
            @unknown default: throw AudioInputError.conversionFailed
            }
        }
    }
}

public enum AudioFile {
    public static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard Double(file.length) / file.processingFormat.sampleRate <= 60 else { throw AudioInputError.tooLong }
        let converter = try PCMConverter(input: file.processingFormat)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else {
            throw AudioInputError.invalidFormat
        }
        var samples: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            samples += try converter.convert(buffer)
        }
        samples += try converter.convert(nil, end: true)
        return samples
    }

    public static func write(_ samples: [Float], to url: URL) throws {
        guard !samples.isEmpty else { throw EngineError.noAudio }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioChunk.sampleRate,
                                   channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw AudioInputError.invalidFormat }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
        try file.write(from: buffer)
    }
}

/// Bounded stream; copies tap-owned memory before handing samples to consumers.
/// No audio is persisted. The caller must stop on completion, error or cancellation.
@MainActor
public protocol AudioCapturing: AnyObject {
    var inputDescription: String { get }
    func start() async throws -> AsyncThrowingStream<AudioChunk, Error>
    func stop()
}

@MainActor
public final class MicrophoneCapture: AudioCapturing {
    public private(set) var inputDescription = "Unknown microphone"
    private let engine = AVAudioEngine()
    private var continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation?
    private var installed = false
    private var converter: PCMConverter?
    private var cursor: SampleCursor?
    private let deviceUID: String?
    public init(deviceUID: String? = nil) { self.deviceUID = deviceUID }

    public static func defaultDeviceName() -> String {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
            return "System default microphone"
        }
        return name(of: device)
    }

    public func start() async throws -> AsyncThrowingStream<AudioChunk, Error> {
        guard !installed else { throw EngineError.invalidState }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw AudioInputError.permissionDenied }
        let input = engine.inputNode
        if let deviceUID {
            var device = try AudioInputDevice.deviceID(for: deviceUID)
            guard let unit = input.audioUnit,
                  AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                      kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
                throw AudioInputError.deviceSelectionFailed
            }
        }
        let format = input.outputFormat(forBus: 0)
        inputDescription = "\(Self.deviceName(input)): \(Int(format.sampleRate)) Hz, \(format.channelCount) channel(s)"
        let pair = AsyncThrowingStream<AudioChunk, Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        continuation = pair.continuation
        try installTap(on: input, format: format, continuation: pair.continuation)
        installed = true
        do { try engine.start() } catch { stop(); throw error }
        return pair.stream
    }

    /// Kept separate so tests can drive the exact installed callback from an
    /// audio-style background queue without microphone access or a running engine.
    func installTap(on node: AVAudioNode, format: AVAudioFormat,
                    continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation) throws {
        self.continuation = continuation
        let converter = try PCMConverter(input: format)
        // AVAudioEngine serializes callbacks for this tap.
        let cursor = SampleCursor()
        self.converter = converter
        self.cursor = cursor
        // AVAudioEngine calls this Objective-C block on its audio queue. Explicit
        // Sendable prevents it inheriting MainActor isolation from registration;
        // otherwise Swift traps on the first buffer with dispatch_assert_queue.
        // Captures are tap-owned state and a thread-safe stream continuation;
        // never capture the MainActor-isolated MicrophoneCapture instance here.
        node.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable buffer, _ in
            do {
                let samples = try converter.convert(buffer)
                guard !samples.isEmpty else { return }
                let chunk = AudioChunk(samples: samples, timestamp: Double(cursor.count) / AudioChunk.sampleRate)
                cursor.count += samples.count
                if case .dropped = continuation.yield(chunk) {
                    continuation.finish(throwing: AudioInputError.overflow)
                }
            } catch { continuation.finish(throwing: error) }
        }
    }

    public func stop() {
        engine.stop()
        if installed { engine.inputNode.removeTap(onBus: 0); installed = false }
        // The tap has stopped; drain the resampler's remaining frames before EOF.
        if let converter, let cursor, let continuation {
            do {
                let tail = try converter.convert(nil, end: true)
                if !tail.isEmpty {
                    if case .dropped = continuation.yield(AudioChunk(samples: tail,
                        timestamp: Double(cursor.count) / AudioChunk.sampleRate)) {
                        continuation.finish(throwing: AudioInputError.overflow)
                    }
                }
            } catch { continuation.finish(throwing: error) }
        }
        continuation?.finish()
        continuation = nil
        converter = nil
        cursor = nil
    }

    private static func deviceName(_ input: AVAudioInputNode) -> String {
        guard let unit = input.audioUnit else { return "Unknown microphone" }
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &device, &size) == noErr else { return "Unknown microphone" }
        return name(of: device)
    }

    private static func name(of device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let result = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard result == noErr,
              let name else { return "Unknown microphone" }
        return name as String
    }
}

private final class SampleCursor: @unchecked Sendable { var count = 0 }
