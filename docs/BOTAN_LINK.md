# Botan link

Botan is a small screen (536 × 240) with one button that sits next to the Mac. Coucou tells it what the
agents are doing, and its button approves a permission request or picks the answer to a question.
GitHub build only, off by default: Settings → Botan → "Link with Botan".

Mac side: `NotchBuddy/Sources/App/BotanLink/` — `BotanLinkScreen.swift` (pure: what to show, what a
press may decide), `BotanLinkService.swift` (CoreBluetooth), `BotanLinkSettings.swift`.
Tests: `bash scripts/test-botan-link.sh`.

## Bluetooth

Botan advertises the name `Botan` and one service:

| UUID | Direction | Content |
|---|---|---|
| `b07a0001-6d6f-6368-6900-626f74616e00` | service | |
| `b07a0002-…` | Mac → Botan, write with response | the line to show (UTF-8, < 300 bytes) |
| `b07a0003-…` | Botan → Mac, notify | the button's events |

The same lines and events also work over the USB cable (115 200 baud, one line each, ending in a newline).

## What Botan shows: one line

    state|label|title|detail
    #token state|label|title|detail      (approvals and questions)

- `state`: `idle`, `working`, `thinking`, `approval`, `question`, `error`, `finished`, `sleeping`.
- `label`: agent and project in capitals (`CLAUDE CODE · BOTAN`), ≤ 47 bytes.
- `title`: ≤ 95 bytes, wrapped on two lines, cut with "…".
- `detail`: ≤ 127 bytes. For `question`, the choices separated by `;` (2 to 4, ≤ 39 bytes each).
- Fields are on one line and never contain `|`; Coucou replaces it with `/` and cuts long fields.

One screen at a time, the most urgent first:
1. the permission request on the island's card (`approval`, title "Run npm run build?" for a shell
   command, "Edit Button.tsx?" for a file);
2. the question Claude Code waits on, when it is one question with 2 to 4 short choices and one to pick
   (anything else stays on the Mac);
3. a session or n8n workflow in error, then one at work, then one that just finished;
4. otherwise `idle|BOTAN|Mochi is here.|Nothing running on your Mac.`

The demo mode of the island is not real: Botan is told nothing runs.

## The button

| Event | Meaning |
|---|---|
| `approve\|#token` | short press on an approval |
| `choose\|i\|label\|#token` | button held on choice `i` (0-based) |
| `press` | a press with nothing to decide (Botan's own little game) |

The token is the start of the request id (8 letters or digits), sent with the screen. Coucou applies a
decision only if its token is the one of the request still pending, and checks it again on the main
actor right before answering the hook, exactly as a click on the island's card does. A press on an old
screen never answers a newer request. Botan never denies, never types, never answers what it was not
shown; the Mac's own card keeps working all along.
