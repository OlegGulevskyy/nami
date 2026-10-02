# Initial evaluation — 2026-09-25

## Environment

| Item | Recorded value |
| --- | --- |
| Computer | MacBook Pro, Mac16,1 |
| Chip | Apple M4, 10 CPU cores (4 performance, 6 efficiency) |
| Memory | 32 GB |
| macOS | 27.0, build 26A428 |
| Swift | Apple Swift 6.2.3 |
| Language | English (confirmed by user) |
| Target apps | T3 Code, Chrome, Slack (confirmed by user) |
| Candidate SDK | WhisperKit 1.1.0 |
| Candidate model | openai_whisper-large-v3-v20240930_626MB |

Hardware was read from macOS tools; device serial numbers and unique device
identifiers are deliberately excluded from this record. The Mac meets
[WhisperKit's platform prerequisites](https://github.com/argmaxinc/argmax-oss-swift#prerequisites).
Memory capacity and compatibility are not evidence of speed or recognition quality.

## Corpus

Use the [reading script](READING-SCRIPT.md) for all 24 prompts and a matching
recording command for each file. Start with a few clips if you prefer.

`samples.template.json` contains 24 **draft prompts**, not recorded or verified
samples. It includes commands, names, technical terms, numbers, longer thoughts,
pauses, corrections, and conversational messages. Half are assigned quiet
conditions and half everyday noise as a starting plan; update these to the
actual conditions during recording. Aim for natural 5–30-second utterances.

Prepare `samples.local.json` and recordings using the procedure in the main
[README](../README.md). References must reflect the words actually spoken,
including fillers/corrections. Do not rewrite references to match model output.
Add representative real utterances if the draft prompts miss everyday usage.

## Decision protocol

Run an optimized build, on the same recordings for every backend/model. Record
power mode, whether the Mac is on battery, microphone choice, and obvious
background workload with each result. Repeat if thermal pressure or workload
distorts the measurements. Keep each report under a new filename.

Review recognition by listening to the original recordings and inspecting
the reference/hypothesis pairs. Count utterances requiring no word corrections;
look for recurring name/technical-term errors even if the aggregate is good.
Warm repetitions are latency observations, not new independent speech samples.

Initial proposed gates: median ≤1 s, p95 ≤2 s for warm 5–30-second utterances,
and at least 90% of samples requiring no word corrections. Report failures
honestly. Compare a smaller local model or another backend before app expansion
if the baseline is unsuitable. Incremental processing is a possible follow-up
if batch stop-to-final latency is too high.

No user-speech recognition measurements or backend acceptance decision have
been recorded yet.
