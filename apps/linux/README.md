# Coucou — Linux

Floating top-center companion (Tauri 2 + TypeScript). macOS app under `NotchBuddy/` is unchanged.

- Docs: [`docs/linux.md`](../../docs/linux.md)
- Codex / ChatGPT: [`docs/codex-linux.md`](../../docs/codex-linux.md)
- Architecture: [`docs/linux-architecture.md`](../../docs/linux-architecture.md)

## Correct way to run

**Always use Tauri for real features.** Browser Vite alone cannot:

- Sign in with ChatGPT (Codex)
- Talk to Claude Code hooks over the Unix socket
- Store secrets in Secret Service
- Register **Shift+M** desktop control

```bash
# From repo root — once
./scripts/install-linux-deps.sh

cd apps/linux
npm install

# Optional: Codex bridge (Sign in with ChatGPT)
npm run codex:setup    # requires `uv` (https://github.com/astral-sh/uv)

# Real desktop window
npm run tauri:dev
```

`npm run tauri:dev` puts `~/.cargo/bin` on `PATH` automatically. If you still see `cargo: No such file or directory`:

```bash
source ~/.cargo/env
# or install Rust: curl https://sh.rustup.rs -sSf | sh
```

### Browser-only preview (UI only)

```bash
npm run dev            # http://127.0.0.1:1420 — no native APIs
# or from repo root:
./scripts/dev-linux.sh
```

## Connect

| Goal | Steps |
|---|---|
| Claude Code sessions / approvals | Settings → **Install hooks** |
| ChatGPT cloud (Codex) | Settings → **Sign in with ChatGPT** (Tauri only) |
| Screen analysis / chat | Settings → save **Anthropic API key** |
| Desktop control | **Shift+M**, then type a request |

Examples after Shift+M:

- `open youtube search lo-fi`
- `next song` / `غير الأغنية`
- `analyze what's on screen` / `حلل الشاشه`
- `open chatgpt` then `press enter`

## Package

```bash
# from repo root
./scripts/install-linux-deps.sh
./scripts/build-linux.sh
# artifacts → ../../dist/linux/  (.deb + .AppImage)
```

## Scripts

| Command | What |
|---|---|
| `npm run tauri:dev` | Desktop app (what you want day-to-day) |
| `npm run tauri:build` | Release bundle via Tauri |
| `npm run dev` | Vite UI only |
| `npm run codex:setup` | Create `.venv-codex` + install `openai-codex` |
| `npm run typecheck` | `tsc --noEmit` |
| `npm run test` | Small unit tests |

## Troubleshooting

| Symptom | Fix |
|---|---|
| `pkg-config` / `glib-sys` build error | `./scripts/install-linux-deps.sh` |
| `cargo … No such file` | `source ~/.cargo/env` then retry `npm run tauri:dev` |
| Codex tip / no Sign in | You are on Vite-only — use `npm run tauri:dev` |
| Shift+M does nothing | App must be the Tauri build; on Wayland install `grim` + `wtype`/`xdotool` as needed |
