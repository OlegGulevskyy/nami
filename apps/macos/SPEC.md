# Nami — POC spec

Nami (波, “wave”) is a personal macOS dictation app: hold a shortcut, speak,
release, and insert the transcript into the focused text field.

## Goal

Find out whether local speech recognition is accurate and fast enough for daily
use on this Mac. Start with a model experiment, then build the smallest useful
app. Keep transcription replaceable so switching models or adding a cloud
provider does not require rewriting recording, UI, or text insertion.

## First experiment

- Start with Swift and [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift).
  Try a multilingual Whisper large-v3-turbo variant; compare a smaller model if
  speed or memory is a problem. Confirm device compatibility before choosing.
- Build a minimal recording/transcription harness before the menu bar app.
- Provide a native recording studio for configuring runs, seeing live input
  levels and recording/processing state, reading evaluation prompts, listening
  back and copying transcripts. This evaluation UI can precede backend selection;
  it uses the same capture and engine contract as the CLI. Persist all studio
  recordings and transcripts locally across restarts and rebuilds, without
  automatic cleanup. CLI audio export remains opt-in.
- Use 20–30 representative utterances with manually checked reference text:
  short commands, longer thoughts, names, technical terms, pauses, corrections,
  and the languages actually used. Include quiet and everyday noisy conditions.
- Record hardware, model/version, cold-start time, warm stop-to-final latency
  (median and p95), recognition errors, and peak memory. Keep models loaded
  between warm runs; process audio during recording where supported.
- Initial target: warm median stop-to-final latency ≤1 second and p95 ≤2 seconds
  for 5–30-second utterances; at least 90% of samples need no word corrections.
  These are proposed evaluation gates, not promised performance.
- Judge results by language and sample type as well as overall. If unsuitable,
  try another local model/backend on the same recordings, then consider a cloud
  adapter. Record the evidence and decision before expanding the app.

## POC scope

- Native Swift/SwiftUI menu bar app; microphone capture through AVAudioEngine.
- Configurable push-to-talk shortcut; recording/processing indicator that does
  not steal focus; Escape cancels.
  The current studio uses Option + Command double-tap to start and single-tap
  to stop, with Input Monitoring setup; conventional key shortcuts remain an
  alternative. Hold-to-talk remains future work.
- Prepare the selected model automatically at startup after permission setup,
  and retain it while the app runs. Microphone capture must not wait for model
  loading: buffer speech immediately, preserve it before waiting for transcription,
  and allow normal stopping/cancellation during background preparation.
- Fully local transcription after the initial model download. No account,
  telemetry, or automatic cloud fallback; studio history saved locally; CLI audio export is opt-in.
- Paste the final text into the focused app using the clipboard and simulated
  paste, with microphone and Accessibility permission setup.
- Preserve clipboard contents where feasible without overwriting newer user
  copies. If the target changes during processing, keep the transcript for
  manual recovery instead of pasting into an unintended field. Never press Enter.
- Keep the latest transcript in memory with a Copy action if insertion fails.
- Validate in three chosen everyday apps. Universal app support is out of scope.

## Replaceable architecture

`Shortcut → Audio capture → Transcription engine → Text insertion`

- **Audio capture:** produces timestamped audio chunks in a documented format;
  adapters own provider-specific conversion and buffering.
- **Transcription engine:** a Swift protocol with prepare, start, append audio,
  finish, and cancel operations. Emits optional partial text, one final result,
  and typed errors; exposes capabilities such as incremental processing and
  network requirement. Batch-only engines buffer internally behind the same API.
- **Adapters:** implement WhisperKit first. Select engine and model through
  configuration and a factory; the rest of the app never imports provider SDKs.
  Store model downloads separately from application code.
- **Session controller:** owns idle/recording/processing/error state, cancellation,
  and session IDs so late results cannot paste after cancellation or a new session.
- **Text insertion:** independent of recognition; accepts final text and target.
- **Cleanup:** off initially so we measure recognition itself. A later, separately
  replaceable text processor can remove fillers or format text while preserving
  meaning. A fully local mode must keep this stage local too.
- **Cloud option:** explicit selection only, with visible network behavior and
  credentials in Keychain. Adapter changes must not affect the dictation UI.

## Delivery sequence

1. Record hardware, intended languages, three target apps, and evaluation samples.
2. Define the engine contract and build the local benchmark harness.
3. Add the recording studio to help collect samples, then run the benchmark;
   document results and choose or replace the local backend.
4. Build the menu bar app, permissions, shortcut, and recording lifecycle.
5. Add insertion, clipboard handling, cancellation, and transcript recovery.
6. Run daily-use trials and a provider-swap check; document remaining limitations.

POC is complete when the selected engine passes the agreed quality/latency gates,
dictation works in the three target apps, and a fake engine can replace the real
one without changes to capture, UI, or insertion. Cloud integration, advanced
cleanup, context reading, other platforms, and distribution are later work.

Progress and evidence live in [TRACKER.md](TRACKER.md).

## Next focus: cleanup and personalization

[SPEC-cleanup.md](SPEC-cleanup.md) defines the proposed next phase: local text
cleanup before insertion, evaluation of speed and meaning preservation, and
learning from confirmed user corrections. Follow its [plan](tasks/plan.md) and
[tasks](tasks/todo.md). This extends the roadmap; it does not mark the original
recognition or dictation validation gates complete.

The sidebar's **Internal debugging** page is the user-facing evaluation workspace:
record/import/reuse audio, edit expected transcripts, add/download candidate
WhisperKit models, and compare selected models on one or all samples. Persist
samples, audio, and per-run reference snapshots separately from normal history.
Never automatically copy/paste test results or change the active dictation model.
Future cleanup evaluation must extend this page; JSON/CLI setup is not required
of the user.
