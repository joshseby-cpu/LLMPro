# Security Policy

## Supported versions

LLMPro is pre-1.0 and ships from `main`. Only the **latest** release / `main`
commit receives security fixes.

| Version | Supported |
|---------|-----------|
| latest (`main`) | ✅ |
| older commits   | ❌ |

## Reporting a vulnerability

**Please do not open a public issue for security vulnerabilities.**

Report privately via either:

- **GitHub private vulnerability reporting** — the repo's **Security** tab →
  *"Report a vulnerability"* (preferred), or
- **Email** — joshseby@gmail.com

Please include: a description, reproduction steps, affected version/commit, and
the potential impact. You'll get an acknowledgement, and a fix or mitigation will
be prioritized for the latest version.

## Security model (what to keep in mind)

LLMPro is a **local** macOS app, but a few things are worth understanding:

- **It bundles a Python sidecar.** A `uv`-managed venv runs `mlx-lm` and helper
  scripts as subprocesses (never `libpython` linked in-process). The app requires
  hardened-runtime entitlements (JIT / unsigned executable memory) to spawn it.
- **The Code tab is an agentic coding assistant.** A local model can read/write
  files in the chosen workspace and run shell commands via tools. As of the latest
  hardening, **auto-approve edits and auto-run commands default to OFF** (each
  action goes through a human approval gate), the `run_command` child environment
  is scrubbed of secret-bearing variables, `fetch_url` blocks loopback/private/
  link-local targets (SSRF guard), and the file tools resolve symlinks so they
  can't escape the workspace. Treat fine-tuned/imported models as untrusted code
  generators and keep the approval gates on for untrusted prompts.
- **No telemetry / network beacons.** The app talks to HuggingFace (model/dataset
  search + download) and your chosen local servers only.

If you find a way around any of the above, that's exactly the kind of report we
want — thank you.
