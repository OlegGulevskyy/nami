# Nami

Nami has a native SwiftUI recording studio and a command-line benchmark harness
for the local-first dictation app in [SPEC.md](SPEC.md).
Progress is in [TRACKER.md](TRACKER.md).

Next focus: [transcript cleanup and personalization spec](SPEC-cleanup.md),
with an [implementation plan](tasks/plan.md) and [task checklist](tasks/todo.md).
These describe planned work; cleanup and learning are not implemented yet.
The **Internal debugging** page already supports recording samples and comparing
speech-recognition models entirely in the app.

## Internal debugging

Open **Internal debugging** at the very bottom of the sidebar. This is a separate
local test workspace; it never automatically copies or pastes test results and
does not change your normal dictation model.

1. Choose **Record**, **Import**, or **From History…**. Recordings
   stop at 60 seconds. Imports and history selections get their own audio copy.
2. Give the sample a title and enter its **Expected text**: the words you
   actually said, including hesitations and corrections. Edits save immediately.
3. Expand **Models**, then use **Add model** to select the dictation model,
   choose a local folder, or download from Hugging Face.
   Browsing and downloading explicitly contact Hugging Face; downloaded models
   and comparisons are local afterward. Downloads and initial preparation can
   take several minutes. Removing a candidate keeps its files and prior results.
4. Select models and click **Compare**, or **Compare all** for all saved samples.
   Each model processes the same audio. Results appear beside your expectation
   with transcript, word error rate (WER), and transcription time. The info
   button shows the run date, model-load time, language, and saved reference.

WER ignores case/punctuation and is not a human quality judgment. It can exceed
100%; missing expectations remain unscored. Each result saves its own expectation
and language snapshot; a badge marks results made before you edited those fields.
Timing is one pass per model/sample, with preparation shown separately, not a
formal warm p95 benchmark or stop-to-paste measurement. Reruns retain older results.
Failed models show their errors while the rest continue. Cancel rejects late
results and retains already saved samples/results. Normal dictation cannot start
while debugging is capturing or running a comparison.

Samples, expectations, candidate model paths, and results persist under
`~/Library/Application Support/Nami/InternalDebugging`, independently of normal
history and app rebuilds. Model downloads use its `Models` subfolder. There are
no JSON files or terminal commands to manage in this workflow. This first page
compares WhisperKit speech recognition; text-cleanup providers and learning are
the next stage described in the spec.

## Open the recording studio

Build and open the app from this directory:

```sh
./Scripts/app.sh
```

After building once, double-click `.build/Nami.app` in Finder, or run
`open .build/Nami.app`. No CLI recording commands are needed.

On every launch, Nami checks **Microphone** and **Input Monitoring** access. If either
is missing, a popup blurs and blocks the history pane until both are allowed. The
sidebar stays available, including Settings and Permissions. Use
**Allow microphone** to trigger the macOS prompt before any model loads. If access
was denied, **Open Settings…** takes you to the microphone privacy settings.
**Allow Input Monitoring…** requests shortcut access and opens its privacy settings
when needed. Enable Nami, then return to the app; it rechecks automatically, or you
can click **Check again**. Follow any macOS prompt to quit and reopen the app. If a
rebuilt app still shows missing access, switch its permission off and on and reopen
Nami. Recording shortcuts and audio import cannot bypass this setup.

The persistent sidebar contains **History**, **Settings**, **Permissions**, **Local
model**, **About Nami**, and **Internal debugging** at the bottom. **Permissions** shows current Microphone, Input Monitoring,
and Accessibility access. Use **Allow…** for missing access, or **Manage…** to open the
corresponding macOS privacy pane and revoke or re-enable access. Status updates when
you return to Nami. Revoking a required permission stops an active recording.

1. Open **Settings** to choose a duration (5–60 seconds), or select manual stopping to stop
   manually. All recordings have a 60-second maximum.
2. Leave English and the configured WhisperKit model selected. **Local model**
   contains the model folder, engine, and optional evaluation reading prompts.
3. Click **Start recording** or use your shortcut. Nami opens the microphone immediately,
   independently of model loading. The **Listening** indicator confirms capture has started.
   The model prepares automatically at launch once permissions are granted, and stays loaded
   while Nami is open. If you record before it is ready, audio is buffered and saved before
   waiting for transcription; you can still stop or cancel normally.
4. Watch the timer and live microphone levels. Click **Stop & transcribe**
   early if needed, or wait for the chosen duration. Escape cancels.
5. The finished transcript is **copied to the clipboard automatically**. When
   recording with a shortcut from another app, Nami also **pastes at your cursor**
   after you allow Accessibility. You can **Listen** to the captured audio or use **Copy** again.
   **Import audio** lets you transcribe an existing recording without a microphone.
   Transcripts are grouped by day. Click the search icon or press **⌘F** to search;
   hover a transcript for playback, or use its context menu. **⌘R** starts/stops recording.

