#!/usr/bin/env python3
"""End-to-end smoke test for MLX Studio's coding agent.

Faithfully mirrors the Swift implementation:
  - MLXServerService: start `python -m mlx_lm server`, poll /health, warm up.
  - CodingAgentService: the tool-use loop (native tool_calls OR <tool_call> text
    fallback; feed results back; stop when no tool calls; iteration cap).
  - AgentTools/ToolExecutor: read_file/list_dir/grep/write_file/edit_file/run_command,
    sandboxed to a workspace dir.

It proves the server + OpenAI tool protocol + loop work against a REAL model.
Run: python3 agent_smoke.py <model_snapshot_path>
"""
import json, os, re, socket, subprocess, sys, tempfile, time, urllib.request, shutil

MAX_OUTPUT = 16000
MAX_ITERS = 12

# ---- tool specs (mirror AgentTools.specs) ----
def tool_specs():
    def spec(name, desc, props, required):
        return {"type": "function", "function": {"name": name, "description": desc,
                "parameters": {"type": "object",
                               "properties": {k: {"type": "string", "description": v} for k, v in props.items()},
                               "required": required}}}
    return [
        spec("read_file", "Read a UTF-8 text file from the project.", {"path": "rel path"}, ["path"]),
        spec("list_dir", "List a folder.", {"path": "rel path"}, []),
        spec("glob", "Find files by glob pattern, e.g. **/*.py.", {"pattern": "glob pattern"}, ["pattern"]),
        spec("grep", "Search the project (regex).", {"pattern": "regex", "path": "optional subpath"}, ["pattern"]),
        spec("write_file", "Create or overwrite a file.", {"path": "rel path", "content": "full contents"}, ["path", "content"]),
        spec("edit_file", "Replace first exact old_string with new_string (set replace_all true for all).", {"path": "rel", "old_string": "x", "new_string": "y", "replace_all": "optional"}, ["path", "old_string", "new_string"]),
        spec("run_command", "Run a shell command in the project root.", {"command": "cmd"}, ["command"]),
        spec("todo_write", "Record/update your plan as a checklist.", {"todos": "JSON array of {content,status}"}, ["todos"]),
    ]

# ---- fallback parser (mirror AgentTools.parseFallbackCalls) ----
def _sanitize_tool_json(s):
    # Strip leaked model special tokens that corrupt the JSON (e.g. gemma emits
    # `<|"|>`, `<tool_call|>`, `<end_of_turn>`). Mirrors AgentTools.sanitizeToolBlock.
    s = re.sub(r"<\|.*?\|>", "", s, flags=re.DOTALL)
    s = re.sub(r"</?tool_call\|>", "", s)
    for t in ("<end_of_turn>", "<start_of_turn>", "<eos>", "<bos>"):
        s = s.replace(t, "")
    return s.strip()

def parse_fallback(content):
    calls = []
    for i, m in enumerate(re.findall(r"<tool_call>(.*?)</tool_call>", content, re.DOTALL)):
        try:
            obj = json.loads(_sanitize_tool_json(m))
            if "name" in obj:
                calls.append({"id": f"fb_{i}", "name": obj["name"],
                              "args": obj.get("arguments", obj.get("parameters", {}))})
        except Exception:
            pass
    return calls

# ---- sandboxed executor (mirror ToolExecutor) ----
def sandboxed(workspace, rel):
    rel = (rel or "").strip()
    joined = rel if rel.startswith("/") else os.path.join(workspace, rel)
    std = os.path.normpath(joined)
    root = os.path.normpath(workspace)
    if std != root and not std.startswith(root + os.sep):
        raise ValueError(f"path {rel} outside workspace")
    return std

def truncate(s):
    return s if len(s) <= MAX_OUTPUT else s[:MAX_OUTPUT] + f"\n… (truncated {len(s)-MAX_OUTPUT} chars)"

def execute(workspace, name, args):
    try:
        if name == "read_file":
            with open(sandboxed(workspace, args["path"]), encoding="utf-8") as f:
                return truncate(f.read()), False
        if name == "list_dir":
            d = sandboxed(workspace, args.get("path") or ".")
            return truncate("\n".join(sorted(os.listdir(d))) or "(empty)"), False
        if name == "glob":
            import fnmatch
            pat = args["pattern"]; base = "/" not in pat; hits = []
            for root, dirs, files in os.walk(workspace):
                dirs[:] = [d for d in dirs if d not in (".git", "node_modules", ".build")]
                for f in files:
                    rel = os.path.relpath(os.path.join(root, f), workspace)
                    target = f if base else rel
                    # fnmatch with ** support via translate-ish: treat ** as *
                    if fnmatch.fnmatch(target, pat.replace("**/", "*").replace("**", "*")):
                        hits.append(rel)
            return truncate("\n".join(sorted(hits)) or f"No files match {pat}."), False
        if name == "grep":
            root = sandboxed(workspace, args["path"]) if args.get("path") else workspace
            r = subprocess.run(["/usr/bin/grep", "-rInE", "--exclude-dir=.git", "-e", args["pattern"], root],
                               capture_output=True, text=True, timeout=30)
            out = r.stdout.replace(workspace + "/", "")
            return truncate(out or "No matches."), False
        if name == "write_file":
            p = sandboxed(workspace, args["path"])
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w", encoding="utf-8") as f:
                f.write(args["content"])
            return f"Wrote {len(args['content'].encode())} bytes to {args['path']}.", False
        if name == "edit_file":
            p = sandboxed(workspace, args["path"])
            with open(p, encoding="utf-8") as f:
                text = f.read()
            if args["old_string"] not in text:
                return "old_string not found.", True
            with open(p, "w", encoding="utf-8") as f:
                f.write(text.replace(args["old_string"], args["new_string"], 1))
            return f"Edited {args['path']}.", False
        if name == "run_command":
            r = subprocess.run(["/bin/zsh", "-lc", args["command"]], cwd=workspace,
                               capture_output=True, text=True, timeout=120)
            return truncate(f"exit code: {r.returncode}\n{r.stdout}{r.stderr}"), r.returncode != 0
        if name == "todo_write":
            todos = args.get("todos")
            if isinstance(todos, str):
                try: todos = json.loads(todos)
                except Exception: todos = []
            return f"Plan updated: {len(todos or [])} items.", False
        return f"unknown tool {name}", True
    except Exception as e:
        return f"{type(e).__name__}: {e}", True

