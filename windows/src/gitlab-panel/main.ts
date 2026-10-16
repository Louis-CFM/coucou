// The GitLab panel's page (gitlab-panel.html). Rust reads GitLab and sends the
// whole dashboard in `gitlab-dashboard` events; this page only draws it (view.ts).

import "./panel.css";
import { Bridge, onEvent } from "../core/bridge";
import type { Dashboard } from "../core/gitlab-panel";
import type { Settings } from "../core/state";
import { resolveLanguage, setLanguage, systemLanguages } from "../i18n/i18n";
import { PanelView } from "./view";

async function main() {
  const boot = await Bridge.boot();
  setLanguage(resolveLanguage(boot?.settings.language, systemLanguages()));
  const root = document.getElementById("gp")!;
  const view = new PanelView(root);
  view.setAutoClose(boot?.settings.autoCloseInterval ?? 15);
  view.setDashboard((await Bridge.gitlabDashboard()) ?? null);
  // Hovering the slim bar unfolds it; the pointer away for the island's auto-close delay folds it.
  root.addEventListener("mouseenter", () => view.pointerEnter());
  root.addEventListener("mouseleave", () => view.pointerLeave());

  void onEvent<Dashboard | null>("gitlab-dashboard", (dash) => view.setDashboard(dash));
  void onEvent<boolean>("gitlab-panel-open", (open) => {
    if (open) void Bridge.gitlabDashboard().then((dash) => view.setDashboard(dash ?? null));
    else view.closed();
  });
  void onEvent<boolean>("gitlab-panel-mode", (expanded) => view.setMode(expanded));
  void onEvent<Settings>("settings-changed", (s) => {
    view.setAutoClose(s.autoCloseInterval);
    setLanguage(resolveLanguage(s.language, systemLanguages()));
    view.render();
  });
}

void main();