Choose a **Microphone** in **Settings** to remember that device across app restarts,
or choose **System default** to follow macOS. If a saved microphone is disconnected,
Nami keeps the choice and asks you to reconnect it or choose another input.
**Refresh microphones** updates the list after connecting a device.
Recording settings save immediately and restore from `nami.json` under `studio`, with
engine, language and model folder shared with the CLI. All studio recordings and
transcripts are saved automatically in `~/Library/Application Support/Nami/History`,
independent of the project, app bundle, and build directory. History is restored
on launch and has no count limit, expiration, or automatic cleanup. Each recording
has a UUID-named WAV and a JSON file containing its text, timestamp, input, model,
prompt, and recording statistics. Playback loads audio from disk on demand.
Imported audio gets its own normalized WAV copy, so moving/deleting the original
does not break history. Audio is saved when capture ends, before transcription;
failed, cancelled, or interrupted transcriptions retain the captured audio with a
status in history. Force-quitting during active capture can still lose that take.
**Settings → Recording history → Show folder** opens the storage directory.
**Save extra audio copies** optionally saves another microphone WAV in
`evaluation/audio` or a chosen folder; turning it off never disables history.
Previously discarded in-memory history cannot be recovered.

**Option + Command taps are enabled by default.** Press and release both keys
together **twice quickly** (within half a second) to start recording. While
recording, press and release the pair **once** to stop and transcribe. Release
both keys between taps. Either left or right modifiers work. Holding the keys,
adding another modifier, typing a regular key, or clicking/scrolling does not
count as a tap.

A small floating capsule appears near the bottom of the display under your
pointer, above the Dock, even while Nami is in the background or minimized.
It briefly shows **Getting ready…** while the microphone opens, live microphone waves and
a timer while **Listening**, then a **Transcribing…** spinner until the final
text is ready (and copied/pasted, if enabled). It never takes keyboard focus and
disappears after completion, failure, or cancellation. Keep Nami running to use
the global shortcuts.

Open **Nami → Settings… (⌘,)** or **Settings** in the sidebar, then click the pencil
beside **Start / stop recording**. Use **History** in the sidebar or **Escape** to
return to recording history. Click **Allow Input Monitoring…**, enable **Nami** in **System Settings →
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
still applies). Background model preparation does not block recording shortcuts.
Shortcuts do nothing while the microphone is opening, transcribing, or cancelling.
Conventional shortcuts trigger once on release. Escape cancels when Nami is focused. Cancelled, failed, and empty
transcriptions leave the clipboard unchanged. Successful recordings and audio
imports replace it with the final text when **Copy when finished** is enabled (the default).
Disable it in Settings to copy individual transcripts manually; this also disables automatic pasting.

Startup timings are logged locally under subsystem `local.nami.studio`, category
`Startup`: model preparation, recording request to microphone start, and recording
request to first audio received. These contain timing values, not audio or text.
Microphone hardware startup is still device-dependent; the model is no longer
on that path. An opt-in integration test replays an existing audio fixture through
the real model without opening a microphone or touching the clipboard:

```sh
NAMI_TEST_MODEL_FOLDER="/path/to/model" NAMI_TEST_AUDIO_FILE="/path/to/fixture.wav" \
  swift test --filter realModelStartupCapturesBeforeLoadAndReusesWarmModel
```

**Automatic paste:** click **Allow Accessibility…** in Nami or **Settings**,
then enable **Nami** in **System Settings → Privacy & Security → Accessibility**.
This permission is optional: without it, recording and copying still work.
Click the text field you want to dictate into, use the global shortcut to start
and stop, and keep that field focused until transcription finishes. Nami sends
**⌘V**, never Enter, so messages remain drafts for you to send. **Paste automatically**
is enabled by default and can be turned off in Settings while retaining automatic copying.

Nami remembers the foreground app and, when available, the focused Accessibility
element at recording start. If the app or field differs at completion, Nami leaves
the text on the clipboard for manual recovery. Editors that do not expose their
focused element get a best-effort paste guarded by the foreground app only.
If you hold shortcut modifiers when transcription finishes, paste is skipped.
Recordings started with Nami in front, audio imports, and the manual Copy button
only copy. The transcript stays on the clipboard after paste; Nami does not restore
its previous contents. An app can reject the paste event, so history and Copy
remain available. Live compatibility checks in T3 Code, Chrome, and Slack are pending.
Menu bar dictation is still upcoming.

For code changes, quit Nami and rerun `./Scripts/app.sh`. Builds are incremental;
this setup does not hot reload. `NAMI_BUILD_CONFIGURATION=debug ./Scripts/app.sh`
uses the debug configuration for faster compilation (release remains the default
for transcription performance). The script packages the app at `.build/Nami.app`
and remembers this checkout for development settings. Resource bundles are
self-contained and no longer depend on SwiftPM's build-directory fallback.

