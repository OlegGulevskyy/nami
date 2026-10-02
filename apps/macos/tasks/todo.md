# Tasks — transcript cleanup and personalization

Status: first experiment implemented; complete stage gates remain pending.
[Implementation notes](../evaluation/cleanup/README.md). Requirements and gates:
[spec](../SPEC-cleanup.md). Sequencing and risks: [plan](plan.md).
Paths below are proposed where a file does not yet exist. Split any task that
grows beyond roughly five files before implementation.

The ASR **Internal debugging** page is now implemented. The tasks below concern
cleanup and must extend that page. Users collect/reference samples, choose
providers, and inspect results in the app; JSON/CLI work is not required.

## Stage A — prove the approach

2026-09-28 checkpoint: Internal debugging has Transcription/Cleanup pages, a
vocabulary baseline, Apple guided-output cleanup, downloadable Qwen3-0.6B via
MLX, saved comparisons, and opt-in synthetic probes. The live toggle applies
the selected engine before copy/paste, retains raw text in history, and enforces
bounded fallback and cancellation. Explicit local vocabulary and correction
retrieval can be tested with memory on/off. This covers implementation slices of
A2–A4, B, and C; it does not complete the 40-case corpus, held-out evaluation,
real-editor trials, or automatic correction capture. The original stage gates
below remain broader than these implemented slices.

- [ ] **A1. Extend the debugging corpus for cleanup.** Add desired cleaned text,
  verification and split labels to the saved samples and their editor. Seed 40
  synthetic cases and prepare a fixed
  24/16 development/held-out split; mark unverified records honestly.
  Acceptance: verbatim, ASR, desired output, protected facts, and verification
  state are distinct; personal data is excluded from git.
  Verify: fixture schema checks, manual case review, `git check-ignore` on local
  paths. Dependencies: none. Files: `Sources/NamiStudio/DebuggingStore.swift`,
  `Sources/NamiStudio/InternalDebuggingView.swift`, `evaluation/cleanup/README.md`,
  `evaluation/cleanup/samples.template.json`, `Tests/NamiStudioTests/DebuggingSessionTests.swift`.

- [ ] **A2. Add a text-only rules/pass-through comparison.** Introduce the
  provider contract and a cleanup runner accessible from Internal debugging.
  Acceptance: reproducible per-case output/timing, schema validation, manual
  quality fields, and provider identity; existing ASR evaluation unchanged.
  Verify: `swift test --filter Cleanup`, in-app comparison on synthetic fixtures.
  Dependencies: A1. Files: `Sources/NamiCore/TextProcessor.swift`,
  `Sources/NamiStudio/CleanupComparison.swift`, `Sources/NamiStudio/InternalDebuggingView.swift`,
  `Tests/NamiCoreTests/CleanupTests.swift`, `evaluation/cleanup/README.md`.

- [ ] **A3. Run the Apple model feasibility probe.** Add an isolated adapter and
  benchmark it with the same cases, short instructions, and no personal profile.
  Acceptance: runtime availability, refusal, preparation, full generation time,
  and deadline behavior reported; deployment baseline preserved.
  Verify: adapter tests, release build, real model probe on this Mac.
  Dependencies: A2. Files: `Sources/NamiAppleCleanup/AppleTextProcessor.swift`,
  `Package.swift`, `Sources/NamiStudio/CleanupComparison.swift`,
  `Tests/NamiAppleCleanupTests/AppleTextProcessorTests.swift`.

- [ ] **Checkpoint A3:** runner works, failures are visible, model work does not
  require changing ASR, and prototype outputs are available for human review.

- [ ] **A4. Compare one small MLX model.** Select a compatible licensed model,
  pin revision/quantization, and run the identical benchmark.
  Acceptance: model assets remain outside source control; setup is explicit;
  output, full latency, and combined memory are recorded.
  Verify: adapter tests, optimized probe, report comparison.
  Dependencies: A3. Files: `Sources/NamiMLXCleanup/MLXTextProcessor.swift`,
  `Package.swift`, `Sources/NamiStudio/CleanupComparison.swift`,
  `Tests/NamiMLXCleanupTests/MLXTextProcessorTests.swift`,
  `evaluation/cleanup/README.md`.

- [ ] **A5. Evaluate real dictations and record the decision.** Collect/reuse
  representative recordings and manually verify references; tune only on the
  development split, then evaluate held-out cases and raw-ASR end-to-end results.
  Acceptance: all spec metrics, regressions, fallbacks, exact model/configuration,
  and a selected provider or measured blocker are documented.
  Verify: listen to samples, review paired outputs, repeat warm timings, check
  offline operation. Dependencies: A4 plus user-verified corpus.
  Files: ignored local corpus/reports, `evaluation/cleanup/DECISION.md`, `TRACKER.md`.

- [ ] **Checkpoint A:** review the provider decision against quality and total
  latency gates. Do not call synthetic-only results validation of user speech.

## Stage B — integrate daily-use cleanup

- [ ] **B1. Preserve original and processed text in history.** Add optional
  processing metadata and compatible decoding.
  Acceptance: old recordings load unchanged; raw text survives processor failure;
  final transcript remains compatible with current history consumers.
  Verify: old/new round-trip and failure tests with `swift test --filter History`.
  Dependencies: A5. Files: `Sources/NamiStudio/StudioSession.swift`,
  `Sources/NamiStudio/RecordingHistoryStore.swift`,
  `Tests/NamiStudioTests/RecordingHistoryTests.swift`.

