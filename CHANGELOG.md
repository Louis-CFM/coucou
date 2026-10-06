# Changelog

## 1.0.0 Lighto Edition — upstream 0.1.9 base

This fork keeps its own 1.0.0 version line and carries the Windows, agent-hook,
permission and Desktop Mochi work described below. Its shared macOS source now
includes upstream 0.1.8 and 0.1.9 changes; the published Lighto Edition installer
remains Windows-focused.

- Everything from 0.1.6: Mochi on the desktop with the wardrobe, greetings, live file-edit tickers and diffs, and the expanded GitHub integration (pull requests, CI, review requests and the contribution grid)
- Five agent pills now, each with its own name and colour: VS Code (Claude Code), Pi, Copilot CLI, Codex and Antigravity. Every event is routed by the agent tag the relay carries, so one agent's approval card can never land on another agent's pill
- Pi: install writes one extension file to `~/.pi/agent/extensions/`. Pi reports its sessions, tool calls and a per-turn summary, and permission requests block until you Allow or Deny in the island
- Copilot CLI: Coucou's entries go into `~/.copilot/hooks/coucou.json` in the flat `exec`/`args`/`timeoutSec` shape Copilot expects. Only `PermissionRequest` waits on you
- Codex: installs its hook entries in `~/.codex/hooks/hooks.json`, preserves unrelated hooks and routes Codex activity and supported permission requests to its own pill
- Antigravity: `~/.gemini/config/hooks.json`, wired to Antigravity's own `PreInvocation`/`PostInvocation` events plus the legacy lifecycle names so a session is never half-tracked
- Settings has an agent picker: pick an agent, see whether its hooks are installed, read the diff, and write it — all with a backup and a fingerprint guard, exactly as Claude Code always did
- Every agent writes to its own file, so installing one can never clobber another's hooks, and uninstalling restores the file byte for byte
- Coucou never overwrites or deletes a Pi extension it did not write. If your own extension is already at that path, it is left exactly as it is, the Settings window says so, and there is no Install or Uninstall button to press by mistake — reinstalling your hook cannot replace it with Coucou's built-in one
- Fixed Pi permission prompts being abandoned: the request waited 800ms for a human to click Allow, so the island card was discarded while still on screen and Pi fell back to its own dialog. The wait is now long enough for a person, and "Coucou is not running" is detected immediately instead of by timeout
- Pi permissions now have exactly one asker. `pi-permission-system` asks Coucou first and falls back to Pi's dialog, and Coucou's extension no longer answers permissions too — two extensions intercepting one decision produced duplicate cards
- Every failure while asking now falls through to Pi rather than denying: Coucou closed, relay missing, empty or unrecognised answer, timeout, or an exception in the handler
- Fixed the Pi prompt ticker always being empty — it read a `text` field that does not exist on `before_agent_start`, so it always sent `undefined`

## Upstream 0.1.9 baseline merged

- Adds upstream iPhone service-detail actions and Live Activity timing/recovery improvements, plus a Cal.com API v2 fix. These Apple-platform changes do not change the Windows 1.0.0 installer feature set.

## Upstream 0.1.8 baseline merged

- Brings in upstream's iPhone companion, widgets and private iCloud session sync, plus the shared CoucouKit refactor. These Apple-platform features are source changes; the Lighto 1.0.0 published installer remains Windows-only.
- Includes upstream changes for iPhone approval decisions, questions, Live Activities and service/session summaries. They do not change the Windows installer feature set.

## 0.1.7 — October 4, 2026

