# Coucou MCP Architecture — Tools & Connectors for Chat

Coucou connects to Model Context Protocol (MCP) servers already configured on the user's machine, transforming the island chat into an assistant with actionable developer tools.

Following the philosophy of PR #400 (where local AI backends are automatically detected with zero credentials to paste), the MCP subsystem scans existing developer tool configurations passively without modifying files on disk or storing credentials in clear text.

---

## 1. Architecture Overview

```
┌────────────────────────────────────────────────────────────────────────┐
│                      Coucou Conversation & Voice                       │
│    (Dynamic Island / Chat / ClaudeVoiceBrain / FoundationModels)      │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ Tool definitions & tool_calls
┌───────────────────────────────────▼────────────────────────────────────┐
│                         MCPChatCoordinator                             │
│       - Intercepts tool calls from LLM (Chat & Voice brains)           │
│       - Dispatches read-only vs mutating calls                         │
└─────────────────────┬───────────────────────────┬──────────────────────┘
                      │ Mutating (Approval)       │ Read-Only (Safe)
┌─────────────────────▼─────────────────────┐ ┌───▼──────────────────────┐
│            MCPApprovalManager             │ │     MCPToolRegistry      │
│  - Integrates with unified ApprovalQueue  │ │  - Dispatches calls      │
│  - Notch Card (1/N, project, Allow/Deny)  │ │  - Formats OpenAI schema │
└───────────────────────────────────────────┘ └───┬──────────────────────┘
                                                  │
                              ┌───────────────────┴───────────────────┐
                              ▼                                       ▼
                     MCPStdioClient                          MCPHTTPClient
                 (Hardened Subprocesses)               (Remote streamable HTTP)
                 - CLOEXEC & clean env                 - JSON-RPC over HTTP
                 - Sandboxed / bounded                 - Bearer auth injection
```

---

## 2. Zero-Config Discovery (`MCPScanner.swift`)

Coucou automatically reads existing configurations from standard developer tools on macOS and Linux:

| Tool | Monitored Locations | Configuration Key |
| :--- | :--- | :--- |
| **Claude Desktop** | `~/Library/Application Support/Claude/claude_desktop_config.json`<br>`~/.config/Claude/claude_desktop_config.json` | `mcpServers` |
| **Claude Code** | `~/.claude.json`<br>`<project>/.mcp.json` | `mcpServers`<br>`projects[*].mcpServers` |
| **Cursor** | `~/.cursor/mcp.json` | `mcpServers` |
| **VS Code** | `~/Library/Application Support/Code/User/mcp.json`<br>`~/.config/Code/User/mcp.json` | `servers`<br>`mcpServers` |
| **Windsurf** | `~/.codeium/windsurf/mcp_config.json` | `mcpServers` |
| **OpenCode** | `~/.config/opencode/opencode.json`<br>`~/.config/opencode/mcp.json` | `mcp`<br>`mcpServers` |

### Normalization Rules
1. **Variable expansion:** Normalizes syntax across formats:
   * `${VAR}` (Claude Code, shell)
   * `${env:VAR}` (VS Code, Cursor, Windsurf)
   * `{env:VAR}` (OpenCode)
   * `${userHome}` and `~/` expand to the actual user home directory.
2. **Secret Masking:** Keys and tokens (e.g. `sk-••••`, `ghp_••••`) and URL query parameters are masked when rendered in Settings.
3. **Deduplication:** Identical servers (e.g., PostgreSQL or GitHub configured in both Claude Desktop and Cursor) are merged into a single entry with composite source badges.

---

## 3. Communication Transports

