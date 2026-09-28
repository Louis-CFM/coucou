# Coucou — Linux

Tauri 2 + TypeScript implementation of the Coucou companion for Linux desktops.

- Full docs: [`docs/linux.md`](../../docs/linux.md)
- Architecture: [`docs/linux-architecture.md`](../../docs/linux-architecture.md)
- macOS app (unchanged): [`NotchBuddy/`](../../NotchBuddy/)

```bash
npm install
npm run typecheck
npm run dev          # Vite UI
npm run tauri:dev    # needs GTK/WebKit -dev packages
```

From repo root:

```bash
./scripts/dev-linux.sh
./scripts/build-linux.sh
```
