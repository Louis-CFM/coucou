// Settings → General → Updates — port of UpdateSettingsSection
// (MacUpdateViews.swift): the toggle, what it does, "Check now" (a click, so
// it works with the toggle off), and "Install X" once a new version is out.

import { Bridge } from "../core/bridge";
import { NO_UPDATE, isBusy, type UpdateStatus } from "../core/update";
import { h } from "../views/dom";
import { t } from "../i18n/i18n";

type Toggle = (on: boolean, onChange: (v: boolean) => void) => HTMLElement;

/** The rows on screen, told about "update-status" (listened to once in main.ts). */
export let updatesListener: ((status: UpdateStatus) => void) | null = null;

export function updateRows(toggle: Toggle, version: string): HTMLElement[] {
  let status: UpdateStatus = { ...NO_UPDATE, current: version };
  const sw = toggle(false, (on) => void Bridge.updateSetConsent(on));
  const install = h("button", {
    onclick: () => void (status.canInstall ? Bridge.updateShow() : Bridge.updateOpenPage()),
  }) as HTMLButtonElement;
  const check = h("button", {
    text: t("Check now"),
    onclick: async () => {
      check.disabled = true;
      feedback.textContent = "";
      const fresh = await Bridge.updateCheck();
      if (fresh) status = fresh;
      draw();
    },
  }) as HTMLButtonElement;
  const feedback = h("span", { class: "hint" });
  const footer = h("span", { class: "hint", style: "flex:1 1 0;min-width:0" });
  const current = h("span", { class: "hint" });

  function draw() {
    sw.classList.toggle("on", status.consent === true);
    sw.setAttribute("aria-pressed", String(status.consent === true));
    const r = status.latest;
    install.style.display = r ? "" : "none";
    if (r) {
      install.textContent = status.canInstall
        ? t("Install {version}", { version: r.version })
        : t("Get {version} on GitHub", { version: r.version });
    }
    check.disabled = status.check === "checking" || isBusy(status.phase);
    feedback.textContent =
      status.check === "upToDate" ? t("Coucou is up to date")
        : status.check === "unreachable" ? t("Couldn't reach GitHub")
          : "";
    footer.textContent = status.platform === "linux"
      ? t("Coucou looks at its own releases on GitHub a few times a day and tells you when one is out. Update it the way you installed it: AppImage, .deb, .rpm or your package manager.")
      : t("Coucou looks at its own releases on GitHub a few times a day. An update is installed only after your click, once its SHA-256 matches the one GitHub publishes.");
    current.textContent = t("You have {version}", { version: status.current || version });
  }

  updatesListener = (fresh) => {
    status = fresh;
    draw();
  };
  void Bridge.updateStatus().then((fresh) => {
    if (fresh) updatesListener?.(fresh);
  });
  draw();

  return [
    h("div", { class: "row" },
      h("label", { text: t("Updates") }),
      sw,
      h("span", { class: "hint", text: t("Tell me when a new version is out") }),
    ),
    h("div", { class: "row" }, h("label", {}), install, check, feedback),
    h("div", { class: "row" }, h("label", {}), footer),
    h("div", { class: "row" }, h("label", {}), current),
  ];
}
