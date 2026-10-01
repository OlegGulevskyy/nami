# Nami

Nami has a native SwiftUI recording studio and a command-line benchmark harness
for the local-first dictation app in [SPEC.md](SPEC.md).
Progress is in [TRACKER.md](TRACKER.md).

Next focus: [transcript cleanup and personalization spec](SPEC-cleanup.md),
with an [implementation plan](tasks/plan.md) and [task checklist](tasks/todo.md).
The **Playground** page supports transcription comparisons, local cleanup
experiments, saved corrections, and editable model prompts.

Designing or changing a page? Follow the [page design guide](docs/design.md).

## Playground

Open **Playground** in the sidebar (**⌘4**). This is a separate
local test workspace; it never automatically copies or pastes test results and
does not change your normal dictation model.

1. Choose **Upload audio** or **History**. History includes saved test recordings
   and normal recording history. Audio is copied into the test workspace.
2. Open **Settings** to choose a local WhisperKit model and enter your ElevenLabs
   API key. Both settings save automatically across restarts; the key is stored
   in macOS Keychain, separate from workspace files and reports. **Add model** can use the
   dictation model, a local folder, or download from Hugging Face.
3. Click **Compare**, then confirm the ElevenLabs upload and provider charge.
   The selected local model and ElevenLabs Scribe v2 transcribe the same audio.
4. Read **Local** and **ElevenLabs** side by side. **Highlight differences** marks
   words present in only one transcript, including replacements, while preserving
   the original text. Case and punctuation differences are ignored. Use Play to
   listen and judge which transcript is better.

The page shows one comparison at a time, with transcription time beside each
provider. Results from different runs are never paired; a failed provider shows
its error while the other continues. Cancel keeps completed results. Normal
dictation cannot start while a comparison is running.

Samples, model paths, and all previous results persist under
`~/Library/Application Support/Nami/InternalDebugging`, independently of normal
history and app rebuilds. Model downloads use its `Models` subfolder. The page
keeps benchmark scores, reference editing, and word-by-word tables out of the
comparison flow. Existing reference data is retained.

The `nami-lab` CLI supports detailed benchmark reports, local runs, verified
references, and explicitly approved cloud comparisons. Reports include audio
hashes, run snapshots, paired differences, category summaries, and failures.
See the [agent benchmark workflow](docs/transcription-benchmarks.md) for commands,
normalization limits, and the improvement protocol.

### Inspect and edit prompts

Open **Playground → Prompts**, choose **Cleanup** or **Transcription**, then select
its model. In **Edit & preview**, the editable fields are on the left and the
assembled request to that same model is on the right. The preview updates as you
type; switch between **Your draft** and **Currently saved** to compare them.

Cleanup shows the system prompt, user message template, and sample transcript.
The Qwen models share the system prompt and user message template. Advanced
settings contain saved-correction templates. **Generation settings** holds the
decoding options sent with each request: thinking, temperature, top-p, seed,
repetition penalty and maximum output, plus the cleanup deadline. The preview lists these parameters under the
messages. **Save cleanup settings** applies the selected model's edits, generation
settings and shared templates to future requests, including live dictation and
retries. **Reset** restores a field's default in the draft; save to apply it.

Under **Transcription → Whisper**, choose **Live dictation** or **Playground**,
edit vocabulary hints, then click **Save vocabulary**. Whisper has no system prompt.
ElevenLabs receives audio and transcription options, with no editable text prompt.
Providers' internal instructions and tokenizer formatting are outside Nami's control.

**Sent requests** shows the selected model's actual messages captured immediately
before inference, with provider, source, time, and request ID. Cleanup includes the
resolved transcript and relevant saved corrections; Whisper shows the effective
vocabulary after its token limit. Requests remain visible if inference later fails.
Vocabulary-only cleanup has no model prompt; ElevenLabs requests are audio-only.

Prompt settings (`prompts.json`) and recent request history (`prompt-history.json`)
stay in the local Playground workspace across launches. History keeps up to 200
requests within an 8 MB text budget, so it is a recent diagnostic log, not an unlimited
archive. It cannot reconstruct prompts from runs made before this feature.

