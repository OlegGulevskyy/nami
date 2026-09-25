# Nami

Nami has a native SwiftUI recording studio and a command-line benchmark harness
for the local-first dictation app in [SPEC.md](SPEC.md).
Progress is in [TRACKER.md](TRACKER.md).

## Open the recording studio

Build and open the app from this directory:

```sh
./Scripts/app.sh
```

After building once, double-click `.build/Nami.app` in Finder, or run
`open .build/Nami.app`. No CLI recording commands are needed.

1. Open **Settings → General** to choose a duration (5–60 seconds), or select manual stopping to stop
   manually. All recordings have a 60-second maximum.
2. Leave English and the configured WhisperKit model selected. **Settings → Local model**
   contains the model folder, engine, and optional evaluation reading prompts.
3. Click **Start recording**, grant Nami microphone access when macOS asks,
   and wait for **Listening** before speaking. Initial model preparation can
   take a few minutes; it stays loaded for subsequent runs in the same app.
4. Watch the timer and live microphone levels. Click **Stop & transcribe**
   early if needed, or wait for the chosen duration. Escape cancels.
5. The finished transcript is **copied to the clipboard automatically**. Paste it
   anywhere with **⌘V**, **Listen** to the captured audio, or use **Copy** again.
   **Import audio** lets you transcribe an existing recording without a microphone.
   Transcripts are grouped by day. Click the search icon or press **⌘F** to search;
   hover a transcript for playback, or use its context menu. **⌘R** starts/stops recording.

Choose a **Microphone** in **Settings → General** to remember that device across app restarts,
or choose **System default** to follow macOS. If a saved microphone is disconnected,
Nami keeps the choice and asks you to reconnect it or choose another input.
**Refresh microphones** updates the list after connecting a device.
Recording settings save immediately and restore from `nami.json` under `studio`, with
engine, language and model folder shared with the CLI. **Keep audio files** is
off by default. Enable it to keep uniquely named WAV files in `evaluation/audio`
or another chosen folder. The last 12 runs remain available in memory while the
app is open; transcript history is not saved to disk. Imported files are left
in their original location.

**Option + Command taps are enabled by default.** Press and release both keys
together **twice quickly** (within half a second) to start recording. While
recording, press and release the pair **once** to stop and transcribe. Release
both keys between taps. Either left or right modifiers work. Holding the keys,
adding another modifier, typing a regular key, or clicking/scrolling does not
count as a tap.

A small floating capsule appears near the bottom of the display under your
pointer, above the Dock, even while Nami is in the background or minimized.
It shows **Getting ready…** during model preparation, live microphone waves and
a timer while **Listening**, then a **Transcribing…** spinner until the final
text is ready (and copied, if enabled). It never takes keyboard focus and
disappears after completion, failure, or cancellation. Keep Nami running to use
the global shortcuts.

Open **Nami → Settings… (⌘,)** or the settings icon, then click the pencil beside
**Start / stop recording**. Settings opens inside the main window; use the back arrow
or **Escape** to return to recording history. Click **Allow Input Monitoring…**, enable **Nami** in **System Settings →
Privacy & Security → Input Monitoring**, and reopen Nami if macOS requests it.
The status changes to **Ready in any app while Nami is running** when the
listener is active. The listener is passive: it does not consume input or read
or retain typed characters. Secure Input can prevent macOS from delivering events.

To use conventional shortcuts instead, turn off **Use ⌥⌘ taps**. The existing
configurable toggle (initially Control–Option–Space) and separate Start/Stop
shortcuts are retained, but inactive while tap mode is enabled. Those recorder
fields require a regular key with modifiers; they cannot capture modifier-only
or double-tap gestures. Mode and key assignments persist in macOS app preferences.

Turn off **Stop automatically** for manual stopping (the 60-second safety limit
still applies). Wait for **Listening** before speaking; shortcuts do nothing
while preparing, transcribing, or cancelling. Conventional shortcuts trigger once on release. Escape cancels when Nami is focused. Cancelled, failed, and empty
transcriptions leave the clipboard unchanged. Successful recordings and audio
imports replace it with the final text when **Copy when finished** is enabled (the default).
Disable it in General to copy individual transcripts manually. Nami does not paste into other apps.
Menu bar dictation and automatic insertion are still upcoming.

For code changes, quit Nami and rerun `./Scripts/app.sh`; Swift builds
incrementally, but this setup does not hot reload. Changing controls does not
require a rebuild. The script creates a locally ad-hoc-signed app bundle with
its own microphone usage description and remembers this project's location.
Keep the project and `.build` directory in place: this development bundle uses
SwiftPM's build-directory fallback to load the shortcut recorder's resources.

### Shortcuts stop working after a rebuild

The default local build is ad-hoc signed. Its code identity changes when the
executable changes, so macOS can reject the previous Input Monitoring grant even
when Nami still appears enabled in System Settings. Recording with the button
can continue to work because microphone access is a separate permission.

