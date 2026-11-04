// Settings → Integrations → WhatsApp (experimental) — a port of WhatsAppSettingsSection
// (WhatsAppViews.swift). Off until turned on. "Install WhatsApp" downloads GOWA from its GitHub
// releases on that click only; the QR to link WhatsApp shows right here. The gateway's address and
// credential go to the credential store through Rust, which never hands the credential back.

import { Bridge, onEvent } from "../core/bridge";
import {
  DEFAULT_PORT, DEFAULT_URLS, WHATSAPP_GREEN, installError, installStepLabel, isInstalling, linkColor, linkLabel,
  showsLinkState, testResultLabel, webhookLine, type WaSettingsView,
} from "../core/whatsapp";
import { h } from "../views/dom";
import { t } from "../i18n/i18n";

type Toggle = (on: boolean, onChange: (v: boolean) => void) => HTMLElement;

export interface WhatsAppSettingsHost {
  toggle: Toggle;
  /** Whether the WhatsApp pill is among the active ones. */
  pillActive(): boolean;
  /** Turns the pill on (when a slot is free) or off, and saves. */
  setPill(on: boolean): void;
  /** How many pills may be active. */
  maxPills: number;
}

const hintStyle = (color: string) => `color:${color}`;

export function whatsappSection(host: WhatsAppSettingsHost): HTMLElement {
  let view: WaSettingsView | null = null;
  let showAdvanced = false;
  /** The advanced fields are filled from Rust once, then left to the user while they type. */
  let fieldsFilled = false;
  let testing = false;
  let testResult = "";
  let lastInstall = "";

  // ── Built once ──
  const enableSwitch = host.toggle(false, (on) => void setEnabled(on));
  const muteSwitch = host.toggle(true, (on) => void setOptions({ muteGroups: on }));
  const readSwitch = host.toggle(true, (on) => void setOptions({ markReadOnOpen: on }));
  const body = h("div", { style: "display:flex;flex-direction:column;gap:10px" });
  const dynamic = h("div", { style: "display:flex;flex-direction:column;gap:10px" });
  const ignoredList = h("div", { style: "display:flex;flex-direction:column;gap:4px" });
  const ignoreInput = h("input", {
    type: "text", placeholder: t("Phone number or chat id to ignore"), autocomplete: "off", spellcheck: "false",
    style: "flex:1 1 auto;min-width:0",
  }) as HTMLInputElement;
  const addBtn = h("button", { text: t("Add") });

  // Advanced
  const advancedBtn = h("button", { text: t("Advanced: your own gateway") });
  const advanced = h("div", { style: "display:flex;flex-direction:column;gap:10px" });
  const gatewaySelect = h("select", {},
    h("option", { value: "gowa", text: "GOWA" }),
    h("option", { value: "openwa", text: "OpenWA" }),
  ) as HTMLSelectElement;
  const urlInput = h("input", { type: "text", autocomplete: "off", spellcheck: "false", style: "flex:1 1 auto;min-width:0" }) as HTMLInputElement;
  const credentialInput = h("input", { type: "password", autocomplete: "off", spellcheck: "false", style: "flex:1 1 auto;min-width:0" }) as HTMLInputElement;
  const credentialRemove = h("button", { class: "danger", text: t("Remove") });
  let autoStart = false;
  const autoStartSwitch = host.toggle(false, (on) => {
    autoStart = on;
    drawAdvanced();
  });
  const pathInput = h("input", {
    type: "text", placeholder: t("Path to the GOWA binary (whatsapp)"), autocomplete: "off", spellcheck: "false",
    style: "flex:1 1 auto;min-width:0",
  }) as HTMLInputElement;
  const autoStartHint = h("div", { class: "hint" });
  const autoStartBlock = h("div", { style: "display:flex;flex-direction:column;gap:8px" });
  const portInput = h("input", { type: "number", min: "1024", max: "65535", style: "width:90px" }) as HTMLInputElement;
  const saveBtn = h("button", { class: "primary", text: t("Save WhatsApp") });
  const testBtn = h("button", { text: t("Test connection") });
  const testNote = h("div", { class: "hint" });
  const saveNote = h("div", {});

  const switchState = (el: HTMLElement, on: boolean) => {
    el.classList.toggle("on", on);
    el.setAttribute("aria-pressed", String(on));
  };

  async function setOptions(change: Partial<{ enabled: boolean; muteGroups: boolean; markReadOnOpen: boolean }>) {
    const p = view?.prefs;
    if (!p) return;
    const next = { enabled: p.enabled, muteGroups: p.muteGroups, markReadOnOpen: p.markReadOnOpen, ...change };
    try {
      await Bridge.whatsappSetOptions(next.enabled, next.muteGroups, next.markReadOnOpen);
    } catch {
      // The next report puts the switches back as they are.
    }
  }

  /** WhatsAppController.setEnabled: on also makes room for its pill when a slot is free. */
  async function setEnabled(on: boolean) {
    await setOptions({ enabled: on });
    host.setPill(on);
    draw();
  }

  function addIgnored() {
    const raw = ignoreInput.value.trim();
    if (!raw) return;
    ignoreInput.value = "";
    void Bridge.whatsappIgnore(raw);
  }
  addBtn.addEventListener("click", addIgnored);
  ignoreInput.addEventListener("keydown", (e) => {
    if (e.key === "Enter") addIgnored();
  });

  advancedBtn.addEventListener("click", () => {
    showAdvanced = !showAdvanced;
    drawAdvanced();
  });

  gatewaySelect.addEventListener("change", () => {
    const kind = gatewaySelect.value as "gowa" | "openwa";
    const other = kind === "gowa" ? DEFAULT_URLS.openwa : DEFAULT_URLS.gowa;
    // Still on the other gateway's default address: follow the switch.
    if (urlInput.value.trim() === other) urlInput.value = "";
    drawAdvanced();
  });

  async function saveGateway(credential: string | null) {
    const port = Number(portInput.value);
    saveNote.replaceChildren();
    try {
      await Bridge.whatsappSaveGateway({
        gateway: gatewaySelect.value === "openwa" ? "openwa" : "gowa",
        url: urlInput.value.trim(),
        credential,
        port: Number.isInteger(port) && port >= 1024 && port <= 65535 ? port : (view?.prefs.port ?? DEFAULT_PORT),
        autoStart,
        gowaPath: pathInput.value.trim(),
      });
      credentialInput.value = "";
      return true;
    } catch (err) {
      saveNote.append(h("div", { class: "notice err", text: t("Could not save: {error}", { error: String(err) }) }));
      return false;
    }
  }

  saveBtn.addEventListener("click", () => {
    const typed = credentialInput.value.trim();
    void saveGateway(typed ? typed : null);
  });
  credentialRemove.addEventListener("click", () => void saveGateway(""));
  testBtn.addEventListener("click", async () => {
    const typed = credentialInput.value.trim();
    if (!(await saveGateway(typed ? typed : null))) return;
    testing = true;
    testResult = "";
    drawAdvanced();
    const result = await Bridge.whatsappTest();
    testing = false;
    testResult = result ? testResultLabel(result) : "";
    drawAdvanced();
  });

  // ── Drawn from each report ──

  function drawAdvanced() {
    const v = view;
    advanced.style.display = showAdvanced ? "" : "none";
    if (!v) return;
    const kind = gatewaySelect.value === "openwa" ? "openwa" : "gowa";
    urlInput.placeholder = DEFAULT_URLS[kind];
    credentialInput.placeholder = v.hasCredential
      ? `••••••••  ${t("(stored)")}`
      : kind === "gowa" ? t("Basic auth  (user:password, if set)") : t("API key  (owa_k1_…)");
    credentialRemove.style.display = v.hasCredential ? "" : "none";
    switchState(autoStartSwitch, autoStart);
    autoStartBlock.replaceChildren();
    if (kind === "gowa") {
      autoStartBlock.append(h("div", { class: "row" }, h("label", { text: t("Start GOWA automatically") }), autoStartSwitch));
      if (autoStart) {
        autoStartHint.textContent = t("Coucou runs it on this computer only (127.0.0.1, the URL’s port), without downloading media, and stops it when Coucou quits. Its WhatsApp session stays in {path}.", { path: v.gowaDir });
        autoStartBlock.append(h("div", { class: "row" }, h("label", { text: "" }), pathInput), autoStartHint);
      }
    }
    testBtn.disabled = testing;
    testNote.textContent = testing ? "…" : testResult;
  }

  function fillFields(v: WaSettingsView) {
    gatewaySelect.value = v.prefs.gateway;
    urlInput.value = v.url;
    portInput.value = String(v.prefs.port);
    autoStart = v.prefs.autoStart;
    pathInput.value = v.prefs.gowaPath;
    fieldsFilled = true;
  }

  function installBlock(v: WaSettingsView): HTMLElement[] {
    const out: HTMLElement[] = [];
    if (isInstalling(v.install)) {
      out.push(h("div", { class: "hint", text: installStepLabel(v.install) }));
      return out;
    }
    if (v.installed) {
      const update = h("button", { text: t("Update"), onclick: () => void Bridge.whatsappInstall() });
      const text = v.prefs.gowaVersion
        ? t("Gateway GOWA {version} installed, started by Coucou", { version: v.prefs.gowaVersion })
        : t("Your GOWA gateway is set up");
      out.push(h("div", { class: "row" },
        h("span", { style: `color:${WHATSAPP_GREEN}`, text: "✓" }),
        h("span", { style: "font-size:12.5px", text }),
        h("span", { class: "spacer" }),
        update,
      ));
    } else {
      out.push(
        h("div", { class: "row" }, h("button", {
          class: "primary", text: t("Install WhatsApp"), onclick: () => void Bridge.whatsappInstall(),
        })),
        h("div", { class: "hint", text: t("Coucou downloads GOWA, the open-source gateway, from its GitHub page (about 15 MB, once), checks it and starts it. Then scan the QR code with your phone. No command line needed.") }),
      );
    }
    const failed = installError(v.install);
    if (failed) out.push(h("div", { class: "notice err", text: failed }));
    return out;
  }

  function linkState(v: WaSettingsView): HTMLElement[] {
    const out: HTMLElement[] = [];
    const text = v.link.state === "connected" && v.me ? t("Connected as {number}", { number: v.me }) : linkLabel(v.link);
    out.push(h("div", { class: "row", style: "gap:8px" },
      h("i", { class: "dot", style: `background:${linkColor(v.link)}` }),
      h("span", { style: "font-size:12.5px", text }),
    ));
    if (v.link.state === "connected") out.push(h("div", { class: "hint", text: webhookLine(v.webhook) }));
    if (v.link.state === "needsQr") {
      if (v.qr) {
        out.push(h("div", { class: "row", style: "align-items:flex-start" },
          h("img", { class: "qr", src: v.qr, width: "168", height: "168", alt: "", style: "width:168px;height:168px;image-rendering:pixelated" }),
          h("div", { class: "hint", style: "flex:1 1 160px", text: t("On your phone: WhatsApp › Settings › Linked devices › Link a device, then scan this code.") }),
        ));
      } else {
        out.push(h("div", { class: "hint", text: "…" }));
      }
    }
    return out;
  }

  function draw() {
    const v = view;
    if (!v) return;
    // Installed by Coucou just now: the fields follow what it set.
    const install = JSON.stringify(v.install);
    if (!fieldsFilled || (install !== lastInstall && v.install.step === "done")) fillFields(v);
    lastInstall = install;
    switchState(enableSwitch, v.prefs.enabled);
    switchState(muteSwitch, v.prefs.muteGroups);
    switchState(readSwitch, v.prefs.markReadOnOpen);
    body.style.display = v.prefs.enabled ? "" : "none";

    const parts: HTMLElement[] = [];
    if (v.prefs.enabled && !host.pillActive()) {
      parts.push(h("div", { class: "hint", style: hintStyle("#F4505E"), text: t("Turn off another pill to make room for WhatsApp ({max} at most).", { max: host.maxPills }) }));
    }
    // One click: Coucou downloads GOWA, checks it and starts it. No command line.
    if (v.prefs.gateway === "gowa") parts.push(...installBlock(v));
    if (showsLinkState(v)) parts.push(...linkState(v));
    dynamic.replaceChildren(...parts);

    ignoredList.replaceChildren(...v.ignored.map((chat) => h("div", { class: "row", style: "gap:8px" },
      h("span", { style: "font-size:12.5px", text: chat.name }),
      h("span", { class: "spacer" }),
      h("button", { text: t("Remove"), onclick: () => void Bridge.whatsappUnignore(chat.id) }),
    )));
    drawAdvanced();
  }

  advanced.append(
    h("div", { class: "row" }, h("label", { text: t("Gateway") }), gatewaySelect),
    h("div", { class: "row" }, h("label", { text: "" }), urlInput),
    h("div", { class: "row" }, h("label", { text: "" }), credentialInput, credentialRemove),
    autoStartBlock,
    h("div", { class: "row" }, h("label", { text: t("Coucou’s webhook port") }), portInput),
    h("div", { class: "row" }, saveBtn, testBtn),
    testNote,
    saveNote,
  );

  body.append(
    dynamic,
    h("div", { class: "row" }, h("label", { text: t("Mute groups (unless I’m mentioned)") }), muteSwitch),
    h("div", { class: "row" }, h("label", { text: t("Mark as read when I open a conversation") }), readSwitch),
    h("div", { class: "hint", text: t("Off: marked read only when you reply. Never when a message just arrives.") }),
    h("div", { class: "subhead", text: t("Ignored chats") }),
    ignoredList,
    h("div", { class: "row" }, ignoreInput, addBtn),
    h("div", { class: "hint", text: t("Coucou only talks to the gateway on this computer. Messages stay in memory, are never logged or saved, and are forgotten when Coucou quits. No photo or media is ever downloaded.") }),
    h("div", { class: "row" }, advancedBtn),
    advanced,
  );

  const section = h(
    "section",
    {},
    h("h2", {}, h("i", { class: "dot", style: `background:${WHATSAPP_GREEN}` }), h("span", { text: t("WhatsApp (experimental)") })),
    h("div", { class: "hint", style: hintStyle("#F5B83D"), text: t("Unofficial integration: it goes through a gateway you run on this computer. Use it on your own account only. WhatsApp may restrict accounts that abuse it.") }),
    h("div", { class: "row" }, h("label", { text: t("Show my WhatsApp messages") }), enableSwitch),
    body,
  );
  body.style.display = "none";
  advanced.style.display = "none";

  const apply = (v: WaSettingsView | null) => {
    if (!v) return;
    view = v;
    draw();
  };
  void Bridge.whatsappSettings().then(apply);
  let off: (() => void) | null = null;
  void onEvent<WaSettingsView>("whatsapp-settings", (v) => {
    // A section drawn again (another page, a language change) leaves this one behind.
    if (!section.isConnected && view) {
      off?.();
      return;
    }
    apply(v);
  }).then((unlisten) => {
    off = unlisten;
  });
  return section;
}