### A. Hardened Subprocesses over Stdio (`MCPStdioClient.swift`)
* Launches servers as child processes (`Process`) with isolated standard pipes (`stdin`, `stdout`, `stderr`).
* **Process & Descriptor Hygiene (Gentle Dot pattern):**
  * All internal sockets and pipes (e.g., Coucou's `HookServer` socket `nb.sock`, IPC channels) are strictly closed-on-exec (`CLOEXEC`) so child tool processes cannot inherit or tamper with internal communications.
  * Continuous draining of `stderr` via dedicated readability handlers to prevent XNU pipe buffer exhaustion (64 KB kernel deadlock).
* **Environment Sanitization:**
  * Clean environment isolation: child processes inherit essential developer paths (`/opt/homebrew/bin`, `/usr/local/bin`, `.nvm`, `.local/bin`), but Coucou's internal secrets, API keys, and sensitive tokens are strictly scrubbed, passing only explicitly configured server variables.
* **Protocol & Watchdogs:**
  * Strict line-delimited JSON-RPC 2.0 framing.
  * Watchdog timers terminate runaway processes on timeout (15s for handshake, 60s for tool calls).
  * Child processes are cleanly terminated when the app exits or a server is disabled.
* **App Store Sandbox Guard:**
  * Guarded under `#if !APPSTORE`: in Mac App Store builds, subprocess execution is disabled, recommending remote HTTP servers.

### B. Remote Streamable HTTP (`MCPHTTPClient.swift`)
* Communicates with remote servers via JSON-RPC 2.0 over HTTP POST (`application/json`).
* Injects headers (e.g. `Authorization: Bearer <token>`) configured by the user or imported from external configs.
* Fails closed with descriptive messages on HTTP 401, 403, 404, or 500 status codes.

---

## 4. Human-in-the-Loop Governance & Unified Approval Queue

Coucou strictly regulates tool execution to prevent unintended side effects:

### Safety Classification
* **Read-Only / Safe Tools:**
  * Tools declaring `readOnlyHint: true`.
  * Tools starting with safe read prefixes (`get_`, `list_`, `read_`, `search_`, `fetch_`, `check_`, `describe_`, `view_`, `show_`, `find_`) that do not contain mutating keywords.
  * *Action:* Execute immediately and show an active working state.
* **Mutating / Side-Effect Tools:**
  * Any tool with keywords like `write`, `delete`, `send`, `post`, `update`, `create`, `execute`, `run`, `edit`.
  * *Action:* Triggers the native **Approval** card in the Notch via the unified `ApprovalQueue`.

### Unified Approval Queue (Coucou PR #563 Pattern)
Mutating tool requests no longer overwrite each other or get clobbered by external agent hook approvals (Claude Code, Cursor):
1. `MCPApprovalManager` captures execution state with a unique request `UUID` and enqueues it into `ApprovalQueue`.
2. The Notch displays requests in strict FIFO order:
   * Header indicates current position in queue (e.g. `1/3`) and asking context (`MCP: PostgreSQL`).
   * Tool arguments summarized in a formatted code block.
   * `Allow` / `Always` / `Deny` action buttons bound strictly to the currently displayed request `UUID`.
3. Answering or clicking on a request settles only that specific `UUID`. Subsequent waiting tool calls are promoted automatically.
4. If the user dismisses the Notch or the 115s safety watchdog elapses, the tool execution fails closed without side effects.

---

## 5. Chat & Voice Brain Integration

MCP tools are available to both text-based island conversations and Coucou's voice assistant:

1. **Schema Generation:** `MCPToolRegistry` formats all active tools as standard function definitions (`mcp__<serverID>__<toolName>`).
2. **Text Chat (`ClaudeService.swift`):**
   * Tools are injected into the `/chat/completions` payload.
   * `MCPChatCoordinator` executes tool calls returned by the model and feeds the results back for contextual follow-up turns.
3. **Voice Brain (`ClaudeVoiceBrain.swift` & `VoiceBrain.swift`):**
   * Dynamic MCP tools augment Coucou's built-in voice tools (`pills`, `service_info`, `open_app`, `prepare_email`).
   * When Claude or FoundationModels invokes an MCP tool via voice:
     * Read-only tools fetch data seamlessly to answer the user's spoken question.
     * Mutating tools open the native Notch approval card with sound before performing any action.

---

## 6. Testing

All MCP modules are validated using standalone Swift test harnesses:
* `scripts/test-mcp-scanner.sh`: Tests config parsing, normalization, secret masking, and deduplication.
* `scripts/test-mcp-client.sh`: Tests JSON-RPC 2.0 protocol encoding, response parsing, and AnyCodable serde.
* `scripts/test-mcp-coordinator.sh`: Tests safety classification, tool routing, and approval handling.
* `scripts/test-mcp-http.sh`: Tests remote HTTP client payload framing and response parsing.
