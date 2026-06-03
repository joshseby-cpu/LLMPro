# Installing MLX Studio on your Mac

This guide takes you from a fresh Mac to a running copy of **MLX Studio** — a
native macOS app for fine-tuning and running local LLMs on Apple Silicon.

There is no pre-built download yet, so you build the app once on your own Mac.
It sounds harder than it is: copy-paste five setup commands, run one build
command, and open the app. Budget **30–60 minutes** the first time (most of it is
Xcode and model downloads, not work you have to babysit).

> Already a developer with Xcode + Homebrew set up? Jump to
> [The 4 commands](#the-4-commands-for-people-in-a-hurry).

---

## 1. Check your Mac can run it

| Requirement | Why | How to check |
|---|---|---|
| **Apple Silicon** (M1, M2, M3, M4, …) | The ML engine (MLX) is Apple-GPU only. **Intel Macs are not supported.** |  → About This Mac → "Chip" should say *Apple M…* |
| **macOS 14 (Sonoma) or newer** | The app uses modern Apple frameworks | → About This Mac → look at the version |
| **16 GB memory or more (recommended)** | Models are big. 8 GB runs only tiny models; 32 GB+ is comfortable; 64–128 GB for large models | → About This Mac → "Memory" |
| **~20 GB free disk** | Python runtime + at least one model | Finder → right-click your drive → Get Info |

Open  (Apple menu) → **About This Mac** to check all four at once. If the chip
isn't "Apple M-something," this app won't run on your machine — stop here.

---

## 2. Install the prerequisites (one time)

You need four things: **Xcode**, the **Xcode command-line tools**, **Homebrew**,
and two small tools (`xcodegen` and `uv`). Do these in order.

### 2a. Xcode 26 or newer

Install **Xcode** from the **Mac App Store** (free, but it's a large ~15 GB
download — start it first and let it run while you read on).

Search "Xcode" in the App Store → Get → wait for it to finish → **open Xcode
once** so it can install its extra components, then quit it.

> ⚠️ You need **Xcode 26 or newer** (it uses the Swift 6 toolchain). If the App
> Store gives you an older Xcode because your macOS is older, you'll need to
> update macOS first, or download Xcode 26 from
> [developer.apple.com/download](https://developer.apple.com/download/all/)
> (free Apple ID required).

### 2b. Open Terminal

Everything below is typed into **Terminal**. Open it via Spotlight: press
**⌘ Space**, type `Terminal`, press Return.

### 2c. Command-line tools + accept the licence

```bash
xcode-select --install        # if it says "already installed", that's fine
sudo xcodebuild -license accept
```

The second command asks for your Mac password (you won't see it as you type —
that's normal), then makes you scroll through Apple's licence; type `agree` at
the end.

### 2d. Homebrew (the macOS package manager)

If you don't already have it:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

After it finishes it prints **two `eval` commands** — copy-paste and run them so
`brew` works in your current Terminal (or just close and reopen Terminal).

Check it worked:

```bash
brew --version
```

### 2e. The two build tools

```bash
brew install xcodegen uv
```

- **`xcodegen`** generates the Xcode project from the repo's `project.yml`.
- **`uv`** is a fast Python installer. **MLX Studio needs it** — the app uses it
  on first launch to set up its Python environment. Don't skip it.

Confirm both:

```bash
xcodegen --version
uv --version
```

---

## 3. Get the code

If you received a **link to a Git repository**, clone it:

```bash
cd ~/Documents
git clone <REPOSITORY-URL> MLXStudio
cd MLXStudio
```

If you received the project as a **`.zip` folder**, unzip it, then in Terminal
`cd` into the unzipped folder (you can type `cd ` with a trailing space and then
drag the folder onto the Terminal window to fill in the path):

```bash
cd ~/Downloads/MLXStudio       # adjust to wherever you put it
```

You're in the right folder if this command lists a file:

```bash
ls project.yml                 # should print: project.yml
```

---

## 4. Build the app

Two ways — pick one.

### Option A — All in Terminal (fastest, fewest clicks)

From inside the project folder:

```bash
xcodegen generate
xcodebuild -project MLXStudio.xcodeproj -scheme MLXStudio \
           -configuration Debug -destination 'platform=macOS' build
```

The first build takes a few minutes. When it finishes you'll see
**`** BUILD SUCCEEDED **`** near the end. (Warnings in yellow are fine; only a
red `** BUILD FAILED **` is a problem — see [Troubleshooting](#troubleshooting).)

### Option B — Use the Xcode app (nice if you prefer clicking)

```bash
xcodegen generate
open MLXStudio.xcodeproj
```

Xcode opens. At the very top, make sure the scheme selector says **MLXStudio**
and the run target is **My Mac**. Then press the **▶︎ Run** button (or **⌘ R**).
Xcode builds and launches the app for you — and any errors show up inline. With
this option you can skip step 5.

---

## 5. Run it

If you built with Option A (Terminal), launch the app you just built:

```bash
open ~/Library/Developer/Xcode/DerivedData/MLXStudio-*/Build/Products/Debug/MLXStudio.app
```

(If that doesn't find it, run
`find ~/Library/Developer/Xcode/DerivedData -name 'MLXStudio.app' -type d` and
`open` the path it prints.)

Because **you** built it on **your** Mac, macOS trusts it — Gatekeeper won't
block it. (If someone instead hands you a pre-built `MLXStudio.app`, see
[the Gatekeeper note](#someone-gave-me-a-pre-built-app-and-it-wont-open).)

---

## 6. First launch — what to expect

The first time the app opens it runs a short **setup wizard**. Be on **Wi-Fi** —
this step downloads software and a model.

1. **System check** — confirms Apple Silicon, macOS version, memory.
2. **Python runtime setup** — the app creates its own private Python environment
   and installs the ML libraries (mlx-lm and friends). **This downloads several
   hundred MB and takes 5–10 minutes.** It only happens once. A progress bar
   keeps you posted; you don't have to do anything.
3. **HuggingFace token** *(optional)* — skip it unless you plan to download
   gated/private models. You can add it later in **Settings**.
4. **Pick a starter model** — choose a small one for your first run (e.g. a
   Llama 3.2 1B/3B). This downloads in the background.
5. **Done** — you land on the Home screen.

Everything the app creates lives in one folder:
`~/Library/Application Support/MLXStudio/` (the Python environment, models,
datasets, and your fine-tuned results). Nothing is installed system-wide.

That's it — you're running MLX Studio. For what to do next (download a model →
pick lessons → Teach → Try it out), see the **Quick start** section of
[`README.md`](README.md).

---

## The 4 commands (for people in a hurry)

You already have Xcode 26+, Homebrew, and an Apple-Silicon Mac:

```bash
brew install xcodegen uv
cd <the project folder>
xcodegen generate
xcodebuild -project MLXStudio.xcodeproj -scheme MLXStudio -configuration Debug -destination 'platform=macOS' build
open ~/Library/Developer/Xcode/DerivedData/MLXStudio-*/Build/Products/Debug/MLXStudio.app
```

---

## Troubleshooting

### "You have not agreed to the Xcode license agreements"
Run `sudo xcodebuild -license accept`, scroll to the end, and type `agree`.

### `xcodebuild: command not found` or it points at the wrong Xcode
Tell the system to use the full Xcode (not just the command-line tools):

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Then check `xcodebuild -version` shows **26.x or higher**. If it shows an older
version, install/update Xcode (step 2a).

### `** BUILD FAILED **` mentioning a missing file, or Xcode shows fewer files than expected
You edited or re-downloaded the project without regenerating it. Run
`xcodegen generate` again, then rebuild.

### `xcodegen: command not found`
`brew install xcodegen` didn't run or your PATH isn't set up. Re-run the two
`eval` lines Homebrew printed during install (or close and reopen Terminal),
then `brew install xcodegen` again.

### First-launch setup fails / "couldn't find uv" / Python step errors
The app couldn't find `uv`. Install it and relaunch the app:

```bash
brew install uv
```

If it's installed but still not found, confirm it's on your PATH with
`uv --version`. (The app looks for `uv` via Homebrew at `/opt/homebrew/bin/uv`
and `~/.local/bin/uv`.)

### The Python setup is stuck or failed partway
Make sure you're online, then reset just the runtime: open the app →
**Settings → Runtime → "Recreate venv"**. Or wipe everything and start clean
(see below).

### Build is slow / the app feels stuck downloading
First builds and first model downloads are genuinely slow (Xcode compiling,
hundreds of MB of Python packages, then a model). Give it time and keep Wi-Fi
on. Subsequent launches are fast.

### "Someone gave me a pre-built app and it won't open"
A `.app` built on a *different* Mac is ad-hoc signed, so macOS quarantines it.
**Right-click the app → Open → Open** (do this once), or remove the quarantine
flag:

```bash
xattr -dr com.apple.quarantine /path/to/MLXStudio.app
```

This does **not** apply if you built the app yourself with the steps above.

### Start completely fresh
This deletes the app's Python environment, downloaded models, datasets, and your
fine-tuned results (it does **not** touch the source code):

```bash
rm -rf ~/Library/Application\ Support/MLXStudio
```

Relaunch the app and the first-launch setup runs again.

---

## Need more?

- **Deeper build details, dev workflow, and advanced troubleshooting:**
  [`docs/BUILDING.md`](docs/BUILDING.md)
- **What the app does and how to use it:** [`README.md`](README.md)
- **How everything fits together (for contributors):** [`CLAUDE.md`](CLAUDE.md)
</content>
