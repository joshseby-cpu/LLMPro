# API + MCP support — implementation contract (shared by all build phases)

> ⚠️ **STATUS: PLANNED / NOT YET IMPLEMENTED.** This is a design document for a
> future feature (OpenAI-compatible API serving + MCP client/server). None of it
> ships yet — it's recorded here so the work is ready to pick up. Don't read it as
> describing current behaviour.

> Working contract for adding **API serving** and **MCP support** to LLMPro.
> Authored 2026-05-31. Each build phase reads this file so all pieces fit. Once
> the feature lands, fold the durable parts into CONTRACTS.md / ARCHITECTURE.md /
> WORKFLOWS.md / CONVENTIONS.md and delete this file.

## Scope (confirmed with the user)

1. **API = serve local models.** Expose the user's local models + fine-tuned LoRA
   adapters over an **OpenAI-compatible HTTP server** (`/v1/chat/completions`,
   `/v1/models`) that other apps on this Mac (Ollama-style clients, LM Studio,
   OpenAI SDKs, editors) can call. This is the "Use it" exit of the loop.
2. **MCP = both directions.**
   - **Client:** the Code-tab agent team can connect to external MCP servers and
     gain their tools alongside the built-in ones.
   - **Server:** LLMPro exposes its own MCP server so other MCP clients
     (Claude Desktop, IDEs) can use its local models.
3. **Network policy = LOCAL-ONLY.** Only **stdio** MCP servers (local
   subprocesses) and **localhost-bound** HTTP. Agents stay **offline by default**
   (preserves the deliberate earlier decision to remove web_search/fetch_url).
   No remote SSE/HTTP MCP transport. No cloud-provider API calls from agents.

## Non-negotiable existing constraints (from CLAUDE.md / CONVENTIONS.md)

- **Swift-first.** MCP client + API-server management are pure Swift. Python only
  for the *exposed* MCP server script (it must be a spawnable command; Python is
  the existing sidecar). Do NOT add a Swift MCP package dependency — hand-roll
  JSON-RPC over the existing `ProcessRunner` (it already supports stdin via
  `spawn(stdin: true)` + `RunningProcess.writeLine(_:)` and a newline-split stdout
  `AsyncStream<String>`).
- **Services do, Views show.** All logic in `Services/`; SwiftUI files stay thin.
- **`@MainActor @Observable final class` singletons** for services; long work in
  `Task { @MainActor in … }`; re-fetch SwiftData `@Model` by UUID inside Tasks.
- **Friendly-first UI**, technical behind disclosure. No emoji in code.
- **Secrets → Keychain** (`KeychainHelper`), flags/config → `AppSettings`
  (SwiftData) or a JSON string field. **Bind servers to `127.0.0.1` only.**
- **Regenerate the Xcode project after adding files** (`xcodegen generate` via
  project.yml — see tools/ and docs/BUILDING.md) and confirm `** BUILD SUCCEEDED **`.
- **Read the logs after testing** (`Log.*` → `llmpro.log`); a green build is
  not a pass on its own.

## AppSettings additions (single source of config)

Add these stored properties to `LLMPro/Models/AppSettings.swift` (defaults keep
everything OFF/offline):

```swift
// --- API server (serve local models over OpenAI-compatible HTTP) ---
var apiServerAutoStart: Bool = false       // start on app launch
var apiServerPort: Int = 8080              // localhost port
var apiServerModelRepoID: String = ""      // last-served model (repoID or local name)
var apiServerAdapterPath: String = ""      // optional LoRA adapter dir ("" = none)

// --- MCP client (agents use external stdio servers) ---
var mcpServersJSON: String = "[]"          // [MCPServerConfig] encoded as JSON
// --- MCP server (expose LLMPro to other clients) ---
var mcpExposeEnabled: Bool = false         // user has turned on the exposed server
```

`MCPServerConfig` (a plain `Codable, Identifiable, Hashable, Sendable` struct,
NOT a SwiftData model — stored JSON-encoded in `mcpServersJSON`):

```swift
struct MCPServerConfig: Codable, Identifiable, Hashable, Sendable {
    var id: String              // stable slug, e.g. "filesystem"
    var name: String            // display name
    var command: String         // executable, e.g. "npx" or an abs path
    var args: [String]          // e.g. ["-y","@modelcontextprotocol/server-filesystem","/path"]
    var env: [String: String]   // extra environment
    var enabled: Bool           // connect on launch / offer to agents
}
```

## Naming + integration conventions

