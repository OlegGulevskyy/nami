# Transcription comparison and agent workflow

## Vocabulary truncation regression (28 September 2026)

A saved 47.67-second recording returned only a few words with vocabulary hints,
while the same audio produced a full paragraph without hints. This reproduced
through `WhisperKitEngine`, independently of capture, history, or text cleanup.
Enabling timestamps alone still dropped speech on repeated runs. WhisperKit
1.1.0's multilingual timestamp filter searches only the first three prompt tokens
for the task token; vocabulary shifts that token beyond the search. Nami now
keeps segment timestamps and supplies the filter with the actual prompt boundary.
The displayed transcript still excludes special tokens and timestamps.

Run the opt-in regression with a local model, a recording longer than 30 seconds,
and a text file containing at least three expected phrases, one per line, spanning
the beginning, middle, and end. It checks cold and repeated prompted runs and
switching vocabulary off on the same engine. It never opens the microphone,
changes history, copies text, or uploads audio. Keep private fixtures out of Git.

```sh
NAMI_TEST_MODEL_FOLDER='/path/to/local/model' \
NAMI_TEST_LONG_AUDIO_FILE='/path/to/recording.wav' \
NAMI_TEST_EXPECTED_PHRASES_FILE='/path/to/phrases.txt' \
NAMI_TEST_VOCABULARY='Example product, Example company' \
swift test --filter longTranscriptionPreservesSpeechWithVocabularyAndWarmReuse
```

## Baseline choice (27 September 2026)