- Keyboard shortcuts from anywhere: ⌃⌥Space opens the chat, ⌃⌥A jumps to a waiting permission or question, ⌃⌥T brings your terminal forward, ⌃⌥] and ⌃⌥[ switch pills, ⌃⌥M mutes Mochi, ⌃⌥D sends him to the desktop and back, ⌃⌥G opens the wardrobe, and ⌃⌥W attaches the front window to the chat (GitHub build) (#205)
- In the open island: ⌘← ⌘→ and ⌘1–9 switch pills, ⌘↑ ⌘↓ and ⌘O move through a card's list, ⌘E opens the diff, ⌘↩ sends, ⌘K starts a new chat, ⌘P pins the island (#205)
- Every global shortcut can be changed or turned off in Settings → Shortcuts, which also flags combinations another app already uses. They need no Accessibility permission (#205)
- ⌘⇧N now opens and closes the island (#205)

## 0.1.6 — October 4, 2026

- Mochi on the desktop: drag him out of the notch and drop him anywhere on your desktop. He hangs out there, follows your cursor with his eyes, wears his outfit and dances to your music (#198)
- When Claude needs you, he flies back to the notch with the permission or the question, then returns to his spot once you answer. He does a happy jump when a task finishes (#198)
- Click him to poke him, right-click for the wardrobe, drop him on a window to attach it to the chat (GitHub build), and drop him on the notch or double-click him to bring him home (#198)
- He falls asleep when nothing is going on, and remembers his spot between launches (#198)

## 0.1.5 — October 4, 2026

- Dress Mochi up: right-click him to open the wardrobe and pick a party hat, beanie, crown, witch hat, Santa hat, bunny ears, bow, sunglasses, round glasses, scarf or pumpkin, all drawn in code (#195)
- Auto mode dresses Mochi for the seasons on his own (#195)
- Outfits follow his head in 3D, glasses stay on his eyes, soft parts react when you tap or move him, and outfits come and go with a transition. Only the main Mochi wears them (#195)
- A new launch greeting: Mochi drops into the island, bounces, slides to the side and waves hello with a quick little hand, then comes back, with a new soft whisper of a sound (#196)
- Mochi's body is no longer clipped at two corners during the greeting (#196)

## 0.1.4 — October 3, 2026

- See what Claude is editing, live: each file edit shows up in the session ticker with its +N −M lines, and a click opens the diff right in the notch (#177)
- When Claude finishes, the session card shows its final message instead of the last step, without the shimmer (#177, #179)
- GitHub pill: your open pull requests with their CI status, the pull requests waiting for your review, and the CI of the default branch of your recent repos. Click a row for the list, then an item to open it on github.com (#181)
- GitHub alerts: a badge and a sound when the CI of one of your pull requests turns red or green, when a default branch breaks, or when someone requests your review. Fast CI runs are caught too, and the card refreshes when you open it (#181, #185)
- Your GitHub contribution grid: the last 7 days in the GitHub card header, click it for the past 23 weeks, and click a day for its count (#187)
- The GitHub token needs read access to pull requests and CI: a classic token with the repo scope, or a fine-grained token with read access to Pull requests, Commit statuses and Actions (#181)
- The finished view no longer overflows the card (#179)

## 0.1.3 — October 3, 2026

- Answer Claude's questions from the notch: when Claude Code asks a multiple-choice question, pick an option or type your own answer right in the island, and Reply in terminal hands it back. Update your hooks in Settings to turn it on (#165) — thanks @Vega8991 for the idea (#94)
- Claude plan usage (GitHub build): turn on Settings → Agents → Plan usage to see your 5-hour and weekly limits in a small pill in the notch header, and click it for the details and reset times. Pro and Max plans; your current status line keeps working (#159)
- Chat with local models through Ollama or LM Studio, no API key needed: connect them in Settings → Chat → Local models. Answers stream in, and thinking blocks stay hidden (#156)
- Markdown in chat answers: bold, lists, headings, quotes, and code blocks with a copy button. Links open only when they are web links (#156)
- Apple Music (GitHub build): see what is playing in the notch, play, pause and skip on hover, and Mochi dances along (#144, #153)
- Settings are now organized in a sidebar (#153)
- The chat greets you by your own first name (#154)

## 0.1.2 — October 2, 2026

- Codex support (GitHub build): sessions show up live on the Codex pill, and permission requests get Allow and Deny in the notch. Install from Settings → Codex Hooks, then trust the hooks once with /hooks in Codex (#130) — thanks @lacatu5
- Cursor: Claude Code started in Cursor's terminal shows up on the Cursor pill, and you can answer its permission requests from the notch (#120).
- Pick your main coding tool in Settings → Active pills: VS Code, Cursor, Codex or Antigravity (Codex and Antigravity: GitHub build). It stays on and no longer takes one of the 4 slots (#120).
- The permission card stays in the notch until you answer it: the mouse no longer folds it, and reopening the island shows the request again (#117).
- The permission card also shows when the island is already open, and the pill you were on comes back once you answer (#120).

## 0.1.1 — October 2, 2026

- Declare the tools you use in Settings: Gemini CLI, Antigravity, Anthropic, Google AI and OpenAI pills join the existing ones (Cursor and Codex pills are coming soon), and you pick the main pill.
- Chat now supports Google AI (Gemini) and OpenAI in addition to Anthropic; switch provider and model by clicking the model name in the chat view, on macOS.
- Linux version: the Tauri app now builds for Linux too (AppImage, .deb, .rpm), with the island as a layer-shell overlay on Wayland and Claude Code hooks over a private Unix socket (#21) — thanks @Davy133
- Compact island on screens without a notch (#22) — thanks @Kamasoutra
- Only web links (http/https) open from the notch; other kinds of links from Claude or integrations are ignored (#16) — thanks @Cris1670
- Hook socket limited to your own user account, with size and time limits; logs no longer keep commands, n8n data or full URLs, and stay under 1 MB (#16) — thanks @Cris1670 and @Vignesh-Thangamariappan
- The island always reopens after folding, and Settings opens below it, resizable — thanks @rouderz
- Choose the Claude model for the chat in Settings; the list comes from your Anthropic account, and Claude Sonnet 4.6 stays the default — thanks @rouderz
- Windows build artifacts are now downloadable from a manual CI run — thanks @MysJofR
- Any agent can talk to Mochi: tag a hook payload with `coucou_agent` (e.g. `nb-hook --agent my-agent`) and it gets its own pill in the island (#7, #9) — thanks @lacatu5
- Gemini CLI and Antigravity (agy) hook support on macOS: install from Settings and their sessions show up in the island — thanks @corefusiion

## 0.1.0 — September 27, 2026

- First release: Mochi lives in your notch, breathing, blinking, with eyes that follow your cursor
- Claude Code sessions: live steps, approve permissions, answer questions, jump to the terminal
- Chat with Claude from the notch
- Drop a file on the notch to ask a question about it or send it by email
- Drag Mochi onto any window to attach it as context
- Integrations: Stripe, n8n, GitHub, Vercel, Resend, Notion, Cal.com
- 28 handcrafted sounds
- Hides when idle, peeks out when you hover