## Snippets

Open **Snippets** in the sidebar (**⌘2**) to save text you dictate often. Each
snippet has comma-separated phrases and text with `{{…}}` placeholders; the first
phrase names it in history. Say the trigger word (default `snippet`, editable on
the page), one of the snippet's phrases, then the details. Snippets are read-only
in the list; use the pencil to edit, then **Save** or **Cancel**. **How it works** on
the page summarizes this:

> "free env snippet for Excel add-in, Users API"

With the text `Hey @gptqa, is there a free environment to deploy {{apps}}`, Nami
pastes `Hey @gptqa, is there a free environment to deploy Excel add-in, Users API`.

- Matching is literal and ignores case and punctuation; the longest matching
  phrase wins. Recordings without a trigger word are pasted as usual. Leave the
  trigger words empty to turn snippets off.
- Details are the words after the phrase, without the trigger word and leading
  words such as "for" or "для". Commas, semicolons, "and", "plus", "и", and
  "плюс" separate them.
- Nothing is translated. To use snippets in several languages, list a trigger
  word per language (`snippet, сниппет`) and add each snippet's phrases in each
  language. In Russian dictation, English names may be recognized in Cyrillic
  ("Эксель"), so add that spelling too.
- One placeholder gets every detail, joined with commas. With several, details
  fill them in order and the last takes the rest; repeated labels share a value.
  Placeholders with no detail stay visible in the pasted text.
- Snippet text skips AI cleanup. History shows the snippet used and keeps what
  you said under **Show original**.

Snippets are saved in `~/Library/Application Support/Nami/snippets.json`, not in
`nami.json`. A damaged file is left untouched and is not overwritten.

### Manage snippets from the command line

`Scripts/nami-snippets` builds and runs a small CLI (NamiCore only, so it builds
in seconds) that edits the same file. The running app picks up its changes
within a second, and both lock the file while writing.

```sh
Scripts/nami-snippets list
Scripts/nami-snippets add --phrases "free env, free environment" \
    --text 'Hey @gptqa, is there a free environment to deploy {{apps}}'
Scripts/nami-snippets try "free env snippet for Excel add-in, Users API"
Scripts/nami-snippets update "free env" --phrases "free env, free environment, request env"
Scripts/nami-snippets remove "free env"
Scripts/nami-snippets trigger "snippet, сниппет"
```

