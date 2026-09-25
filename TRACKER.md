# Nami — progress tracker

Status: benchmark harness and native recording studio implemented. User has
confirmed a successful CLI recording; formal recognition evaluation and
network-denied validation remain pending.

Scope and architecture: [SPEC.md](SPEC.md).

## Next focus — cleanup and personalization

- [x] Prepare the [feature spec](SPEC-cleanup.md), [execution plan](tasks/plan.md),
  and [ordered task checklist](tasks/todo.md), 2026-09-25.
- [ ] Compare rules, Apple Foundation Models, and a small MLX candidate on the
  same verified dictations; record quality, full latency, memory, and fallbacks.
- [ ] Integrate selected local cleanup before paste, preserving original text,
  cancellation, focus checks, and deadline fallback.
- [ ] Add editable personal memory and explicit correction capture; evaluate
  learning from examples before considering fine-tuning.

No cleanup provider has been selected and no cleanup performance result or
training claim has been established. Existing POC validation remains pending.

## Steps

- [x] **0. Define POC:** local-first experiment, replaceable engine, and scope.
- [ ] **1. Prepare evaluation:** record Mac hardware, languages, three target
  apps, and 20–30 audio samples with reference transcripts.
  - Hardware recorded: MacBook Pro / M4 / 32 GB. English; T3 Code, Chrome,
    Slack confirmed by user. [Evaluation setup](evaluation/README.md) and
    [24 draft prompts](evaluation/samples.template.json) ready. Actual recordings
    and manually checked references remain outstanding.
- [ ] **2. Build harness:** engine protocol, WhisperKit adapter, model loading,
  microphone input, and latency/error/memory measurements.
  - Implemented Swift package, SDK-independent engine contract, batch WhisperKit
    adapter, explicit model/tokenizer download, AVAudioEngine capture, audio-file
    input, fake engine, and JSON benchmark reports. [Usage](README.md).
  - User confirmed the large-v3-turbo download completed; its folder exists in
    Application Support and is selected in [nami.json](nami.json). CLI commands
    use that config by default; future downloads update the stored model path.
  - User completed a live microphone run (10.10 seconds captured, 1.038 seconds
    stop-to-final). Real-model offline operation still needs network-denied
    validation before checking this step.
- [ ] **3. Evaluate local recognition:** record benchmark results; keep the
  engine, tune it, or compare an alternative using the same samples.
- [ ] **4. Build app shell:** menu bar, permission setup, configurable shortcut,
  recording indicator, and session lifecycle.
  - Native evaluation window delivered ahead of the full menu bar app at the
    user's request: timed/manual recording, real input levels, progress/status,
    model/language controls, reading prompts, file import, playback, Copy,
    optional WAV saves, and in-memory run history. Settings persist in
    `nami.json`. Configurable global toggle/start/stop shortcuts are implemented;
    shortcut assignments persist in macOS app preferences. Successful nonempty
    transcripts copy automatically. Recordings also attempt automatic paste with
    Accessibility permission and a check of the focused target.
- [ ] **5. Complete dictation:** paste, clipboard preservation, focus checks,
  cancellation, failure handling, and last-transcript recovery.
- [ ] **6. Validate POC:** trials in three target apps, quality/latency gates,
  offline operation after download, and fake-engine swap without UI changes.

## Evaluation record

Fill after running the experiment; do not infer measurements.

| Hardware / model / languages | Cold start | Warm latency median / p95 | Samples needing no word corrections | Peak memory | Decision |
| --- | --- | --- | --- | --- | --- |
| Not tested | — | — | — | — | — |

## Decisions and blockers

- Start local with WhisperKit; model choice remains provisional until measured.
- Cloud is an explicit later option if local results are unsuitable.
- WhisperKit pinned to 1.1.0; provisional model is the compressed multilingual
  `openai_whisper-large-v3-v20240930_626MB`. Hardware meets platform requirements;
  no performance claim or backend acceptance decision yet.
- Initial adapter is batch-only and reports that capability honestly. If warm
  latency is unsuitable, investigate incremental decoding before choosing a
  different local backend. The user authorized a recording studio to make
  evaluation easier before backend selection; full dictation remains later work.
- User speech recordings and verified references are needed for the benchmark.
  Draft prompts and fake-engine results are not recognition measurements.

