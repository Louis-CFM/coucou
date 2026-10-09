# Nova assistant — Windows 11 x64

## Run
- Installer: unpack the downloaded artifact ZIP and run `Nova-Windows-setup.exe`.
- Portable: extract the whole ZIP into one folder. Keep `engine/` beside `nova.exe`; run `nova.exe`. It still saves settings/history in your Windows user profile.
- The build is unsigned. Check the repository/commit and scan the download. Windows may show SmartScreen; “More info → Run anyway” is available if you decide to trust it.

## Set up AI
1. Open Settings → AI Chat. Import your previous saved chat setup, or enter a provider name, API base URL, API format, exact model ID, and API key.
2. OpenAI-compatible endpoints commonly end in `/v1`. Use your provider’s documented URL. Native OpenAI Responses, Anthropic and Google formats are separate options.
3. Select a model that supports tool calling. Image/PDF support also depends on the selected model. No provider account or API credit is included.
4. Settings → Computer Access: choose an existing working folder, or leave it blank to use `NovaWorkspace` in your home folder.
5. Send a request. The bundled OpenCode engine starts without a terminal. First startup needs internet to fetch its official plugin dependency into a private cache; no global Node/Bun/WSL installation is required for the installed app.

## Daily use
- × hides the island; it does not quit or stop an active task. Move the pointer to the screen’s top centre to reopen it.
- Quit Nova in Settings or the tray stops the app and its engine.
- + attaches up to five photos, PDFs or text/code files (8 MiB per file, 16 MiB total). Export Office documents to PDF first. Original selected files are not edited by attaching them.
- Enter sends; Shift+Enter starts another line. New conversation starts a separate chat. Stop task terminates the engine’s process tree. Ctrl+Alt+K is the emergency stop when Windows can register that shortcut; it changes permission mode to Strict.
- Chat history searches completed conversations saved on this PC. Open an entry to resume its real engine session. The AI can request approved searches of earlier chats; this is not unlimited or automatic memory.
- Switching providers can send the current conversation to the selected provider. Provider keys stay in Windows Credential Manager.

## Computer access and safety
Nova runs as your ordinary Windows user, not administrator. Reads outside the working folder may ask for additional permission. Every shell command and native file edit asks for a fresh approval. Review the displayed command/diff; unanswered approvals deny after 60 seconds. Use the Recycle Bin tool for deletion. Shell programs may permanently delete files or make wider changes if you explicitly approve them; this is a permission gate, not an OS sandbox. Do not approve commands you do not understand.

History is local but **not encrypted**: `%LOCALAPPDATA%\Nova\history`. The private engine stores full sessions under `%LOCALAPPDATA%\Nova\engine-runtime`; configuration is under `%APPDATA%\Nova`. Attaching and sending a file shares its contents with your selected AI provider. Do not attach credentials or private files you do not intend to share.

## Quick acceptance checks on your PC
1. Change Light/Dark, hide with ×, and reopen from top-centre hover; confirm chat input stays visible on a long conversation.
2. Attach a harmless photo or text file and ask about it using a capable model.
3. Ask Nova to create a text file inside the working folder. Confirm the proposed diff before Allow once.
4. Ask for a harmless `Write-Output 'hello'` shell command. Deny first, then repeat and approve; nothing should execute before approval.
5. Finish a chat, quit/reopen Nova, search Chat history, and resume it.
6. Start a harmless long-running task and try Stop task / the emergency shortcut.

Windows CI exercises the real bundled engine with two **local mock-provider** endpoints, file edits, shell approval/denial and child-process cleanup. It does not validate your paid provider/key, model image capabilities, Windows display scaling or your desktop’s hover behavior. Those require the checks above.

This fork retains upstream MIT code attribution. NOVA uses original replacement mascot geometry, palette and generated icons; bundled upstream sounds and branded media are removed. See LICENSE and LICENSE-ASSETS.md.

## Clock and weather

Settings → Appearance & App → Widgets enables/reorders the two header pills. Weather is disabled until you choose a location. Enter coordinates or search a city; the optional IP estimate asks first and shares your public IP with ipapi.co. Open-Meteo receives coordinates, not your chat. Cached weather refreshes after 60 minutes; `~` marks a stale offline value. A disabled pill stops its timer. The optional second clock accepts an IANA timezone (for example `Asia/Kolkata`).

## Skills, instruction commands, subagents and MCP

Settings → AI Chat → Engine skills, commands & MCP manages the engine's own extensions. No configuration-file editing is required. IDs use lowercase letters, digits and hyphens. Skills are registered as OpenCode `SKILL.md` files; commands are registered under `nova-<id>`. Command instructions may use `$ARGUMENTS`; `!` and `@` are rejected in commands and their arguments because upstream performs shell/file expansion before permission hooks.

In chat, **Engine tools** opens the subagent/skill/command picker and MCP connection status. Send one ordinary message to start the engine first; its available subagents then appear. A selected skill asks the model to load the engine's skill tool; compliance depends on the model. A selected subagent delegates through OpenCode's real task mechanism. Its permissions/questions remain visible, with fresh shell approval and the same 60-second denial timer. The visible transcript remains the parent conversation.

Remote MCP supports HTTPS (or local HTTP), no-auth and a bearer token stored in Windows Credential Manager and bound to the exact endpoint. OAuth is not enabled. Local MCP requires an already-installed absolute `.exe` and an explicit trust checkbox for its executable/arguments; Nova installs no global tools. A local MCP server is trusted code running as your Windows user, **not an OS sandbox**. Its internal startup/actions cannot be inspected as separate shell calls. The model's MCP tool invocations still ask permission. Disable or remove the server in Settings to stop attaching it at engine startup. Never put a secret in a URL, command argument, instruction or skill body.

**Export Markdown** opens Windows' Save dialog and exports the cached conversation's text, tool status and attachment names, not image bytes or attachment data URLs. Active conversations update their local cache when a turn finishes. History search remains local and plaintext; export is plaintext too.

### Extension acceptance checks

1. Add a harmless skill and an instruction command; open Engine tools and try both.
2. Select `general` as a subagent and ask it to write a throwaway file. Verify no write/command runs before approving its card.
3. Attach a known MCP server. Check its status in Engine tools and deny a first tool request.
4. Resume an older conversation and export Markdown to a folder you choose.
5. Change a bearer-protected MCP endpoint without entering a new token: startup must refuse to reuse the old token.