Run `Scripts/nami-snippets help` for every option. The
[nami-snippets skill](Sources/NamiStudio/Resources/Skills/nami-snippets/SKILL.md)
teaches coding agents to create snippets with it; see [Agent skills](#agent-skills).

## Actions

Open **Actions** in the sidebar (**⌘3**) to do something on this Mac by voice
instead of pasting. Each action has comma-separated phrases and one or more steps,
run in order: open a link, app, file, or folder (links, files, and folders can
open in a chosen app), run a Shortcut, or run a shell command. For example, the
phrases `Open Excel repository, open Excel repo` with the step **Open link**
`https://github.com/acme/excel-addin`, opened with `Google Chrome`, open that
repository in Chrome when you say "Open Excel repo".

- A recording runs an action only when it starts with one of its phrases.
  Matching ignores case and punctuation; the longest phrase wins. Nothing is
  translated, so for several languages add phrases in each one, e.g.
  `open Excel repo, открой репозиторий Excel`.
- Without placeholders the phrase must be all you say, so "Open Excel repo and
  check the tests" is pasted as usual. Put `{{…}}` in a step to take the words
  said after the phrase: `github.com/search?q={{query}}` with the phrase
  `search GitHub` turns "search GitHub for snippet store" into a search. Details
  are URL-encoded in links and quoted as one word in shell commands.
- Links without a scheme open as `https://`. Shell commands run in a login `zsh`;
  Nami waits up to five seconds to report a failure, then lets them finish on
  their own. The first failing step stops the rest and shows its error.
- Only live dictation runs actions; imported audio and re-transcribed recordings
  are transcribed as usual. Nothing is copied, cleaned up, or pasted, and history
  shows the action that ran.

Actions are saved in `~/Library/Application Support/Nami/actions.json`, not in
`nami.json`. A damaged file is left untouched and is not overwritten.

### Manage actions from the command line

`Scripts/nami-actions` builds and runs a CLI like `nami-snippets` (NamiCore only)
that edits the same file; the running app picks up its changes within a second.
Steps run in the order given, and `--with` opens the previous link, file, or
folder in a chosen app.

```sh
Scripts/nami-actions list
Scripts/nami-actions add --phrases "open Excel repo, open Excel repository" \
    --open-url https://github.com/acme/excel-addin --with "Google Chrome"
Scripts/nami-actions add --phrases "search GitHub" --open-url "github.com/search?q={{query}}"
Scripts/nami-actions try "Open Excel repo"
Scripts/nami-actions update "open Excel repo" --open-app "GitHub Desktop"
Scripts/nami-actions remove "open Excel repo"
```

Other steps are `--open-file <path>`, `--shortcut <name>`, and `--command <command>`
(`--command -` reads it from standard input). `try` shows what would run without
running it. Run `Scripts/nami-actions help` for every option. The
[nami-actions skill](Sources/NamiStudio/Resources/Skills/nami-actions/SKILL.md)
teaches coding agents to create actions with it; see [Agent skills](#agent-skills).

### Agent skills

The app ships both CLIs in `Nami.app/Contents/Helpers`, so they work without this
checkout. **Settings → Agent skills** installs a skill for each into Claude Code's
`~/.claude/skills`, the shared `~/.agents/skills`, or a folder you choose (for
example your `CLAUDE_CONFIG_DIR`/skills). Installed skills point at the CLIs in the
running app. Each row shows whether its skill is installed, up to date, outdated,
edited, or from a newer Nami; **Remove** moves the skill's folder to the Trash, and
a symlinked skill is replaced or unlinked without touching its target.

The skills live in `Sources/NamiStudio/Resources/Skills/`. Whenever you edit one,
raise `metadata.version` in its front matter so installed copies show **Update**;
`AgentSkillsTests` fails until the version and fingerprint are updated.

## Open the recording studio

Build and open the app from this directory:

```sh
./Scripts/app.sh
```

After building once, double-click `.build/Nami.app` in Finder, or run
`open .build/Nami.app`. No CLI recording commands are needed.

On every launch, Nami checks **Microphone** and **Input Monitoring** access. If either
is missing, a popup blurs and blocks the history pane until both are allowed. The
sidebar stays available, including Settings and its Permissions section. Use
**Allow microphone** to trigger the macOS prompt before any model loads. If access
was denied, **Open Settings…** takes you to the microphone privacy settings.
**Allow Input Monitoring…** requests shortcut access and opens its privacy settings
when needed. Enable Nami, then return to the app; it rechecks automatically, or you
can click **Check again**. Follow any macOS prompt to quit and reopen the app. If a
rebuilt app still shows missing access, switch its permission off and on and reopen
Nami. Recording shortcuts and audio import cannot bypass this setup.

The sidebar contains **History**, **Snippets**, **Actions**, **Playground**, **Settings**,
**Shortcuts**, and **Models**, in that order, with an **About** icon at the bottom.
Press **⌘1**–**⌘7** to open the matching page, or **⌘8** for About. **Permissions** lives inside **Settings**.
The **Shortcuts** page contains all recording and pin-input shortcut controls, plus a
reference for built-in app shortcuts. Click **Pin / unpin input** to assign or change
its keys (default **⌃⌥P**). **Settings → Permissions** shows current Microphone, Input Monitoring,
and Accessibility access. Use **Allow…** for missing access, or **Manage…** to open the
corresponding macOS privacy pane and revoke or re-enable access. Status updates when
you return to Nami. Revoking a required permission stops an active recording.

1. Recordings have no time limit: they continue until you stop them.
2. Leave English and the configured WhisperKit model selected. **Local model**
   contains the model folder, engine, and optional evaluation reading prompts.
3. Click **Start recording** or use your shortcut. Nami opens the microphone immediately,
   independently of model loading. The **Listening** indicator appears once sound actually
   arrives. Bluetooth headsets such as AirPods need a second or two to switch to their
   microphone; until then the indicator shows **Waiting for microphone…**, and if no sound
   arrives within six seconds Nami asks you to choose another microphone.
   The model prepares automatically at launch once permissions are granted, and stays loaded
   while Nami is open. Transcription starts in the background after the first second of
   audio, once the model is ready. If you record before it is ready, audio is buffered
   and catches up after loading; you can still stop or cancel normally.
4. Watch the timer and live microphone levels. Click **Stop & transcribe** or use your
   shortcut when you're done. Nami finishes the unconfirmed tail and runs optional text
   cleanup before publishing the final transcript. Escape cancels.
5. The finished transcript is **copied to the clipboard automatically**. When
   recording with a shortcut from another app, Nami also **pastes at your cursor**
   after you allow Accessibility. Turn off **Copy when finished** to keep your previous
   clipboard while still pasting automatically. You can **Listen** to the captured audio or use **Copy** again.
   **Import audio** lets you transcribe an existing recording without a microphone.
   Transcripts are grouped by day. Click the search icon or press **⌘F** to search;
   hover a transcript for playback, or use its context menu. **⌘R** starts/stops recording.

Hover a history item and click **Re-transcribe** (the circular arrow beside the
trash icon) to recognize its saved audio again with the current model, vocabulary,
and cleanup settings. It updates the same item, keeping its original date and
audio. Failed, interrupted, and cancelled recordings can also be retried. The
previous transcript stays intact if a retry fails or is cancelled. Re-transcribing
does not automatically copy or paste; use **Copy** when the updated text is ready.

Choose a **Microphone** in **Settings** to remember that device across app restarts,
or choose **System default** to follow macOS. If a saved microphone is disconnected,
Nami keeps the choice and asks you to reconnect it or choose another input.
When a recording cannot open the microphone (or no sound arrives), the floating
indicator lists the connected microphones instead of closing. Pick one and recording
starts with it; it also becomes your saved choice. Close the list with **×** or **Escape**.
**Refresh microphones** updates the list after connecting a device.
Recording settings save immediately and restore from `nami.json` under `studio`, with
engine, language and model folder shared with the CLI.

Add names and technical terms in **Settings → Vocabulary**, separated by commas or
new lines. Changes save immediately in `studio.vocabulary` and survive app restarts
and Mac reboots. Packaged development builds use the project's `nami.json`;
distributed builds use `~/Library/Application Support/Nami/nami.json`.
Vocabulary stays on-device and applies to the next normal recording or audio import
without reloading the model. Keep the list short: WhisperKit limits its prompt
context and retains the end of long lists. These are recognition hints, not guaranteed
spellings or cleanup instructions. Clear the field to disable hints. Playground
comparisons use their own hint in **Playground → Prompts**, empty by default.
CLI benchmarks keep their unprompted baseline.

All studio recordings and
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
text is ready (and copied/pasted, if enabled). While listening, click **×** in the
capsule or press **Escape** in any app to cancel; the audio is kept in History. It
never takes keyboard focus and disappears after completion, failure, or cancellation. Keep Nami running to use
the global shortcuts.

Open **Shortcuts** in the sidebar (**⌘6**), or click the shortcut beside the
recording button in History. Use **History** in the sidebar or **Escape** to
return to recording history. Click **Allow Input Monitoring…**, enable **Nami** in **System Settings →
Privacy & Security → Input Monitoring**, and reopen Nami if macOS requests it.
The status changes to **Ready in any app while Nami is running** when the
listener is active. The listener is passive: it does not consume input or read
or retain typed characters. Secure Input can prevent macOS from delivering events.

To use conventional shortcuts instead, turn off **Use Option–Command taps**. The existing
configurable toggle (initially Control–Option–Space) and separate Start/Stop
shortcuts are retained, but inactive while tap mode is enabled. Those recorder
fields require a regular key with modifiers; they cannot capture modifier-only
or double-tap gestures. Mode and key assignments persist in macOS app preferences.

Recording continues until you stop it with a shortcut. Background model preparation does not block recording shortcuts.
Shortcuts do nothing while the microphone is opening, transcribing, or cancelling.
Conventional shortcuts trigger once on release. While listening or choosing a microphone,
Escape cancels from any app; otherwise it cancels when Nami is focused. Cancelled, failed, and empty
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

To compare batch transcription with live processing, replay saved audio at recording
speed. This test uses no microphone or clipboard. The optional JSON report includes
transcripts, so keep it private. For multiple fixtures, separate paths with newlines.

```sh
NAMI_TEST_MODEL_FOLDER="/path/to/model" \
NAMI_TEST_STREAM_AUDIO_FILES="/path/to/fixture.wav" \
NAMI_TEST_STREAM_REPORT="/tmp/nami-streaming-replay.json" \
  swift test -c release --filter streamingReplayMeasuresStopLatencyAgainstBatch
```

The report measures warm batch decode versus time from the last replayed audio buffer
to the final live transcript. It excludes history writes, text cleanup, and pasting.

**Fast local dictation:** in Models, download **Parakeet Ultra** and choose **Use
for dictation**. Keep a Whisper model installed: uncertain acronyms and close
matches to your vocabulary are verified against the complete recording with
Whisper. Parakeet supports 25 European languages; an explicitly selected language
outside that set uses Whisper. Automatic language detection on this path is
limited to Parakeet's languages. Choose Whisper for other languages.

With Qwen 1.7B or **Qwen 3 · 4B Instruct** cleanup, thinking disabled and
temperature **0**, Nami can prepare
cleanup while you speak. It reuses that work only when the complete final
transcript, language, prompts and saved corrections match exactly. Changed
endings are recognized and cleaned again; no provisional words are committed or
inserted. On Stop, obsolete cleanup is cancelled while final recognition runs.
Qwen verifies proposed tokens copied from the transcript; the 4B model can also
propose its previous answer and reuse an exactly matching causal prompt prefix.
Every proposed token is checked by the model. Batched floating-point evaluation
can differ from ordinary generation, so validate the resulting text as well as
latency when changing models, prompts or proposal sizes. The 0.6B model keeps its
existing generation path. Model loading is local; only the explicit Download
action accesses the network.

The 4B Instruct model uses about 3–5 GB of memory. Its official separate chat
template is embedded in the tokenizer configuration during installation for
compatibility with the pinned Swift tokenizer. Cleanup quality still depends on
the saved prompt: specify that hesitation sounds and accidental repetition are
removed, spoken corrections keep the corrected version, and names, numbers,
negation, uncertainty and unfinished thoughts are preserved.

For the complete stop-to-paste-dispatch path, use the isolated real-time replay:

```sh
NAMI_TEST_PROJECT="$PWD" \
NAMI_TEST_DEBUG_SETTINGS="$HOME/Library/Application Support/Nami/InternalDebugging" \
NAMI_TEST_FAST_MODEL_FOLDER="$HOME/Library/Application Support/Nami/Models/parakeet-ultra" \
NAMI_TEST_CLEANUP_ENGINE=qwen4 \
NAMI_TEST_CLEANUP_TEMPERATURE=0 \
NAMI_TEST_DICTATION_FILES="/path/to/fixture.wav" \
NAMI_TEST_DICTATION_REPORT="/tmp/nami-dictation.json" \
  swift test -c release --filter savedDictationEndToEndPerformance
```

Separate multiple audio paths with newlines. This copies settings and memory to
a temporary directory and uses a private pasteboard and injected paste-event
callback; it does not change the real clipboard, history, settings or focused
document. The timing includes recognition, cleanup, history writes and paste
preparation, but substitutes focus lookup and event dispatch and excludes the
receiving app's rendering time. For the original
Whisper and ordinary Qwen baseline, omit `NAMI_TEST_FAST_MODEL_FOLDER` and set
`NAMI_TEST_BASELINE=1` with `NAMI_TEST_CLEANUP_ENGINE=qwen17`. Keep temperature
and other inputs identical for an optimization-only comparison; report model or
prompt changes separately when evaluating a complete configuration. Optional
`NAMI_TEST_MAX_STOP_SECONDS` asserts a latency ceiling, and
`NAMI_TEST_DICTATION_EXPECTATIONS` points to per-recording content constraints.
Content checks are regression checks, not human-verified word error rates.
Reports contain transcripts and prompts; keep them private.

**Automatic paste:** click **Allow Accessibility…** in Nami or **Settings**,
then enable **Nami** in **System Settings → Privacy & Security → Accessibility**.
This permission is optional: without it, recording and copying still work.
Click the text field you want to dictate into, use the global shortcut to start
and stop, and keep that field focused until transcription finishes. Nami sends
**⌘V**, never Enter, so messages remain drafts for you to send. **Paste automatically**
is enabled by default and can be turned off in Settings while retaining automatic copying.
The two settings are independent: **Copy when finished** controls whether the
finished transcript stays on your clipboard. With copying off, automatic paste
temporarily places the transcript on the clipboard, sends **⌘V**, and restores
the previous items and all their available formats after a short handoff delay.
If you copy something else during that delay, Nami keeps your newer clipboard.
Temporary text is marked with the [standard transient and autogenerated types](https://nspasteboard.org/)
so clipboard managers that honor those markers exclude it from history. Managers
that ignore them may still record it.

Nami remembers the foreground app and, when available, the focused Accessibility
element at recording start. If the app or field differs at completion, Nami skips
paste; the transcript remains in history and is copied only if copying is enabled.
Editors that do not expose their
focused element get a best-effort paste guarded by the foreground app only.
If you hold shortcut modifiers when transcription finishes, paste is skipped.
Recordings started with Nami in front, audio imports, and the manual Copy button
do not automatically paste. Recordings and imports respect **Copy when finished**;
manual Copy always copies. Paste events are asynchronous, and an app can reject
the event or read the clipboard too late, so history and Copy
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

Nami includes Sparkle updates: **Nami → Check for Updates…** and update controls
in **Settings** and **About**. The update feed uses the public
`OlegGulevskyy/nami` GitHub releases repository. After the one-time Actions secret
setup, publish a `vX.Y.Z` release on GitHub to build and distribute it automatically.
Release notes are optional. See [Updates and releases](docs/updates.md).
Unconfigured local builds show that updates are unavailable, and distribution
builds fail rather than ship a broken updater.

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
Models, and About share the paper-and-sage styling. **Launch at login** uses
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
silently dropping audio.

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
  factory, model setup and the batch/live adapter live here.
- `NamiBench`: CLI orchestration, report generation, and explicit recording.
- `NamiStudio`: observable recording controller, persistent settings and SwiftUI
  recording/evaluation interface using the same engine contract.
- `NamiApp`: macOS application entry point and window lifecycle.

Live capture decodes in the background at approximately one-second audio intervals,
with one inference at a time. It confirms earlier timestamped segments while keeping
the last two segments and the newest second of audio available for revision. Stop
cancels outdated inference before decoding the remaining audio; in-flight or completed
work that already includes all audio is reused. Partial text stays internal, with clipboard/paste only after final
transcription and optional cleanup. File imports, retries, and CLI benchmarks keep
the batch path. Global recording
shortcuts use the pinned KeyboardShortcuts 3.1.0 package. The studio controller guards cancellation and late results; the future
insertion path still needs focus and session-ID checks before pasting.

Transcription uses a local model folder with SDK model download disabled and
validates local tokenizer assets before model loading (the SDK otherwise has a
tokenizer download fallback). A real-model, network-denied run is still needed
to establish offline behavior on this machine. No telemetry, account, cleanup
stage, or cloud adapter has been added.