## Implementation evidence

- Internal debugging UI simplification: removed introductory copy, repetitive
  helper labels, idle status, and duplicate sample information. Models collapse
  by default; adding models uses one menu. Result dates, loading time, language,
  and reference snapshots are available through an info button. Core controls,
  error messages, and changed-reference warnings remain visible. Debug build
  passed and normal/compact SwiftUI snapshots were inspected.

- Internal debugging, 2026-09-25: added the bottom sidebar page with independent
  recording/import/history samples, autosaved expected transcripts, candidate
  model selection and downloads, one/all-sample comparisons, WER, per-stage
  timing, failure reporting, and retained result/reference snapshots. Its files
  live in Application Support/Nami/InternalDebugging; no automatic copy/paste
  or changes to dictation settings. Eight focused tests and the full debug suite
  passed. An opt-in real-model test imported the upstream JFK fixture, compared
  the configured large-v3-turbo model, and restored the saved result: WER 0,
  2.24 s preparation and 0.99 s transcription. This is a functional single-pass
  check, not a user-speech quality or warm-latency gate. Normal/compact page
  snapshots were inspected. Live microphone and a fresh model download through
  the new UI remain manual checks. The release app rebuilt and passed Developer
  ID signature verification; CLI smoke checks passed. Cleanup model adapters are
  still pending.

- Immediate capture and startup warm-up, 2026-09-25: the app prepares the selected
  model automatically after permission setup and retains it until exit or a model
  change. Recording drains audio independently of model loading; stop saves the
  audio before waiting for transcription. Cancelling a recording cancels only its
  wait, so background warm-up survives. SDK work runs outside the main actor.
  Tests cover cold capture, complete sample ordering, bounded stream draining,
  permission recovery, failure/retry, cancellation, reuse, and stale model loads.
  Full debug suite passed (real-model check opt-in); the opt-in real-model check
  separately passed with the 11.87-second synthetic fixture. Its first audio
  arrived in 0.61 ms while debug model preparation took 68.10 s; the second run
  reused that model and finished transcription in 1.08 s. Fixture timings exclude
  real microphone startup and are not a recognition-quality evaluation. The
  release app built and passed Developer ID signature verification. Hardware
  shortcut-to-first-audio latency remains to be measured through the new local
  Startup logs.
- Startup performance experiment: with a fixed one-second fake model preparation
  and synthetic microphone, the same isolated three-run diagnostic measured a
  median recording-start delay of 1.008 s before decoupling and 0.007 s after.
  Kept the change: recording no longer depends on preparation completing, and
  correctness tests confirm the beginning of the recording is preserved.
- Automatic paste, 2026-09-25: recordings capture the foreground app and focused
  Accessibility element, then send ⌘V after successfully copying a nonempty final
  transcript. Changed focus, missing permission, held modifiers, cancellation,
  failed transcription, and failed clipboard writes prevent paste. Imports and
  manual Copy remain copy-only. Settings expose automatic paste and optional
  Accessibility setup. Apps without AX focus use an app-only guard. Clipboard
  preservation and live trials in T3 Code, Chrome, and Slack remain outstanding;
  the transcript intentionally remains on the clipboard for recovery. All 56
  tests pass; the Developer ID signed release app was rebuilt and the General
  settings and compact recording-history layouts were rendered and inspected.
- Modifier-only recording gesture, 2026-09-25: added dedicated ⌥⌘ double-tap
  start / single-tap stop handling, enabled by default. The conventional
  recorder listens for keyDown events and cannot capture modifier-only input;
  a passive Core Graphics event tap now interprets flagsChanged events.
  Settings expose the mode and Input Monitoring permission/status. Conventional
  shortcuts are retained and disabled while this mode is on. All 26 tests pass
  in debug and release, including gesture timing, extra modifiers, ordinary key
  and mouse shortcuts, busy phases, and event-to-recording-to-clipboard routing.
  System-wide hardware delivery requires the user to grant Input Monitoring;
  synthetic tests do not prove that macOS permission has been granted.
