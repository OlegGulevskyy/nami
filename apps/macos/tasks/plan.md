# Plan — transcript cleanup and personalization

Status: dedicated cleanup comparison page, Apple/Qwen adapters, deadline runner,
opt-in live cleanup with original recovery, and explicit personal memory implemented. See
[current experiment and remaining gates](../evaluation/cleanup/README.md).
The full held-out corpus, real-editor trials, provider selection, and automatic
edit capture remain pending.
Requirements: [SPEC-cleanup.md](../SPEC-cleanup.md).
Execution checklist: [todo.md](todo.md).

## First deliverable

Use **Internal debugging** as the user-facing workspace for the entire
experiment. Its recording/import/history, expected transcript editing, model
downloads, and ASR comparisons already work. Add cleanup targets, dataset labels,
and cleanup providers there. CLI tooling is optional developer automation, never
a required user workflow.

Produce a reproducible comparison of raw text, conservative rules, Apple
Foundation Models, and one small MLX candidate on the same dictations. Include
actual outputs, manual quality judgments, complete latency, and memory. Select a
provider only after seeing the results. Do not start with training.

## Delivery sequence

| Stage | Deliverable | Exit condition |
| --- | --- | --- |
| A. Experiment | Separate cleanup corpus, runner, candidate adapters, report | Provider selected or measured blocker documented |
| B. Daily-use cleanup | Opt-in processing before paste, original recovery, local fallback | Lifecycle tests and real-app trials pass |
| C. Personal memory | Editable vocabulary/preferences and confirmed correction examples | Measured improvement on future examples; reset works |
| D. Training decision | Review recurring failures and dataset readiness | Train only if evidence supports benefit over memory/prompting |

Dependency order:

```text
Corpus contract → rules benchmark → Apple probe → MLX comparison → decision
                                                               ↓
                                            history → pre-paste path → UI
                                                               ↓
                                       personal profile → correction capture
                                                               ↓
                                            bounded example retrieval → trial
                                                               ↓
                                                 optional training decision
```

Corpus collection can proceed while the runner is built. Provider work shares
one request/result contract; integrate it sequentially to avoid competing APIs.
No agent delegation is required by this plan.

## Architecture decisions

- Retain the existing ASR interface and current model for the first experiment.
- Introduce an independent `TextProcessor` boundary in `NamiCore`, with provider
  SDKs in adapters. Prepare without delaying capture; limit concurrent work.
- Treat transcript and retrieved examples as data. Return only final text;
  use a compact prompt and bounded profile context.
- Preserve raw and final text; retain existing history compatibility and focus
  guards. Timeout falls back to raw, cancellation never pastes.
- Keep vocabulary, style settings, and correction examples locally editable.
  Explicit feedback is the first learning mechanism.
- Follow explicit feedback with supported-editor capture of corrections made
  after paste. Track the inserted passage, reject ambiguous observations, and
  validate repeated corrections before proposing broadly applied rules.
- Keep existing recognition evaluation unchanged; cleanup has its own schema
  and scoring. Document new CLI commands when they actually exist.

## Main risks and responses

| Risk | Response |
| --- | --- |
| Model alters meaning | Protected-fact cases, unchanged examples, manual held-out review, raw recovery |
| Full rewrite exceeds latency budget | Measure full output, hard fallback deadline, bounded input group, compare smaller model |
| Second model delays capture or exhausts memory | Preserve startup decoupling; measure combined warm memory and capture latency |
| SDK ignores cancellation | Retire timed-out sessions, reject late responses, bound outstanding work |
| Apple model unavailable or toolchain incompatible | Isolate availability checks and keep raw/rules fallback and MLX option |
| Historical data mistaken for verified examples | Explicit labels and human references; immutable held-out split |
| One-off edits become bad global rules | Separate confirmed preferences from retrieved examples; make both removable |

## Verification checkpoints

After stage A, inspect actual outputs and report failures without hiding fallback
rates. After stage B, run focused lifecycle/persistence tests, the existing smoke
checks, a release build, and manual trials in T3 Code, Chrome, and Slack (draft
text only; never send). After stage C, measure held-out improvements with and
without a profile and verify reset/restart behavior. Run the network-denied check
after model setup before claiming fully local operation.

The [spec](../SPEC-cleanup.md) owns acceptance targets. This plan does not
authorize changing those targets, shipping a cloud path, or starting training.
