// Crypto's reports → the page (src-tauri/src/crypto.rs): prices for the card,
// a fresh read when the card comes on screen, and the opt-in alert, which puts
// the Crypto pill in front and shows the island (CryptoController.checkAlerts).

import { Bridge, onEvent } from "../core/bridge";
import { CRYPTO_ID, Crypto, type CryptoState } from "../core/crypto";
import { State } from "../core/state";

export interface CryptoHost {
  reveal(): void;
}

let shown = false;

export function registerCryptoHandlers(island: CryptoHost) {
  void onEvent<CryptoState>("crypto", (s) => {
    Crypto.state = s;
    State.notify();
  });
  void onEvent<string>("crypto-alert", () => {
    if (State.paused) return;
    if (State.mode !== "expanded" && State.tasks.some((t) => t.id === CRYPTO_ID)) State.setFocus(CRYPTO_ID);
    island.reveal();
    State.notify();
  });
  void Bridge.cryptoState().then((s) => {
    if (!s) return;
    Crypto.state = s;
    State.notify();
  });
  // The card came on screen: read again if the last read is older than 20 s.
  State.subscribe(() => {
    const now = State.mode === "expanded" && State.view === "overview" && State.focusTask?.id === CRYPTO_ID;
    if (now && !shown) void Bridge.cryptoRefresh();
    shown = now;
  });
}