- Recording shortcuts and clipboard update, 2026-09-25: all 19 tests pass in
  debug and release. New coverage checks automatic copying after manual and
  automatic stops, clipboard preservation on empty/failed/cancelled results,
  copy failure/retry, and toggle handling during preparation and processing.
  Settings and studio views rendered successfully in the packaged app. Physical
  global shortcut delivery while another app is focused still needs a user trial.
- Verified 2026-09-25: debug tests passed (6/6), optimized release build passed,
  and CLI smoke checks passed against debug and release binaries.
- Unit coverage: lifecycle misuse, cancellation, stale/duplicate finals, audio
  continuity/format validation, WER and percentile calculations, unverified
  reference rejection, and stereo 48 kHz → mono 16 kHz conversion.
- Recording crash fix: the user's three 2026-09-25 crash reports showed
  `SIGTRAP` / `dispatch_assert_queue` in the audio-tap callback on
  `RealtimeMessenger.mServiceQueue`. The callback inherited `MainActor`
  isolation although AVAudioEngine invokes it on a background queue. Explicit
  `@Sendable` fixes that boundary without disabling Swift's runtime checks.
  `audioTapRunsOnBackgroundQueue` registers the production callback through an
  AVAudioNode test double and delivers synthetic audio on a background queue:
  reproduced the same signal/stack before the fix and passes afterward.
  All 7 tests passed in debug and release; CLI smoke checks also passed in both
  configurations. The release executable was rebuilt with the fix.
  This test requires no microphone access. The user's later live retry succeeded.
- Reproducible CLI check: `python3 Scripts/smoke.py` generates temporary silence
  and exercises file transcription, 40 warm fake-engine runs, grouping,
  validation failures, missing model assets and report overwrite protection.
  Config checks also cover project defaults, explicit config/CLI overrides,
  relative paths, spaces, home expansion, and malformed/missing config errors;
  passed for debug and release binaries after adding `nami.json`.
- Initial implementation did not record audio or download a model. Subsequently,
  the user downloaded the model and completed a diagnostic live recording.
  Formal quality/latency gates remain untested.
- Recording studio validation, 2026-09-25: all 15 tests passed in debug and
  release, including
  background audio delivery, cancellation during preparation/processing,
  stale-result rejection, model reuse, exact duration limits, WAV retention on
  inference failure, and config preservation. CLI smoke checks and optimized
  builds passed. Packaged app opened successfully; its own SwiftUI views were
  rendered and visually inspected in idle and transcript states.
- The packaged GUI transcribed the complete 11.87-second synthetic speech
  fixture using the configured real model (3.37 seconds for the first decode,
  excluding model loading; a subsequent app launch decoded it in 1.28 seconds).
  First app load required Core ML preparation; the
  main UI remained responsive. This is functional evidence, not a benchmark
  gate result. GUI microphone permission and live recording await user trial.

## Open recording investigation

- After the crash fix, the user reported an incorrect transcript (“Well, let's
  go to Woz”) for “Hello, how are you? How are you doing today? Hope everything
  is well.” The original recording was not saved, so the cause is not established.
- A local 11.87-second synthetic speech file was transcribed in full by the real
  downloaded model, including its final sentence. This is a diagnostic check,
  not user-speech quality evidence or an evaluation-gate result.
- macOS reported AirPods as the default input during investigation. Synthetic
  ten-second streams survive the production tap callback, resampler and session
  buffer at 16, 24 (AirPods), 44.1, 48 and 96 kHz, with signal at both ends.
- Added actual input-device/format reporting and captured duration/level stats.
  Explicitly requested WAV saves now happen before inference so failures leave
  inspectable audio. Next step: inspect a saved user recording alongside its
  transcript and capture diagnostics; do not call this recognition issue fixed.
- Validation: all 9 tests (including 5 sample-rate cases) passed in debug and
  release; release CLI smoke passed. Rebuilt executable is ready for a saved
  diagnostic recording.
- User supplied the saved diagnostic run: 10.10 seconds, average −28.2 dBFS,
  peak −6.6 dBFS, and 1.038 seconds stop-to-final. They reported the longer
  transcript was more plausible. This confirms capture produced a complete
  length recording; accuracy still needs a manually verified reference.

## Updating this file

Check a step only after its deliverable is verified. Add a short evidence link or
result alongside completed implementation steps. Record failures, model changes,
and revised acceptance targets here; keep SPEC.md aligned with scope changes.
