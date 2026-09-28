# Coucou Codex integration (Linux)

Official OpenAI Codex authentication and agent control via the **`openai-codex` Python SDK** (app-server). Coucou does **not** implement custom OAuth, scrape ChatGPT, or handle tokens in the frontend.

## How to install Codex (شلون تحمّله)

```bash
# 1) Install uv (recommended) then the official SDK + pinned CLI runtime
curl -LsSf https://astral.sh/uv/install.sh | sh
cd apps/linux
uv venv .venv-codex
uv pip install --python .venv-codex/bin/python openai-codex

# 2) Optional: also install the Codex CLI for terminal use
npm install -g @openai/codex
# or: npx @openai/codex

# 3) Optional standalone CLI login (session is reused by Coucou)
codex login
```

Requirements: Python ≥ 3.10, Linux desktop (GNOME/KDE, Wayland or X11), network access for OpenAI login.

## Sign in with ChatGPT (in Coucou)

1. Open Coucou settings → **AI / Integrations** → **OpenAI Codex**
2. Click **Sign in with ChatGPT**
3. Your default browser opens the **official** OpenAI auth URL from `codex.login_chatgpt().auth_url`
4. Coucou shows **Waiting for ChatGPT sign in…** (Cancel available)
5. Complete login in the browser (localhost callback is handled by the Codex runtime)
6. UI becomes **Connected to ChatGPT** (account label only if the SDK exposes a safe field)

### Device code fallback

Use **Use Device Code** when the browser localhost callback cannot work (remote/headless). Coucou shows the official verification URL + user code from `login_chatgpt_device_code()`.

### Existing sessions

On startup Coucou calls `account()` through the official SDK. If you already ran `codex login` (or signed in via another official Codex client), Coucou reconnects automatically — no forced re-login.

### Disconnect

**Disconnect** calls official `logout()`.

## Architecture

```
UI (TypeScript)
  → Tauri commands (Rust, no tokens in logs)
    → apps/linux/codex-bridge/bridge.py  (openai_codex.Codex)
      → Codex app-server / official ChatGPT login
```

Providers:

- `ClaudeCodeProvider` — local Claude Code hooks
- `CodexProvider` — OpenAI Codex

Normalized agent states drive Mochi: `thinking`, `reading`, `searching`, `editing`, `running_command`, `waiting_for_user`, `success`, `error`.

## Security

- No tokens in frontend JS beyond what the official flow requires for the auth URL handoff to the browser
- No cookies scraped; no ChatGPT passwords collected
- No Coucou servers; no analytics
- Bridge stderr logs never print tokens / auth query strings

## Troubleshooting

| Message | Meaning |
|---------|---------|
| Codex runtime unavailable | Install `openai-codex` in `.venv-codex` (see above) |
| Could not open browser | Install `xdg-utils`; try Device Code |
| Authentication cancelled / timed out | Cancelled or wait exceeded |
| Session expired | Sign in again |

## Files

- `apps/linux/codex-bridge/bridge.py`
- `apps/linux/src-tauri/src/codex.rs`
- `apps/linux/src/services/ai/*`
- Settings UI in `index.html` / `views.ts`