SYSTEM = """You are a coding agent working inside the project at:
{dir}
Tools (paths relative to project root): read_file, list_dir, glob, grep, write_file, edit_file, run_command, todo_write.
Investigate first, then make focused changes, then verify. When finished, reply with a short plain-text summary and DO NOT call more tools.
If function calling is unavailable, emit each call on its own line as:
<tool_call>{{"name": "read_file", "arguments": {{"path": "x.py"}}}}</tool_call>
Take one step at a time."""

def post(base, payload):
    req = urllib.request.Request(base + "/chat/completions",
                                 data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=600) as r:
        return json.loads(r.read())

def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p

def wait_health(port, timeout=40):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2); return True
        except urllib.error.HTTPError:
            return True
        except Exception:
            time.sleep(0.4)
    return False

def main():
    model = sys.argv[1]
    py = sys.executable
    port = free_port()
    base = f"http://127.0.0.1:{port}/v1"
    env = dict(os.environ, PYTHONUNBUFFERED="1")
    print(f"[server] starting on :{port}")
    proc = subprocess.Popen([py, "-m", "mlx_lm", "server", "--model", model,
                             "--host", "127.0.0.1", "--port", str(port), "--log-level", "INFO"],
                            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    workspace = tempfile.mkdtemp(prefix="agent_ws_")
    try:
        if not wait_health(port):
            print("FAIL: server never listened"); return 1
        print("[server] up; warming up (loads model)…")
        t0 = time.time()
        post(base, {"model": model, "messages": [{"role": "user", "content": "ready"}], "max_tokens": 1, "temperature": 0})
        print(f"[server] model loaded in {time.time()-t0:.1f}s")

        # seed workspace
        with open(os.path.join(workspace, "greeting.py"), "w") as f:
            f.write("def greet(name):\n    return f'Hello, {name}! Welcome.'\n\nprint(greet('World'))\n")

        task = ("First call todo_write with a short 3-step plan. Then use glob to find all *.py "
                "files, read greeting.py to see what it prints, and create SUMMARY.md describing it. "
                "Update the plan as you go, then finish.")
        wire = [{"role": "system", "content": SYSTEM.format(dir=workspace)},
                {"role": "user", "content": task}]
        used_native = False
        tool_events = []
        for step in range(1, MAX_ITERS + 1):
            resp = post(base, {"model": model, "messages": wire, "tools": tool_specs(),
                               "temperature": 0.2, "max_tokens": 1024})
            msg = resp["choices"][0]["message"]
            text = msg.get("content") or ""
            native = msg.get("tool_calls") or []
            if native:
                used_native = True
                wire.append({"role": "assistant", "content": text or None, "tool_calls": native})
                for tc in native:
                    name = tc["function"]["name"]
                    args = json.loads(tc["function"]["arguments"] or "{}")
                    out, err = execute(workspace, name, args)
                    tool_events.append((name, args, err))
                    print(f"  step {step} [native] {name}({args}) -> {'ERR' if err else 'ok'}")
                    wire.append({"role": "tool", "tool_call_id": tc["id"], "name": name, "content": out})
                continue
            fb = parse_fallback(text)
            if fb:
                wire.append({"role": "assistant", "content": text})
                results = ""
                for c in fb:
                    out, err = execute(workspace, c["name"], c["args"])
                    tool_events.append((c["name"], c["args"], err))
                    print(f"  step {step} [fallback] {c['name']}({c['args']}) -> {'ERR' if err else 'ok'}")
                    results += f"<tool_result name=\"{c['name']}\">\n{out}\n</tool_result>\n"
                wire.append({"role": "user", "content": results})
                continue
            print(f"  step {step} FINAL: {text[:300]}")
            break

        # verdict
        summary_path = os.path.join(workspace, "SUMMARY.md")
        names = [e[0] for e in tool_events]
        print("\n==== VERDICT ====")
        print(f"tool-calling mode: {'native tool_calls' if used_native else 'text fallback'}")
        print(f"tools invoked: {names}")
        print(f"glob used:      {'glob' in names}")
        print(f"todo_write used:{'todo_write' in names}")
        print(f"read_file used: {'read_file' in names}")
        print(f"write_file/edit used: {any(n in ('write_file','edit_file') for n in names)}")
        ok = os.path.exists(summary_path)
        print(f"SUMMARY.md created: {ok}")
        if ok:
            with open(summary_path) as f:
                print("---- SUMMARY.md ----\n" + f.read()[:500])
        print("RESULT:", "PASS" if (ok and "read_file" in names) else "PARTIAL/INSPECT")
        return 0
    finally:
        proc.terminate()
        try: proc.wait(timeout=5)
        except Exception: proc.kill()
        shutil.rmtree(workspace, ignore_errors=True)
        print("[server] stopped; workspace cleaned")

if __name__ == "__main__":
    sys.exit(main())
