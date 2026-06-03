# Building and running MLX Studio

> 📝 **Maintainers**: when you discover a build issue, a workaround, a Swift 6
> gotcha, a signing/notarization quirk, or anything else that took you longer
> than 5 minutes to figure out, add it to the troubleshooting section. The next
> agent should not have to rediscover what you just learned. See the
> [doc-maintenance contract](../CLAUDE.md#%EF%B8%8F-documentation-is-part-of-the-work--read-this-section-twice).

How to get from a freshly-cloned checkout to a running app, plus troubleshooting
for the gotchas we've hit.

---

## TL;DR

```bash
# One-time per machine:
sudo xcodebuild -license accept     # accept Apple's licence agreement
brew install xcodegen

# Every time the project structure changes (new files, project.yml edits):
xcodegen generate

# Build the app:
xcodebuild -project MLXStudio.xcodeproj \
           -scheme MLXStudio \
           -configuration Debug \
           -destination 'platform=macOS' \
           build

# Run it:
open ~/Library/Developer/Xcode/DerivedData/MLXStudio-*/Build/Products/Debug/MLXStudio.app
```

That's it. The app's runtime dependencies (Python venv, mlx-lm, etc.) install
themselves on first launch — you don't need to set anything up manually.

---

## Requirements

- **Apple Silicon Mac** (M1 or later). x86 is unsupported — mlx-lm is Metal-only.
- **macOS 14+** (Sonoma). The project uses SwiftData, `@Observable`, modern
  Swift Charts.
- **Xcode 26+** (Swift 6.0 toolchain). We compile with Swift 6 strict
  concurrency on.
- **At least 16 GB unified memory recommended.** Tiny models work in 8 GB; for
  the 27B+ runs you want 32 GB minimum, ideally 64-128 GB.

For the runtime dependencies that the app bootstraps for itself on first launch:

- `uv` (the modern Python package manager). The app prefers a bundled `uv`
  binary at `MLXStudio/Resources/uv-aarch64-apple-darwin` (not currently
  shipped). Falls back to `~/.local/bin/uv`, `/opt/homebrew/bin/uv`, or
  `/usr/local/bin/uv` on the user's PATH. Install via
  `brew install uv` or `curl -LsSf https://astral.sh/uv/install.sh | sh`.
- ~20 GB free disk for the Python venv + mlx-lm + dependencies + at least one
  base model.

---

## Build flow

### One-time setup

```bash
# 1. Apple licence. You'll need to scroll through the EULA and type "agree".
sudo xcodebuild -license accept
```

If you skip this, every tool that uses the Xcode toolchain (including
`brew install`, `swiftc`, `xcodebuild`) will fail with:

```
You have not agreed to the Xcode license agreements. Please run 'sudo xcodebuild -license accept' from within a Terminal window to review and agree to the Xcode and Apple SDKs license.
```

```bash
# 2. XcodeGen for project regeneration.
brew install xcodegen
```

### Project regeneration

`project.yml` is the source of truth for the Xcode project. It globs the source
tree under `MLXStudio/`, declares the entitlements, plist properties, build
settings, asset-catalog config, and schemes.

Every time you:
- Add a new `.swift` file
- Edit `project.yml`
- Change `Info.plist` properties
- Change entitlements
- Add a new resource folder

…run:

```bash
xcodegen generate
```

This writes `MLXStudio.xcodeproj/`. It is **generated, not committed** — it's in
`.gitignore`, because `project.yml` is the source of truth and every fresh clone
runs `xcodegen generate` (see [`INSTALL.md`](../INSTALL.md)). **Don't manually
edit the generated `.xcodeproj` files** — regeneration clobbers your changes; edit
`project.yml` instead.

### Build

For day-to-day development you can either open the project in Xcode
(`open MLXStudio.xcodeproj`) and hit ⌘R, or build from the CLI:

```bash
xcodebuild -project MLXStudio.xcodeproj \
           -scheme MLXStudio \
           -configuration Debug \
           -destination 'platform=macOS' \
           build
```

Add `clean` before `build` if you suspect stale derived data (often needed when
the icon set changes or you flip entitlements).

The built `.app` ends up in
`~/Library/Developer/Xcode/DerivedData/MLXStudio-<hash>/Build/Products/Debug/MLXStudio.app`.

### Run

```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData -name 'MLXStudio.app' -type d | head -1)
open "$APP"
```

…or just open the `.xcodeproj` and hit ⌘R.

---

## First launch

When the user (or you, while developing) runs the app for the first time:

1. The **First Run wizard** steps through:
   - System check (Apple Silicon, macOS ≥ 14, ≥ 16 GB RAM)
   - **Python runtime bootstrap** (the slow part — see below)
   - HuggingFace token (optional — stored in Keychain)
   - Starter coding models picker
   - Done → opens Dashboard

2. The **Python runtime bootstrap** does:
   - Finds `uv` (bundled, then `~/.local/bin`, then PATH)
   - `uv venv ~/Library/Application Support/MLXStudio/runtime/.venv --python 3.11`
   - `uv pip install mlx-lm huggingface_hub datasets safetensors sentencepiece protobuf`
     — this downloads several hundred MB; budget 5-10 minutes on first run
   - Copies helper Python scripts from the app bundle into `.venv/../helpers/`
   - `import mlx_lm` smoke test → ready

Subsequent launches do `bootstrapIfNeeded()` which just verifies the venv works
and (always) refreshes helper scripts.

---

## Iterating

Common dev-loop tasks and how to do them quickly.

### "I edited a Swift file and want to test"

Just hit ⌘R in Xcode. If you've added a new file, do
`xcodegen generate` first so XcodeGen picks it up.

### "I edited a Python helper and want to test"

If the app is running, just relaunch it — `bootstrapIfNeeded()` copies helpers
on every launch, so the new version takes effect. If you want to skip the
relaunch, run the helper directly:

```bash
~/Library/Application\ Support/MLXStudio/runtime/.venv/bin/python \
  MLXStudio/Resources/helpers/<helper>.py <args>
```

### "I edited the app icon"

```bash
python tools/make_icon.py        # regenerates all 10 PNG sizes
xcodegen generate                # picks up Contents.json changes
xcodebuild ... clean build       # ensures Assets.car re-compiles
killall Dock                     # flushes macOS Icon Services cache
open <new .app>
```

The Dock cache is the most annoying part — without `killall Dock` you'll see the
old icon even though the new one is in the bundle.

### "I changed entitlements / Info.plist"

Same as icon: `xcodegen generate && xcodebuild clean build`. Entitlements
changes require a fresh code sign, which `clean build` triggers.

### "I want to wipe the user data and start fresh"

```bash
rm -rf ~/Library/Application\ Support/MLXStudio/
```

This nukes the venv, models, datasets, adapters, exports, and SwiftData store.
First launch will rebuild everything.

You might also want to clear the macOS Icon Services cache + relaunch the Dock:

```bash
killall Dock
killall Finder
```

---

## Troubleshooting

### Build fails with "You have not agreed to the Xcode license agreements"

Run `sudo xcodebuild -license accept` and scroll-then-`agree`. This affects
every Xcode tool, including `brew` when it builds something from source.

### `xcodebuild` complains about a missing file you just added

You skipped `xcodegen generate`. Run it; rebuild.

### Swift 6 concurrency error: "Static property 'x' is not concurrency-safe"

You declared a `static let` of a non-Sendable type (typically a `Regex` value).
Add `nonisolated(unsafe)`:

```swift
nonisolated(unsafe) private static let myRegex = /pattern/
```

See [`Core/LogStreamParser.swift`](../MLXStudio/Core/LogStreamParser.swift) for examples.

### Swift 6 concurrency error: "Sending 'job' risks data races"

You captured a SwiftData `@Model` instance into a `Task.detached`. Use the
re-fetch pattern (see [`CONVENTIONS.md#pattern-re-fetch-swiftdata-model-by-uuid-inside-tasks`](CONVENTIONS.md#pattern-re-fetch-swiftdata-model-by-uuid-inside-tasks)):

```swift
Task { @MainActor in
    if let job = fetchJob(id: jobID, context: context) { … }
}
```

### App icon is wrong / shows generic Xcode placeholder

macOS aggressively caches Dock icons. Steps:

1. Confirm assets are in the bundle:
   `ls <app-path>/Contents/Resources/AppIcon.icns`
2. Re-register the app:
   `lsregister -f <app-path>`
3. Flush the Dock + Finder caches:
   `killall Dock; killall Finder`
4. Reopen.

Full path: `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister`.

### App launches but training immediately fails with "exit 1"

Open the latest job folder:

```bash
ls -t ~/Library/Application\ Support/MLXStudio/adapters/ | head -1
```

Read `config.yaml`. Common culprit: `model:` is a bare folder name (no `/`).
mlx-lm interprets bare strings as HF repos and bails. Fix: ensure
`TrainingConfigView.resolveModelArg()` resolves your model to an absolute path
before writing the YAML. See [`CONVENTIONS.md#local-model-paths-must-be-resolved-before-being-passed-to-mlx-lm`](CONVENTIONS.md#local-model-paths-must-be-resolved-before-being-passed-to-mlx-lm).

### Training works but loss is NaN

Three known causes:

1. **Pathological dataset** (extreme row sizes that overflow after truncation).
   Try a different dataset; if every dataset NaNs, it's not the data.
2. **Unstable LoRA config** for that specific model (e.g. q+k+v+o targets on
   Qwen3.6-27B + Magicoder-Evol). Reduce target keys to `q+v` or reduce
   `learning_rate`.
3. **A bug in our weight rewriter** (strip-vision saved with wrong dtype, etc.)
   — verify by training the unstripped equivalent with identical config. If
   that NaNs too, it's not our bug.

See the diagnostic procedure used in
[`STATE.md#known-numerical-issues`](STATE.md#known-numerical-issues).

### `xcodegen generate` complains about an old project format

```bash
brew upgrade xcodegen
```

We target XcodeGen 2.43+.

### "Permission denied" when running `uv`

The bundled `uv` binary needs to be marked executable. The `PythonRuntime.resolveUV()`
code does this:

```swift
try FileManager.default.setAttributes(
    [.posixPermissions: 0o755],
    ofItemAtPath: dest.path
)
```

If you've shipped a `uv` binary in `Resources/`, ensure it's not stripped of its
executable bit during code signing.

### macOS Gatekeeper blocks launch of the built `.app`

The Debug build is ad-hoc signed (`CODE_SIGN_IDENTITY: "-"`). For local dev this
is fine. If you want to share the built app with someone else, you'll need to
sign it with a Developer ID — see [`STATE.md#notarization-todos`](STATE.md#notarization-todos).

### `mlx_lm` deprecation warnings in training stdout

You're using the old form (`python -m mlx_lm.lora`). Switch to the subcommand
form (`python -m mlx_lm lora`) — see
[`CONTRACTS.md#1-the-mlx-lm-cli-surface`](CONTRACTS.md#1-the-mlx-lm-cli-surface).
The deprecation lines also pollute the parser; if `LogStreamParser` starts
mis-matching, this is the first thing to check.

### "Couldn't find any data file at /path/to/dataset"

mlx-lm couldn't find your dataset directory. The path passed to `mlx_lm lora`'s
`data:` field must be an **absolute** path that contains `train.jsonl`. Verify:

```bash
ls -la <data-path>/train.jsonl
```

If the file exists but mlx-lm still complains, you might be passing a UUID-named
dataset that's been deleted out from under SwiftData (orphan dataset reference).

### Helper script silently does nothing

Check stderr too. ProcessRunner's stderr handler in the Swift wrapper is often
set to `{ _ in }` to keep the JSON-event log clean — but during debugging,
temporarily log stderr to see Python tracebacks:

```swift
onStderr: { line in print("[stderr] \(line)") }
```

---

## Performance tips for development

### Faster iteration on subprocess code

Run helpers from the CLI before integrating them into a Swift service. The venv
Python is at:

```
~/Library/Application Support/MLXStudio/runtime/.venv/bin/python
```

Test JSON-event output by running with `tee` to see what the Swift side will receive:

```bash
~/Library/Application\ Support/MLXStudio/runtime/.venv/bin/python \
    MLXStudio/Resources/helpers/your_helper.py args... \
    2>&1 | tee /tmp/helper.log
```

### Faster training-feedback loop

When testing training logic (not training quality), use:
- Llama-3.2-1B (fast load, small memory)
- A 200-row dataset
- 5-10 iters

A full smoke test takes about 90 seconds. Don't test training plumbing on Qwen-32B
unless you specifically need to.

### Avoid downloading the same model twice

If you delete a local model from the Models tab UI, the underlying files are
gone (see `ModelRegistry.delete`). To avoid re-downloading, keep them around
during development. Or use `mlx-community/Llama-3.2-1B-Instruct-4bit` (~700 MB)
as your test model — it downloads in seconds.

---

## CI / packaging (future work)

Currently we build only locally. A future CI setup would need:

- A self-hosted macOS runner (GitHub-hosted runners can't run Xcode 26 yet for free)
- Cached uv + brew caches
- A signing identity for shareable Debug builds
- The above plus notarization for Release builds

See [`STATE.md#notarization-todos`](STATE.md#notarization-todos) for what
notarization specifically requires.
