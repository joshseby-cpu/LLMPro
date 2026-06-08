# Reference projects (prior art & upstream)

> 📝 **Maintainers**: this doc is *context*, not a contract. It lists the external
> projects that informed LLMPro's design, and the one we actually depend on at
> runtime. When you add a feature that borrows a pattern from one of these — or
> when you reach for "how does $TOOL do this?" — note the link here so the next
> agent has the same map. Nothing here is imported except **mlx** (see
> [`CONTRACTS.md`](CONTRACTS.md)); the rest are design references we read, not code
> we ship. Some entries are pointers a maintainer supplied for context / future
> direction — they need not have shaped a shipped feature yet.

LLMPro is one closed feedback loop — **download → fine-tune → test → use in the
Code agent → retrain** (see [`CONCEPT.md`](CONCEPT.md)). Each stage has well-known
open-source prior art. These are the projects we looked at while building, grouped
by the stage / concern they map to.

---

## Runtime dependency (we actually ship/call this)

| Project | Why it matters here |
|---|---|
| **mlx** — <https://github.com/ml-explore/mlx> | Apple's array framework for Apple-Silicon ML (Metal). Its `mlx-lm` layer is the **engine of the whole app**: every training, inference, and Code-agent-server call is a `python -m mlx_lm …` subprocess (see [`CONTRACTS.md`](CONTRACTS.md#1-the-mlx-lm-cli-surface) and [`CONVENTIONS.md`](CONVENTIONS.md#apple-silicon-mlx-memory-tuning-runs-on-every-mlx_lm-call)). This is the only "reference" we depend on rather than merely consult. |

---

## ① Agentic coding (the Code tab / Orchestrator team)

Prior art for the multi-agent Code tab — orchestration, tools, SKILL.md packages,
markdown-defined agents, the `ask_user`/`remember` control tools, the autonomous
run loop, and reasoning/chain-of-thought handling. See
[`CONVENTIONS.md`](CONVENTIONS.md) (the Code-tab sections) and
[`ARCHITECTURE.md`](ARCHITECTURE.md).

| Project | Relevance |
|---|---|
| **claw-code** — <https://github.com/ultraworkers/claw-code> | Lightweight LLM agentic-coding harness — reference for a small, local-first coding agent loop. |
| **opencode** — <https://github.com/anomalyco/opencode> | Open agentic coding assistant — reference for tool design and the edit/run/approve flow. |
| **pi** — <https://github.com/earendil-works/pi> | Coding-agent with on-demand **skills** (`/skill:name`) and TypeScript **extensions** — a direct influence on our Agent Skills model (SKILL.md packages + progressive disclosure). |
| **autoresearch-mlx** — <https://github.com/trevin-creator/autoresearch-mlx> | Fixed-time **autonomous research/agent loops on MLX**. An MLX-native autonomous-loop reference — pointer for time-boxed agent runs: the same instinct behind Teach's Quick/Standard/Thorough budgets ([`AutoTuner`](../LLMPro/Services/AutoTuner.swift) `TrainingDuration`) and a candidate shape for a time-budgeted Code/Practice run. |
| **query-llm** — <https://github.com/ariya/query-llm> | Asking questions with **chain-of-thought** (and RAG) against local LLMs. Reference for the Code agent's reasoning path — the `reasoning`-delta / `letModelThink` handling in [`OpenAIChatClient`](../LLMPro/Services/OpenAIChatClient.swift) + [`CodingAgentService`](../LLMPro/Services/CodingAgentService.swift) — and for CoT prompting in the Arena. |

Adjacent specs we follow for the skills + agents format (linked where used):
OpenAI Codex Skills and Anthropic Agent Skills — see the SKILL.md format in
[`CONTRACTS.md`](CONTRACTS.md) and the design notes in [`CONVENTIONS.md`](CONVENTIONS.md).

## ② Local fine-tuning (Teach / the training pipeline)

| Project | Relevance |
|---|---|
| **mlx** — <https://github.com/ml-explore/mlx> | The trainer (LoRA/DoRA via `mlx_lm lora`). Also listed above as the runtime dependency. |
| **unsloth** — <https://github.com/unslothai/unsloth> | Faster/cheaper fine-tuning. **Reference only — not importable here** (CUDA/Triton/xformers kernels; the "macOS/MLX" in its README is a separate product). We adopted the *portable, algorithm-side* ideas (DoRA, warmup→cosine LR schedule) on MLX instead — see [`CONVENTIONS.md`](CONVENTIONS.md#smarter-fine-tune-recipe-dora--lr-schedule--the-mlx-native-answer-to-unsloth). |