Start with **ElevenLabs Scribe v2**, an accessible, strong prerecorded-audio
baseline with word timestamps. This is a practical choice, not a claim that it
wins every language, accent or domain. The [Artificial Analysis non-streaming
leaderboard](https://artificialanalysis.ai/speech-to-text/non-streaming) currently
reports Scribe v2 at 2.2% AA-WER, Microsoft MAI-Transcribe-2 at 2.0%, and
StepAudio 3 ASR / Fun-Realtime-ASR-preview at 1.7%. Those benchmark results are
not estimates of accuracy on Nami's recordings. Compare on your actual speech.

The [Scribe API](https://elevenlabs.io/docs/api-reference/speech-to-text/convert)
uses `scribe_v2`, word timestamps, verbatim mode (`no_verbatim=false`), no audio
event tags, no diarization, temperature 0 and the sample's language (omitted for
auto-detection). Neither the expected text nor vocabulary is sent as a hint.
Local comparison also uses its existing unprompted baseline. The API alias may
change server-side; retain run dates and cached responses when testing changes.
The saved response includes transcript, detected language and word timestamps.

## In the app

1. Open **Playground**, select a saved sample or use **From History…**.
2. Choose your local model in **Settings**. The selection saves with the workspace
   and is restored when Nami restarts.
3. Enter an ElevenLabs API key in **Settings**. Changes save immediately to macOS
   Keychain; the key is never saved in configuration, reports or the workspace.
   A saved value takes precedence over `ELEVENLABS_API_KEY`; clearing the field
   remembers an empty value. Without a saved value, the environment key is used.
   The CLI continues to use `ELEVENLABS_API_KEY` without accessing Keychain.
4. Click **Compare selected with cloud…**. Review the sample duration and confirm
   the upload/paid request. It transcribes the same WAV with Scribe and selected
   local models. Cloud results and local results appear together with differences.
5. Listen and enter the words actually spoken, including corrections and fillers.
   Mark **Reference verified by listening** before running scored comparisons.
   A verified empty reference means silence. Editing the text clears verification.
6. Use **Export benchmark JSON** for a report with audio paths and every saved run.

The normal **Compare** and **Compare all** buttons remain local. Selecting a sample
never triggers a cloud upload. Repeating a cloud comparison sends a new request;
there are no automatic paid retries. Cancellation discards late results but cannot
undo an already received request or its provider charges. Local runs continue if
cloud transcription fails, and every failed attempt remains visible.

## Agent commands

Run from the checkout. Close the app before CLI writes and reopen it afterward;
the store rejects writes from a stale process rather than overwriting another
process's results. Reports can be read while the app is open.

```sh
# Read-only inventory and report; includes absolute audio paths and sample UUIDs.
swift run nami-lab report > /tmp/nami-before.json

# Run one local model against a chosen saved recording.
swift run nami-lab run --sample SAMPLE_UUID --model /path/to/whisperkit-model > /tmp/nami-after.json

# Run all saved samples through enabled local models.
swift run nami-lab run --all > /tmp/nami-local.json

# Save a reference checked against the original audio.
swift run nami-lab reference --sample SAMPLE_UUID --text-file /tmp/reference.txt --verified --category negation

# Only after the user approves the concrete batch and provider charges:
# Set ELEVENLABS_API_KEY securely in the invoking environment (not in command arguments).
swift run nami-lab run --sample SAMPLE_UUID --cloud --allow-cloud > /tmp/nami-cloud.json
```

All commands accept `--workspace PATH`; the default is
`~/Library/Application Support/Nami/InternalDebugging`. `--model` affects this
invocation without changing the app's saved model selection. A cloud run also
runs enabled local models (or the explicitly selected `--model`). `--all --cloud`
requires approval for the entire batch. Before requesting approval, inventory its
sample IDs, audio durations, model choice and expected provider charges. Do not
use `--allow-cloud` merely because a general improvement task was authorized.

The `report` command prints JSON to stdout without modifying the workspace.
`run` and `reference` persist changes to `workspace.json` and print the same report
schema. Operational/setup errors exit nonzero; per-model transcription failures
are retained in `results[].run.error` and `summaries[].failures` so partial batches
remain inspectable. An agent must inspect these fields, not just the exit code.
`benchmark.json` is an explicit export snapshot; regenerate it after changes.
Existing version-1 workspaces load unchanged; old references remain unverified.

## What to inspect

- **WER, substitutions/deletions/insertions and alignment:** find missing negations,
  wrong names, repeated words and omitted phrases. Word indices are zero-based;
  insertion/deletion indices identify a position between words on the absent side.
- **CER:** helps distinguish a small spelling error from a completely wrong word.
  Counts Unicode grapheme clusters in normalized text, including interword spaces.
- **Normalized/exact match:** separate word correctness from original formatting.
- **Cloud disagreement:** aligns cloud text to local text. Missing/extra words are
  relative to the cloud output, not evidence that the local model is wrong.
- **Paired WER delta:** local WER minus cloud WER, only for matching audio hashes,
  current reference/language/verification and verified references on both runs.
  Positive means local did worse. `sameBatch` distinguishes cached cloud comparisons.
- **Corpus WER:** sum word edits / sum reference words; never average percentages
  from short and long samples. Silence contributes insertions but no denominator.
- **Coverage/failures/categories:** compare the same sample IDs. A model that failed
  on difficult recordings must not appear better because those samples vanished.
- **Latency/real-time factor:** cloud time includes network round trip, local time
  excludes model loading (stored separately). Median and observed p95 summarize
  one-pass observations, not formal warmed latency measurements.

Only the latest attempt per sample/model contributes to summaries. Failed latest
attempts don't fall back to previous successes. Edited reference, language or
verification flags mark old runs stale; rerun before scoring. All historical
runs remain available for auditing. Pairing requires matching nonempty audio
SHA-256 hashes; older runs without hashes must be rerun. Samples appear even if
no model has processed them.

Normalization is versioned as `nami-words-v1`: lowercase, straightened curly
apostrophes, whitespace tokens and punctuation trimmed from token edges. It does
not equate `21` and `twenty-one`, remove internal punctuation or segment Chinese.
WER is primarily suitable for this project's English corpus and can exceed 100%.
Scores alone do not establish semantic correctness.

## Improvement loop

1. Inventory existing samples and cache a cloud baseline once per chosen recording.
2. Listen to disagreements and establish independent verbatim references. Never
   promote cloud text to verified truth without checking the audio. If listening
   is unavailable or ambiguous, leave the sample unverified and explain why.
3. Build a representative set of 20–30 real clips: names/technical terms, numbers,
   negation, corrections, short/long speech, silence, background noise and accents.
   Tag categories; retain a separate held-out set not used to tune the model.
4. Rank recurring failures by verified errors and their impact, not raw disagreement.
   Use cloud word timestamps to locate relevant audio; timestamps themselves are
   predictions, not alignment ground truth. Review uncertain regions by listening.
5. Change one local-model/decoding choice at a time, rerun local inference, and reuse
   the cached cloud baseline. Compare sample IDs and reference snapshots exactly.
6. Check held-out WER, no-correction rate, critical names/numbers/negation, failures
   and latency. Inspect regressions at the utterance level before accepting a change.
   Do not tune references or vocabulary to make a benchmark score improve.

No live cloud accuracy claim has been established by implementing this harness.
Tests use mock cloud responses and synthetic audio; an approved real-audio run is
needed to measure the actual local-versus-cloud quality gap.