### One-time Developer ID setup

Use the **same Developer ID Application identity** for local and shared builds.
A paid Apple developer account is required; an iOS distribution certificate does
not sign macOS apps for distribution outside the Mac App Store.

1. Open **Xcode → Settings → Accounts**, sign in, and select your paid team.
2. Open **Manage Certificates → + → Developer ID Application**. Apple requires
   the team's Account Holder to create this certificate. If you already have one
   on another Mac, import its certificate **and private key** into this Mac's
   login Keychain instead. A `.cer` file alone is insufficient without its key.
3. Run `./Scripts/app.sh --check-signing`, then `./Scripts/app.sh`.
   If Keychain asks, allow `codesign` to use the signing key.
4. After switching from the old ad-hoc signature, grant Nami its microphone and
   Input Monitoring permissions once for this new identity. Subsequent rebuilds
   using that identity and bundle identifier should retain those grants.

The script automatically selects a sole valid Developer ID Application identity
and pins its SHA-1 fingerprint in Git-ignored `.signing-identity` after signing.
If multiple identities exist, select one explicitly on the first build:

```sh
security find-identity -v -p codesigning
NAMI_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' ./Scripts/app.sh
```

Environment selection overrides the saved fingerprint. Missing, expired, and
ambiguous identities fail before changing the existing app; the script never
silently falls back to ad-hoc signing. Keep bundle ID `local.nami.studio` stable.
Changing signing certificate type (Apple Development versus Developer ID) changes
the designated requirement and can prompt again. Apple explains this in
[TN3127: code-signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

`--no-open` builds without launching. `--package-only` repackages the last **Xcode**
build without compiling or launching. A disposable build without a certificate
is still possible with `--ad-hoc`, but changed executables can invalidate grants.
All packaged builds enable hardened runtime with the audio-input entitlement.

`Nami.xcodeproj` wraps the existing Swift packages for correct macOS resource
packaging. The script manages signing after Xcode finishes building. If you use
Xcode directly, select your team and the **same Developer ID Application**
identity in Signing & Capabilities; use the script for routine builds at the
stable `.build/Nami.app` path. Xcode-launched copies use Application Support for
settings unless you pass `--project /path/to/nami` in the scheme's arguments.

### Prepare an app to share

Local iteration needs signing only. For distribution, Apple also requires
[notarization](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).
Set up its credentials **once in your own Terminal**, with the interactive prompts:

```sh
xcrun notarytool store-credentials nami-notary
```

Use your Apple ID, developer Team ID, and an app-specific password created at
[account.apple.com](https://account.apple.com). Credentials stay in Keychain;
do not put them in the repository or chat. An App Store Connect API key is also
supported by `notarytool store-credentials --help`.

Then build, sign, notarize, staple, and verify:

```sh
./Scripts/distribute.sh
```

This command uploads the packaged app to Apple's notary service. It creates
`.build/distribution/Nami-macOS-arm64.zip` only after Apple accepts the submission,
the notarization ticket is stapled, and signature/Gatekeeper checks pass. Send
that ZIP yourself. Recipients can unzip it and move Nami to Applications.
Notarization may take several minutes and is not part of routine local builds.
For a signed app without submitting it yet, use `./Scripts/app.sh --distribution`.
The distribution output is separate from your local development app.

Current distribution supports **Apple Silicon and macOS 14+**. It excludes the
checkout path, personal `nami.json`, audio, and model weights. Recipients' settings
live in `~/Library/Application Support/Nami/nami.json`; each recipient must grant
the requested macOS permissions and configure a local WhisperKit model folder.
The app does not yet provide a first-run model download flow; signing does not
remove that setup requirement.

### Recover a stale permission from an older ad-hoc build

If Nami still appears enabled but shortcuts do not work after the one-time switch
to Developer ID, quit Nami and clear only its stale Input Monitoring entry:

```sh
tccutil reset ListenEvent local.nami.studio
open .build/Nami.app
```

Grant Input Monitoring again, and choose **Quit & Reopen** if macOS requests it.
If Nami is missing from the list, use **+** in System Settings to add this
project's `.build/Nami.app`. This reset does not touch other apps or Nami's
microphone permission. Do not run it as a routine rebuild step.

## Build and test

The native interface follows the recording-history and settings references. General,
Local model, and About Nami share the paper-and-sage styling. **Launch at login** uses
macOS Login Items and only changes when you toggle it in the packaged app.

For repeatable visual checks without microphone capture or clipboard changes:

```sh
swift build --product Nami
.build/debug/Nami --snapshot .build/design-check --design-preview
```

This renders the empty and populated history, settings pages, compact layouts, and
the permission popup (`permissions.png`), and permission management with granted and
missing access (`permissions-page.png`, `permissions-missing.png`). Permission states are simulated in snapshot
mode; it never requests macOS access or opens System Settings.
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
