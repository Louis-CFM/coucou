// Portfolio's reports → the page (src-tauri/src/portfolio.rs), and a fresh
// read when the card comes on screen (PortfolioCardView.onAppear).

import { Bridge, onEvent } from "../core/bridge";
import { PORTFOLIO_ID, Portfolio, type PortfolioState } from "../core/portfolio";
import { State } from "../core/state";

let shown = false;

export function registerPortfolioHandlers() {
  void onEvent<PortfolioState>("portfolio", (s) => {
    Portfolio.state = s;
    State.notify();
  });
  void Bridge.portfolioState().then((s) => {
    if (!s) return;
    Portfolio.state = s;
    State.notify();
  });
  State.subscribe(() => {
    const now = State.mode === "expanded" && State.view === "overview" && State.focusTask?.id === PORTFOLIO_ID;
    if (now && !shown) void Bridge.portfolioRefresh();
    shown = now;
  });
}
