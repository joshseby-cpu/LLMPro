# Contributing to LLMPro

Thanks for your interest! LLMPro is a native macOS app that puts a no-code UI on
top of Apple's [MLX](https://github.com/ml-explore/mlx) / `mlx-lm` for fine-tuning
local LLMs. Contributions of all sizes are welcome — bug fixes, features, docs,
and dataset/model-compatibility reports.

## Before you start

This codebase is **documentation-first** — read these in order, they'll save you
a lot of time:

1. [`CLAUDE.md`](CLAUDE.md) — the orientation file. Read it fully once. It explains
   the "core loop" the whole app is built around and the **load-bearing decisions**
   you must not break.
2. [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — what code lives where.
3. [`docs/WORKFLOWS.md`](docs/WORKFLOWS.md) — trace a user action end-to-end.
4. [`docs/CONVENTIONS.md`](docs/CONVENTIONS.md) — *why* things are built the way
   they are (Swift-first, friendly-first UI, the brand accent + `.card()` design
   system, the JSON-event helper protocol).

## Dev setup

You need a Mac with **Apple Silicon** and **Xcode 16+** (macOS 14+ target). The
project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) — the
`.xcodeproj` is gitignored.

```bash
# one-time
brew install xcodegen

# generate + build
xcodegen generate
xcodebuild -project LLMPro.xcodeproj -scheme LLMPro -configuration Debug -destination 'platform=macOS' build

# run the tests (53 and counting)
xcodebuild -project LLMPro.xcodeproj -scheme LLMPro -configuration Debug -destination 'platform=macOS' test
```

See [`INSTALL.md`](INSTALL.md) for a beginner-friendly, end-to-end build guide.

## Conventions that matter

- **Swift-first.** Default to Swift; reach for the Python helpers only for work
  that genuinely needs the ML stack (mlx-lm, HF hub, weight surgery). Every helper
  is permanent bundle weight.
- **Friendly-first UI.** Lead with plain language + emoji + star ratings; tuck
  charts/logs/YAML behind a `DisclosureGroup`. Use `Color.brand` / `.card()` from
  `Core/Theme.swift` rather than hardcoding accent colors or re-rolling card chrome.
- **AutoTuner owns hyperparameters.** Don't add training knobs to the primary UI.
- **Helpers speak the JSON-event protocol** (`{"event": "start|progress|done|error", …}`
  one object per line on stdout). See [`docs/CONTRACTS.md`](docs/CONTRACTS.md).
- **A green UI is not a pass.** After testing, read the logs
  (`~/Library/Application Support/LLMPro/logs/llmpro.log`) and check for a new
  `~/Library/Logs/DiagnosticReports/LLMPro-*.ips` crash report.

## Submitting a change

1. Fork and create a branch off `main`.
2. Make your change. Keep it focused — no drive-by refactors.
3. **Verify:** the build succeeds and the test suite passes; add/adjust tests for
   what you changed.
4. **Update the docs.** This repo treats out-of-date docs as a regression — see the
   [doc-maintenance contract](CLAUDE.md#%EF%B8%8F-documentation-is-part-of-the-work--read-this-section-twice).
   At minimum, append one line to the **Recent session log** in
   [`docs/STATE.md`](docs/STATE.md).
5. Open a pull request using the template. Describe what changed and how you
   verified it.

## Reporting bugs / requesting features

Use the issue templates (Bug report / Feature request). For bugs, the logs and
your macOS + Apple-Silicon details make a huge difference — please include them.

By contributing, you agree your contributions are licensed under the project's
[MIT License](LICENSE).
