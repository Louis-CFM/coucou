# Coucou MCP Architecture — Tools & Connectors for Chat

Coucou connects to Model Context Protocol (MCP) servers already configured on the user's machine, transforming the island chat into an assistant with actionable developer tools.

Following the philosophy of PR #400 (where local AI backends are automatically detected with zero credentials to paste), the MCP subsystem scans existing developer tool configurations passively without modifying files on disk or storing credentials in clear text.

---

## 1. Architecture Overview

```
┌────────────────────────────────────────────────────────────────────────┐
│                      Coucou Conversation & Voice                       │
│              (Island chat: ClaudeService / openai_compat.rs)          │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ Tool definitions & tool_calls
┌───────────────────────────────────▼────────────────────────────────────┐
│                         MCPChatCoordinator                             │
│       - Intercepts tool calls from the chat's model                   │
│       - Dispatches read-only vs mutating calls                         │
└─────────────────────┬───────────────────────────┬──────────────────────┘
                      │ Mutating (Approval)       │ Read-Only (Safe)
┌─────────────────────▼─────────────────────┐ ┌───▼──────────────────────┐
│            MCPApprovalManager             │ │     MCPToolRegistry      │
│  - Entry in HookServer's ApprovalQueue    │ │  - Dispatches calls      │
│  - Notch card (1/N, Allow/Deny), fails    │ │  - Formats OpenAI schema │
│    closed (timeout, Deny, late Allow)     │ │                          │
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

Coucou automatically reads existing configurations from standard developer tools on macOS, Windows and Linux (Windows and Linux: `windows/src-tauri/src/mcp/scanner.rs`):

| Tool | Monitored Locations | Configuration Key |
| :--- | :--- | :--- |
| **Claude Desktop** | `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS)<br>`%APPDATA%\Claude\claude_desktop_config.json` (Windows)<br>`$XDG_CONFIG_HOME/Claude/claude_desktop_config.json`, default `~/.config` (Linux) | `mcpServers` |
| **Claude Code** | `~/.claude.json` | `mcpServers`<br>`projects[*].mcpServers` |
| **Cursor** | `~/.cursor/mcp.json` | `mcpServers` |
| **VS Code** | `~/Library/Application Support/Code/User/mcp.json` (macOS)<br>`%APPDATA%\Code\User\mcp.json` (Windows)<br>`$XDG_CONFIG_HOME/Code/User/mcp.json` (Linux) | `servers`<br>`mcpServers` |
| **Windsurf** | `~/.codeium/windsurf/mcp_config.json` | `mcpServers` |
| **OpenCode** | `$XDG_CONFIG_HOME/opencode/opencode.json` and `…/mcp.json`, default `~/.config` (macOS)<br>`%OPENCODE_CONFIG_DIR%\opencode.json`, `%OPENCODE_CONFIG_DIR%\mcp.json`, `%APPDATA%\opencode\opencode.json` (Windows)<br>`$XDG_CONFIG_HOME/opencode/opencode.json` (Linux) | `mcp`<br>`mcpServers` |

`~` is the user's home folder (`%USERPROFILE%` on Windows).

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
* **Process & Descriptor Hygiene:**
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
  * *Action:* Waits for an **Allow** on the approval card, in the same line as the agents' permission requests.

### Approval card, failing closed
A tool that changes things runs only after an **Allow** clicked on its card before the request's deadline. Everything else refuses the call, and the model is told: `The user did not approve this tool call, so it was not run.`

**macOS** (`MCPApprovalManager.swift` → `HookServer.enqueueMCPApproval`):
1. The request becomes an entry of HookServer's `ApprovalQueue`, the queue that Claude Code's and the other agents' requests wait in. It joins the end of the line and never replaces or cancels another request.
2. The card shows the oldest request first, with its position (`1/3`), `<server>: <tool>` and the arguments (sorted, cut to 300 characters), on an `MCP tools` pill. Its buttons are **Deny** and **Allow**; there is no **Always**, so every call is asked for.
3. A click answers only the request on screen.
4. Refusals: Deny, no click within 108 s, a card dropped without an answer, a line already holding 5 requests, or an Allow clicked at or after the deadline.

**Windows and Linux** (`windows/src-tauri/src/mcp/approval.rs`, decision rule in `mcp/gate.rs`):
1. The request goes to the island as a `PermissionRequest` from agent `mcp`, kind `mcp_tool`, with an id `mcp-N`. It waits in the island's line with the agents' requests and shows on an `MCP tools` pill.
2. The island must confirm within 800 ms that the card is up. The deadline is fixed when the request starts (108 s), and each click is stamped when it reaches Coucou.
3. Refusals: no confirmation in time, a paused island, a full line, Deny, no click before the deadline, or an Allow stamped at or after it.

**The phone's chat and the iPhone app** have no card to ask on: tools that change things never run there; read-only tools still do.

MCP decisions are not counted in the weekly recap.

---

## 5. Chat Integration

MCP tools are offered to the island's text chat. The voice assistant does not use them.

1. **Schema Generation:** `MCPToolRegistry` formats all active tools as standard function definitions (`mcp__<serverID>__<toolName>`).
2. **macOS (`ClaudeService.swift`):**
   * Tools are injected into the `/chat/completions` payload.
   * `MCPChatCoordinator` executes tool calls returned by the model, after approval when needed, and feeds the results back for the follow-up turn.
3. **Windows and Linux (`openai_compat.rs`):**
   * The OpenAI-compatible providers (OpenAI, Google AI, OpenRouter) receive the tools; each tool call goes through `mcp::approval::allowed` before it runs.

---

## 6. Testing

All MCP modules are validated using standalone Swift test harnesses:
* `scripts/test-mcp-scanner.sh`: Tests config parsing, normalization, secret masking, and deduplication.
* `scripts/test-mcp-client.sh`: Tests JSON-RPC 2.0 protocol encoding, response parsing, and AnyCodable serde.
* `scripts/test-mcp-coordinator.sh`: Tests safety classification, tool routing, and the fail-closed run rule.
* `scripts/test-approval-queue.sh`: Tests MCP entries in the approval line and the deadline rule (an Allow at or after the deadline is a refusal).
* Windows and Linux: `cargo test` covers `mcp/gate.rs` (ack, Deny, timeout, late Allow) and `mcp/approval.rs`; `npm test` covers the island's MCP card.
* `scripts/test-mcp-http.sh`: Tests remote HTTP client payload framing and response parsing.
