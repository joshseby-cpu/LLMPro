# Installing the pre-built LLMPro app

Don't want to build from source? Download the ready-made app from the
[**Releases**](https://github.com/joshseby-cpu/LLMPro/releases) page.

> ⚠️ **This build is *not* notarized by Apple.** It's signed only ad-hoc (this is a
> free, AI-written hobby project — see the README). macOS will refuse to open it on
> the first try and you must explicitly allow it (steps below). If that bothers you,
> [build from source](../INSTALL.md) instead — a build you make yourself is trusted
> automatically.

---

## 1. Requirements

- **Apple Silicon Mac** (M1 or later). Intel Macs are **not** supported.
- **macOS 14 (Sonoma) or newer.**
- **`uv`** installed (the app uses it to set up its Python environment on first
  launch):
  ```bash
  brew install uv
  ```
  (No Homebrew? `curl -LsSf https://astral.sh/uv/install.sh | sh`)
- **~20 GB free disk** + Wi-Fi for the one-time first-launch download.

## 2. Download

1. Go to [**Releases**](https://github.com/joshseby-cpu/LLMPro/releases).
2. Download `LLMPro-vX.Y.Z-macos-arm64.zip` from the latest release.
3. Double-click the zip to unzip it → you get **`LLMPro.app`**.
4. Drag **`LLMPro.app`** into your **Applications** folder.

## 3. Open it the first time (the Gatekeeper step)

Because the app isn't notarized, the **first** launch needs you to allow it. Pick
either way:

**Easiest — Terminal (one command):**
```bash
xattr -dr com.apple.quarantine /Applications/LLMPro.app
```
Then double-click LLMPro normally.

**Or — System Settings:**
1. Double-click `LLMPro.app`. macOS says it "cannot be opened" — click **Done**.
2. Open  → **System Settings → Privacy & Security**.
3. Scroll down; you'll see *"LLMPro was blocked…"* → click **Open Anyway**.
4. Confirm **Open Anyway** again, and authenticate.

> On older macOS you could right-click → Open; on macOS 15+ use one of the methods
> above instead.

You only do this **once**. After that, LLMPro opens like any normal app.

## 4. First launch

The app runs a short setup wizard (be on Wi-Fi):

1. System check (Apple Silicon, macOS, memory).
2. **Python runtime setup** — creates a private Python env and installs the ML
   libraries. **Downloads several hundred MB; 5–10 minutes; one time only.**
3. HuggingFace token (optional — skip unless you need gated models).
4. Pick a starter model (it downloads in the background).
5. Done → Home screen.

Everything the app creates lives in `~/Library/Application Support/LLMPro/`. To
fully remove it later: drag `LLMPro.app` to the Trash and
`rm -rf ~/Library/Application\ Support/LLMPro`.

---

## Troubleshooting

**"LLMPro is damaged and can't be opened. Move it to the Trash."**
This is the quarantine flag, not real damage. Run:
```bash
xattr -dr com.apple.quarantine /Applications/LLMPro.app
```

**First-launch setup fails / "couldn't find uv".**
Install uv (`brew install uv`) and relaunch. If it's installed but not found, make
sure `uv --version` works in Terminal.

**Want the no-warning experience?** [Build it yourself](../INSTALL.md) — locally
built apps are trusted by macOS automatically, no Gatekeeper step.