- **MCP tool names exposed to the model:** `mcp__<serverId>__<toolName>`
  (double-underscore segments — matches the broader MCP ecosystem and cannot
  collide with built-in snake_case tools, which contain no `__`). The dispatcher
  splits on `__` to route: `mcp` prefix → MCPService, `<serverId>` → which client,
  `<toolName>` → the remote tool.
- **Agent opt-in (keeps offline-by-default):** an agent gets MCP tools ONLY if its
  markdown frontmatter `tools:` list contains the literal token **`mcp`** (meaning
  "all tools from all *enabled* MCP servers"). No built-in agent ships with `mcp`,
  so the default team stays fully offline. (Optionally also honor explicit
  `mcp__server__tool` entries, but `mcp` = all is the primary mechanism.)
- **API server is independent of the Code-tab server.** `MLXServerService`
  (ephemeral port, the agent's private engine) is untouched. The new
  `APIServerService` is user-managed, uses `AppSettings.apiServerPort`, and can run
  simultaneously. Both reuse `python -m mlx_lm server` and the
  `resolveModelArg`/`MemoryService.wrap` patterns from MLXServerService.
- **No auth on the API server** (it binds to 127.0.0.1, exactly like Ollama /
  LM Studio). Do NOT claim bearer-token enforcement we don't implement; the UI
  presents the localhost URL + model name + copyable client snippets, and states
  plainly that it's unauthenticated localhost.

## Phase breakdown (each ends with a green build)

- **Phase A — API server.** `APIServerService.swift` (start/stop, state machine
  mirroring MLXServerService, stable port, model+adapter, `/v1` base URL, surfaces
  `/v1/models`). AppSettings API fields. A Settings tab **"API Server"**: model +
  adapter pickers (from `ModelRegistry`), port field, Start/Stop, live status,
  copyable base URL + curl/OpenAI-SDK snippet. Optional auto-start on launch.
- **Phase B — MCP client.** `MCPClient.swift` (actor: spawn stdio server,
  JSON-RPC `initialize` → `tools/list` → `tools/call`, newline-delimited framing,
  request-id correlation, timeouts). `MCPService.swift` (`@MainActor @Observable`
  registry: load configs from `mcpServersJSON`, connect enabled servers, aggregate
  tools, expose `specs(forAgentTools:)` → `[ChatToolSpec]` and
  `call(name:argumentsJSON:) async -> ToolResult`). Wire into the agent loop:
  `CodingAgentService` appends MCP specs when an agent's tools include `mcp`, and
  `executeRoleCalls`/`ToolExecutor` route `mcp__*` names to `MCPService`. A
  **"Connections"/"MCP" manager UI** (add/remove/test servers; per-server tool
  list). Keep it OFF the offline path: default team unaffected.
- **Phase C — exposed MCP server.** `Resources/helpers/mcp_server.py` — a stdio
  JSON-RPC MCP server that proxies to the localhost API server (Phase A) and
  exposes tools `mlx_chat` (run a prompt through a local model) and
  `mlx_list_models`. Register it in `PythonRuntime.installHelpers()`. UI in the
  API/MCP settings showing the exact `claude_desktop_config.json` snippet to paste
  (command = bundled python, args = `[<helpers>/mcp_server.py]`, env =
  `MLX_API_BASE=http://127.0.0.1:<port>/v1`), gated behind `mcpExposeEnabled`.

## Acceptance per phase

- **A:** Toggle on → server reaches `.ready`; `curl http://127.0.0.1:<port>/v1/models`
  lists the model; a `/v1/chat/completions` curl returns a completion. UI shows URL.
- **B:** Configure a real stdio server (e.g. `npx -y
  @modelcontextprotocol/server-everything` or filesystem). `MCPService` lists its
  tools; an agent whose `tools:` includes `mcp` can call one and get a result;
  default agents still see zero MCP tools. Unit-test the JSON-RPC framing without a
  live server.
- **C:** `python mcp_server.py` responds to a handcrafted `initialize` +
  `tools/list` + `tools/call` on stdin (newline-delimited) and returns a
  completion sourced from the running API server. UI shows a valid config snippet.

## Docs to update when done (doc-maintenance contract)

ARCHITECTURE.md (new service files + tables), CONTRACTS.md (new §: MCP JSON-RPC
methods we use, the `mcp__` naming, mcp_server.py protocol, API-server endpoints),
WORKFLOWS.md (start API server; add an MCP server; expose to Claude Desktop),
CONVENTIONS.md (why local-only / stdio-only / offline-by-default; why no auth),
STATE.md (session log + verified matrix), CLAUDE.md (sidebar/diagram + vocab),
EXTENDING.md (recipe: add an MCP server; add a new exposed MCP tool). Then delete
this file.