If **Nami** is already enabled, switching it off and on can retain the old build's
code requirement. Quit Nami, then clear only its stale Input Monitoring entry:

```sh
tccutil reset ListenEvent local.nami.studio
open .build/Nami.app
```

Click **Open Settings…** in Nami and grant Input Monitoring again. Choose
**Quit & Reopen** if macOS requests it. If Nami does not appear, use **+** in
**System Settings → Privacy & Security → Input Monitoring** to add this project's
`.build/Nami.app`. Reopen the existing bundle without rebuilding during recovery;
another changed executable will have another identity. This reset does not touch
other apps or Nami's microphone permission.

For development with an existing code-signing certificate, use the same identity
for every build: `NAMI_SIGNING_IDENTITY='Your code-signing identity' ./Scripts/app.sh`.
The identity must already be installed in Keychain; the script does not create
certificates or change permissions. After switching from ad-hoc signing, grant
Input Monitoring once more for the newly signed app. See Apple's
[code-signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

## Build and test

The native interface follows the recording-history and settings references. General,
Local model, and About Nami share the paper-and-sage styling. **Launch at login** uses
macOS Login Items and only changes when you toggle it in the packaged app.

For repeatable visual checks without microphone capture or clipboard changes:

```sh
swift build --product Nami
.build/debug/Nami --snapshot .build/design-check --design-preview
```

This renders the empty and populated history, settings pages, and compact layouts.
Sample history is available only in debug snapshot mode; normal launches use real recordings.

Requires Apple Silicon, macOS 14+, Xcode with Swift 6.2+, and network access to
resolve the pinned Swift package dependencies on the first build.

Run from this directory:

```sh
swift test
python3 Scripts/smoke.py
swift build -c release
.build/release/nami-bench help
```

`Package.resolved` pins transitive dependencies. WhisperKit is pinned to 1.1.0.
The CLI embeds a microphone usage description in its Mach-O executable.

## Download and try a model

This command explicitly accesses Hugging Face to download the model and its
tokenizer, then loads it once to complete setup. Model files are kept outside
application code in `~/Library/Application Support/Nami/Models` by default.
Allow time for the download and initial Core ML specialization.

```sh
.build/release/nami-bench download
```

The download command saves the model-folder path in the project's `nami.json`.
The current config already points to the large-v3-turbo model downloaded on this
Mac. Run from the project directory:

```sh
.build/release/nami-bench record --seconds 10
.build/release/nami-bench transcribe --audio sample.wav
```

## Project configuration

[`nami.json`](nami.json) contains the default engine, language, and model folder:

```json
{
  "engine": "whisperkit",
  "language": "en",
  "modelFolder": "~/Library/Application Support/Nami/Models/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_626MB"
}
```

The model files stay in Application Support; the project stores only the path.
`~` expands to your home directory. Relative model paths in config resolve
against that config file's directory. The CLI reads `nami.json` from the working
directory, or an explicit `--config /path/to/nami.json`. CLI flags such as
`--model-folder`, `--engine`, and `--language` override config values for that run.
Relative paths passed on the CLI resolve against the working directory.
Benchmark languages still come from each sample's manifest entry.

`download` updates only `modelFolder` in the selected config after successful
setup, preserving other settings. It creates the default config if absent;
an explicitly supplied `--config` must already exist. Invalid config files cause
a clear error. Config edits take effect on the next invocation without rebuilding.

The provisional model is `openai_whisper-large-v3-v20240930_626MB`, the compressed
multilingual large-v3-turbo variant. Use `download --model NAME` to try another
WhisperKit variant. Selection remains provisional until the user corpus passes
the gates. See [upstream model guidance](https://github.com/argmaxinc/argmax-oss-swift#model-selection).

English (`en`) is the initial default. `record` and `transcribe` accept
`--language CODE`. The CLI records for a bounded duration, not a global shortcut.
Stop the process with Control-C to cancel a CLI run. No insertion or clipboard
access occurs in this experiment.

Audio is kept in memory unless you explicitly use `record --save-audio PATH.wav`.
Recording prints the actual input device/format, captured duration and audio
levels. This helps distinguish missing/faint input from a recognition error.
Levels are in dBFS (0 is full scale; more negative is quieter), not speech detection.
When `--save-audio` is supplied, the captured audio is saved before inference so
it remains available if transcription fails. Its disk-write time is included in
the live stop-to-final measurement; use file benchmarks for comparable timings.
Existing audio and report files are never intentionally overwritten. Microphone
access is requested only by `record`; macOS may attribute permission to the
terminal that launched the tool. Capture errors stop the session rather than
silently dropping audio. Recordings are limited to 60 seconds.

If a transcript misses or invents words, collect a diagnostic recording:

```sh
.build/release/nami-bench record --seconds 10 --save-audio evaluation/audio/debug-01.wav
```

Read “Hello, how are you? How are you doing today? Hope everything is well.”
after “Speak now…”. Keep the printed microphone name, duration and levels with
the result. The saved WAV is the normalized audio sent to recognition. You can
listen to it with `afplay evaluation/audio/debug-01.wav` and rerun it with
`nami-bench transcribe --audio evaluation/audio/debug-01.wav` using the executable
path shown above. Use a new filename for subsequent attempts. A wrong transcript
alone cannot tell us whether the microphone or the recognizer caused the error.

## Prepare the English evaluation

The target apps are **T3 Code, Chrome, and Slack**. Hardware and the evaluation
procedure are recorded in [evaluation/README.md](evaluation/README.md).
The [reading script](evaluation/READING-SCRIPT.md) contains all 24 prompts with
copyable recording commands; you can collect them before downloading a model.

1. Copy `evaluation/samples.template.json` to `evaluation/samples.local.json`.
2. Record each prompt, aiming for 5–30 seconds. Adapt short prompts if necessary
   rather than padding them with long silence. Example:

   ```sh
   .build/release/nami-bench record --engine fake --seconds 10 --save-audio evaluation/audio/en-01.wav
   ```

   The fake engine produces placeholder text; it lets you collect audio before
   downloading a model. Its transcript is never an evaluation reference.
3. Listen to each saved recording. Edit `reference` to match what you actually
   said, including spoken corrections; set `referenceVerified` to `true` only
   after checking it. Record the actual quiet/noisy condition and sample category.
4. Run the same recordings through each candidate model:

   ```sh
   .build/release/nami-bench benchmark \
     --manifest evaluation/samples.local.json \
     --output evaluation/results/turbo-run-01.json \
     --repetitions 3
   ```

The benchmark rejects unverified references, duplicate IDs, missing files,
durations outside 5–30 seconds, and corpora outside 20–30 samples. Reports contain
reference text and transcripts. Audio, local manifests and result files are
ignored by Git because they may contain personal speech.

## Interpret a report

- `coldPrepareSeconds`: time to load an existing local model and tokenizer in
  this process. Downloads are excluded. Core ML/OS caches may already be warm;
  this is **process cold**, not a claim that system caches were cleared.
- `firstDecodeSeconds`: the first transcription, separately recorded and
  excluded from warm statistics. It is also the single warm-up run.
- Warm stop-to-final: audio is decoded from disk and appended before the timer;
  the timer wraps `finish`. The model remains loaded across all repetitions.
  This is a **batch baseline**, not a measurement of the future shortcut/UI path.
- Median uses the average of the two middle values for even counts; p95 uses
  nearest rank. Reports group warm runs by language, category and condition.
- Peak memory is `getrusage` maximum resident size for the whole process in bytes
  on macOS, including model preparation, preloaded corpus and warm-up. It is not
  isolated model memory or a per-sample peak.
- Word error rate uses word edit distance divided by reference word count,
  ignoring case and leading/trailing punctuation. This tokenizer is intended
  for the initial English corpus. Exact-match rate is an automated proxy.
- Review transcripts manually and add `needsWordCorrections` to each run. The
  JSON initially omits that optional field. Do not treat the automated proxy as
  proof of the 90% no-corrections gate. Record the human decision in TRACKER.md.

The proposed gates remain warm median ≤1 second, p95 ≤2 seconds, and at least
90% of samples needing no word corrections. Inspect each language and sample
type as well as the overall aggregate. A failed run exits with an error and
does not create a success report.

## Boundaries and current limitations

- `NamiCore`: SDK-free engine contract, typed errors, audio/session validation,
  fake engine, and evaluation calculations.
- `NamiAudio`: AVAudioEngine capture and AVAudioConverter normalization into
  timestamped mono 16 kHz Float32 chunks. Adapters own any further conversion.
- `NamiWhisperKit`: the only target importing the provider SDK; configuration,
  factory, model setup and the batch adapter live here.
- `NamiBench`: CLI orchestration, report generation, and explicit recording.
- `NamiStudio`: observable recording controller, persistent settings and SwiftUI
  recording/evaluation interface using the same engine contract.
- `NamiApp`: macOS application entry point and window lifecycle.

The adapter buffers until finish and emits no partials. Incremental decoding,
menu bar UI and focus-safe insertion remain later work. Global recording
shortcuts use the pinned KeyboardShortcuts 3.1.0 package. The studio controller guards cancellation and late results; the future
insertion path still needs focus and session-ID checks before pasting.

Transcription uses a local model folder with SDK model download disabled and
validates local tokenizer assets before model loading (the SDK otherwise has a
tokenizer download fallback). A real-model, network-denied run is still needed
to establish offline behavior on this machine. No telemetry, account, cleanup
stage, or cloud adapter has been added.
