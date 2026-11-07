# Coucou Desktop plugin

Ask a question in the Coucou island and return the user's choice or typed answer
to the **same Codex conversation** through its MCP tool call. The bundled
`coucou-question` skill can also open a free-form field for the user's next
instruction, then continue that conversation with the result.

## Requirements

- macOS, with a GitHub Coucou build that includes **Export desktop plugin…** in
  Settings → Agents → Codex. Stock Coucou 0.3.0 and the App Store build do not provide
  this question bridge.
- A current Codex desktop client with local plugin and stdio MCP support. In
  current releases this is Codex in the ChatGPT desktop app.
- Python 3 available as `python3` to the desktop client. The server uses only the
  Python standard library; there are no packages to install.
- Coucou and the Codex conversation running locally as the same macOS user.

## Install and enable

1. Launch the new Coucou build. In **Settings → Agents → Codex**, select
   **Export desktop plugin…** and choose a destination. Coucou creates
   `Coucou-Codex-Plugin` there; an existing folder is never overwritten.
2. Keep that entire folder, including its hidden `.agents` directory. It contains
   a local marketplace named **Coucou Local**, with its plugin source set to `./`
   relative to the exported folder.
3. From a terminal with the current `codex` CLI, register the exported folder:

   ```sh
   codex plugin marketplace add "/absolute/path/to/Coucou-Codex-Plugin"
   codex plugin marketplace list
   ```

   Replace the example with the folder you exported. These commands register a
   local source; installation and enabling happen in the desktop app.
4. Restart the Codex / ChatGPT desktop app. Open **Plugins**, choose the
   **Coucou Local** source, find **Coucou Desktop**, then install and enable it.
   Review the local MCP server permission when prompted. This plugin needs no
   separate API key or OAuth login.
5. Start a local project conversation and invoke the skill as shown below. Keep
   Coucou running while the question is open.

For development without exporting, register this `CodexDesktopPlugin` directory
as the marketplace root instead. To update an installed copy, update/re-export
the complete folder, refresh the **Coucou Local** marketplace, and restart the
desktop app. Local plugins run from Codex's installed cache, so editing the source
folder alone does not update an already running MCP process. To remove the source,
disable/uninstall the plugin in the desktop app, then run:

```sh
codex plugin marketplace remove coucou-local
```

The directory layout and local marketplace steps follow the
[official plugin packaging guide](https://developers.openai.com/plugins/build/plugins).
The local MCP configuration uses the documented `${PLUGIN_ROOT}` placeholder in
`mcp.json`; see [desktop-only plugins](https://developers.openai.com/plugins/deploy/desktop-only).

## Ask or enter an instruction

In the **original local project conversation**, send:

```text
$coucou-question Ask me in Coucou whether to run the tests or inspect the diff.
```

Choose an option or type an answer in Coucou and submit it. The result returns to
that waiting tool call, and Codex continues the original conversation.

To enter a new instruction through the island:

```text
$coucou-question Open a free-form field in Coucou for my next instruction.
```

The skill asks what to do next with no preset options. Type your instruction in
Coucou and submit it. A new waiting tool call is required each time; the plugin
does not push arbitrary messages into another or an idle conversation.

The `ask_question` tool takes the current project's absolute, existing `cwd` and
one to four questions. Each question has a unique `id` and `question`, with an
optional short `header`, up to nine `{label, description}` options, `isOther`
(typed answers, default `true`), and `isSecret` (masked input, default `false`).
For free-form input use `options: []` and `isOther: true`.

## Behavior and limits

- Only questions explicitly asked through this plugin reach Coucou. Built-in
  Codex questions, approvals, and questions from other tools remain in Codex.
- The plugin does not attach to a private desktop RPC endpoint or assume ownership
  of a native Codex thread. It does not require a terminal Codex session.
- Only one question call can wait in each MCP process. It waits at most 120
  seconds. Cancelled calls close their waiting socket; late answers cannot satisfy
  another call. If Coucou is closed, skips the question, disconnects, or times out,
  the tool returns an error instructing Codex to ask in the original conversation.
- The bridge contacts only the local Coucou socket at
  `~/Library/Application Support/NotchBuddy/nb.sock`. It does not write hooks,
  credentials, transcripts, or answer logs. Answers are returned to the Codex
  conversation and are therefore part of that conversation's tool result.
- Remote and cloud conversations, Windows, and the App Store Coucou build are
  outside this plugin's scope. Workspace policy may disable local MCP plugins.

If the plugin is missing from **Plugins**, verify the registered marketplace path
with `codex plugin marketplace list`, preserve the hidden `.agents` folder, and
restart the desktop app. If its tool is unavailable, check that **Coucou Desktop**
is enabled and that the client can launch `python3`. If no question appears, first
confirm the running Coucou build includes this bridge and that the conversation
called `ask_question`; a built-in Codex question does not call it automatically.

## Fixture validation

From the Coucou repository root:

```sh
python3 scripts/test-codex-plugin.py
```

The test launches the actual MCP server with a temporary fake Coucou socket. It
checks question routing, answer IDs, protocol and size validation, cancellation,
busy calls, timeout, disconnect and stdin EOF. It does not install the plugin,
touch real Codex configuration, log in, invoke a model, or validate the desktop UI.