- [ ] **B2. Process before copying/pasting.** Integrate selected provider through
  injection, deadlines, bounded work, cancellation, and final focus checks.
  Acceptance: copy/paste happens at most once; cancellation/late responses never
  paste; raw fallback works; capture never waits for cleanup preparation.
  Verify: `swift test --filter StudioSession`, delayed fake provider and target
  changes. Dependencies: B1. Files: `Sources/NamiStudio/StudioSession.swift`,
  `Sources/NamiStudio/TextProcessorFactory.swift`, `Package.swift`,
  `Tests/NamiStudioTests/StudioSessionTests.swift`.

- [ ] **B3. Expose cleanup controls and original recovery.** Add the opt-in
  setting, processing status, fallback reason, Original, and Copy original.
  Acceptance: disabled mode matches previous behavior; imports remain copy-only;
  manual copying does not regenerate text. Verify: settings persistence tests,
  SwiftUI renders, manual flows. Dependencies: B2.
  Files: `Sources/NamiStudio/StudioSettings.swift`,
  `Sources/NamiStudio/StudioSettingsView.swift`, `Sources/NamiStudio/StudioView.swift`,
  `Sources/NamiStudio/RecordingIndicator.swift`,
  `Tests/NamiStudioTests/StudioSettingsTests.swift`.

- [ ] **Checkpoint B:** `swift test`, `python3 Scripts/smoke.py`, and
  `swift build -c release` pass. Validate draft insertion in T3 Code, Chrome, and
  Slack without sending. Confirm latency, raw recovery, and network-denied
  operation before considering cleanup enabled by default.

## Stage C — learn from explicit feedback

- [ ] **C1. Add editable personal vocabulary/preferences.** Create local,
  versioned storage and a small UI; pass bounded context to cleanup.
  Acceptance: entries persist, scope/precedence is explicit, delete/reset works,
  and an empty profile preserves baseline behavior.
  Verify: persistence/context tests and restart/delete manual checks.
  Dependencies: B3. Files: `Sources/NamiCore/PersonalProfile.swift`,
  `Sources/NamiStudio/PersonalProfileStore.swift`,
  `Sources/NamiStudio/StudioSettingsView.swift`,
  `Sources/NamiStudio/StudioSession.swift`, `Tests/NamiStudioTests/PersonalProfileTests.swift`.

- [ ] **C2. Capture confirmed correction examples.** Add Correct / teach Nami
  with explicit use-for-learning confirmation and delete support.
  Acceptance: raw/generated/corrected versions and provenance stay distinct;
  saving feedback never pastes or creates a global replacement automatically.
  Verify: confirmation/cancel/delete/restart tests and UI walkthrough.
  Dependencies: C1. Files: `Sources/NamiCore/CorrectionExample.swift`,
  `Sources/NamiStudio/CorrectionStore.swift`, `Sources/NamiStudio/StudioView.swift`,
  `Tests/NamiStudioTests/CorrectionStoreTests.swift`.

- [ ] **C3. Retrieve relevant corrections within a budget.** Select at most
  three confirmed examples, exclude held-out/current evaluation examples, and
  supply only relevant vocabulary/preferences.
  Acceptance: context is bounded, deletion takes effect, and paired evaluation
  shows whether personalization helps without creating meaning regressions.
  Verify: selection/budget tests and profile-on/profile-off comparison.
  Dependencies: C2. Files: `Sources/NamiCore/PersonalizationContext.swift`,
  `Sources/NamiStudio/StudioSession.swift`,
  `Sources/NamiStudio/CleanupComparison.swift`,
  `Tests/NamiCoreTests/PersonalizationContextTests.swift`.

- [ ] **Checkpoint C:** trial daily use, extend the regression set with confirmed
  failures, verify reset removes future influence through retrieval, and document
  results in `TRACKER.md` and the local evaluation report.

- [ ] **C4. Capture edits after paste in supported editors.** First validate a
  single editor: establish the inserted range, observe stable edits through
  Accessibility, reject ambiguous observations, and retain candidate provenance.
  Add an opt-in learning switch and review/delete controls. Keep unsupported
  editors on explicit correction capture. Treat repeated corrections as evidence
  for a proposed scoped rule, never turn one arbitrary rewrite into a global rule.
  Acceptance: no unrelated document text or keystrokes retained; focus changes,
  sends, deletions and range ambiguity safely stop capture. Dependency: B2 and C2.
  Split capture, candidate review, and rule-promotion work before implementation.

## Stage D — decide whether training is justified

- [ ] **D1. Review remaining failures and data readiness.** Categorize ASR errors,
  cleanup errors, and personal preferences; compare prompt/memory improvements
  before proposing a LoRA experiment.
  Acceptance: a written train/defer decision with dataset provenance, evaluation
  split, version/rollback plan, and measurable expected benefit. No training is
  started by this task. Verify: evidence review against the cleanup baseline.
  Dependencies: checkpoint C. Files: `evaluation/cleanup/TRAINING-DECISION.md`.