## ③ Reward / preference & self-improvement training (future direction)

Prior art for the **Practice tab** (recursive self-improvement). Today Practice does
the simplest shape that works — **rejection-sampling self-distillation** gated by
unit tests (see [`CONVENTIONS.md`](CONVENTIONS.md#why-rejection-sampling-self-distillation-not-dpo--rlaif--agent-rewriting-code)).
These are the richer techniques we'd reach for if/when we go further.

| Project | Relevance |
|---|---|
| **OpenRLHF** — <https://github.com/OpenRLHF/OpenRLHF> | RLHF/PPO/DPO **at scale, with an automated judge**. Reference for *if/when* we go beyond rejection-sampling self-distillation in Practice. The full automated-RLHF pipeline is not used today. **NOTE:** a **human-judged DPO** loop *has* shipped — the Arena's "Teach by preference" (via the separate `mlx-lm-lora` package, since `mlx_lm lora` itself has no DPO trainer); see [`CONVENTIONS.md`](CONVENTIONS.md#dpo-preference-loop-via-on-demand-mlx-lm-lora) + [`CONTRACTS.md`](CONTRACTS.md#mlx_lm_loratrain--dpo-preference-training-separate-package). |
| **AlphaLLM** — <https://github.com/YeTianJHU/AlphaLLM> | Self-improving LLM via **imagination, MCTS searching, and criticizing** ("Towards Self-Improvement of LLMs via …"). Prior art for a *search/critique-guided* alternative to our linear rejection-sampling loop — a pointer for making the Practice retrain edge smarter (tree search + a critic over candidate solutions) rather than just first-pass keep. Not used today. |

## ④ Model modification (uncensoring)

| Project | Relevance |
|---|---|
| **heretic** — <https://github.com/p-e-w/heretic> | Automated refusal-direction removal ("decensoring"). Prior art for our **abliterate** helper (`abliterate.py` — refusal-direction projection); see [`CONTRACTS.md`](CONTRACTS.md#3-helper-script-protocol) and the Models→Modify flow in [`WORKFLOWS.md`](WORKFLOWS.md). |

## ⑤ Evaluation (Try it out / Practice grading)

| Project | Relevance |
|---|---|
| **llm-checker** — <https://github.com/Pavelevich/llm-checker> | Local LLM evaluation/benchmarking. Reference for our eval surfaces — the scored Test node (`EvalService` → `EvalRun`, pass@k via `eval_pass_rate.py`) and the Practice held-out eval — and a pointer for richer eval (more suites, a custom-suite authoring UI) if we expand them. |

## ⑥ Agent management / orchestration UX (comparison)

| Project | Relevance |
|---|---|
| **Flowise** — <https://github.com/FlowiseAI/Flowise> | Visual builder for LLM agents/flows. A UX *contrast*: LLMPro deliberately uses **editable Markdown files** for agents and skills (CRUD + linking) rather than a node graph — but Flowise is the reference point for the agent-manager problem space. |

## ⑦ Visualization (Progress charts / Practice trend)

| Project | Relevance |
|---|---|
| **ai-llm-data-visualizer** — <https://github.com/flavioespinoza/ai-llm-data-visualizer> | LLM-driven data visualization. Reference for our metric-visualization surfaces — the friendly **Progress** tab charts (loss / val-loss curves, 5-star learning rating) and the **Practice** pass@1 trend chart — and a pointer for richer, possibly LLM-narrated, in-app charts. |

---

### How these map to the loop

```
DOWNLOAD ─▶ FINE-TUNE ─▶ TEST ─▶ USE (Code agent) ─▶ (retrain ↩)
            ②mlx,unsloth   ⑤llm-checker  ①claw-code,opencode,pi,
   model    ③OpenRLHF,AlphaLLM            ①autoresearch-mlx,query-llm
            (self-improve, future)        ④heretic (off-loop: Modify)
                                          ⑥Flowise (agent-manager UX contrast)
   ⑦ai-llm-data-visualizer — viz across Progress (FINE-TUNE) + Practice (retrain)
```
