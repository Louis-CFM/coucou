// Settings → Integrations → WhatsApp (experimental) — port of
// WhatsAppSettingsSection (WhatsAppViews.swift). Off until turned on; the
// gateway's address and credential go to the credential store; the QR to link
// WhatsApp shows right here. One click installs and starts GOWA, no terminal.

import { Bridge, onEvent } from "../core/bridge";
import {
  DEFAULT_PORT, WHATSAPP_GREEN, WhatsApp, chatFromEntry, defaultUrl, displayNumber, installLabel, installing,
  linkColor, linkLabel, type WhatsAppGateway, type WhatsAppPrefs, type WhatsAppState,
} from "../core/whatsapp";
import { h, clear } from "../views/dom";
import { t } from "../i18n/i18n";

const MUTED = "color:#8E939C;font-size:11px";

let listening = false;
let current: (() => void) | null = null;

function toggleRow(label: string, on: boolean, change: (v: boolean) => void): HTMLElement {
  const sw = h("button", { class: on ? "switch on" : "switch", "aria-pressed": on });
  sw.addEventListener("click", () => {
    const next = !sw.classList.contains("on");
    sw.classList.toggle("on", next);
    change(next);
  });
  return h("div", { class: "row", style: "gap:10px" }, sw, h("span", { style: "font-size:12px", text: label }));
}

function hint(text: string, color = "#8E939C"): HTMLElement {
  return h("div", { class: "hint", style: `color:${color};font-size:11px;line-height:1.4`, text });
}

/**
 * The WhatsApp block under its row in Integrations. `declared`: the pill is in
 * Active pills (without it nothing runs, and the block says so).
 */
export function whatsappSection(declared: () => boolean): HTMLElement {
  const box = h("div", { style: "display:flex;flex-direction:column;gap:7px;padding-top:2px" });
  let showAdvanced = false;
  let testResult: string | null = null;
  let testing = false;
  // What is typed in Advanced survives a redraw from a new snapshot.
  let draft: { gateway: WhatsAppGateway; url: string; credential: string; port: string } | null = null;
  let ignoreEntry = "";

  function prefs(): WhatsAppPrefs {
    return { ...WhatsApp.state.prefs };
  }

  async function setPrefs(next: WhatsAppPrefs, url?: string, credential?: string) {
    await Bridge.whatsappSetPrefs(next, url ?? null, credential ?? null);
  }

  function draw() {
    const s = WhatsApp.state;
    const p = s.prefs;
    // A field being typed in keeps its caret: redraw everything but Advanced's inputs.
    const focused = document.activeElement;
    if (focused && box.contains(focused) && (focused as HTMLElement).dataset.keep) return;
    clear(box);

    box.append(
      h("div", { style: "display:flex;align-items:center;gap:6px" },
        h("span", { style: `width:8px;height:8px;border-radius:50%;background:${WHATSAPP_GREEN}` }),
        h("b", { style: "font-size:12px", text: t("WhatsApp (experimental)") }),
      ),
      hint(t("Unofficial integration: it goes through a gateway you run on this computer. Use it on your own account only. WhatsApp may restrict accounts that abuse it."), "#F5B83D"),
      toggleRow(t("Show my WhatsApp messages"), p.enabled, (on) => void setPrefs({ ...prefs(), enabled: on })),
    );
    if (!p.enabled) return;

    if (!declared()) {
      box.append(hint(t("Make room in Active pills to show the WhatsApp pill (4 at most)."), "#F4505E"));
    }

    // One click: Coucou downloads GOWA, checks it and starts it.
    if (p.gateway === "gowa") box.append(installBlock(s));

    if (showsLinkState(s)) box.append(...linkState(s));

    box.append(
      toggleRow(t("Mute groups (unless I’m mentioned)"), p.muteGroups, (on) => void setPrefs({ ...prefs(), muteGroups: on })),
      toggleRow(t("Stay quiet during Do not disturb"), p.respectFocus, (on) => void setPrefs({ ...prefs(), respectFocus: on })),
    );
    if (p.respectFocus && !s.focusReadable) {
      box.append(hint(t("Windows doesn’t let Coucou read Do not disturb right now: messages still arrive, Mochi keeps reacting.")));
    }
    box.append(
      toggleRow(t("Mark as read when I open a conversation"), p.markReadOnOpen, (on) => void setPrefs({ ...prefs(), markReadOnOpen: on })),
      hint(t("Off: marked read only when you reply. Never when a message just arrives.")),
      ...ignoredChats(s),
      hint(t("Coucou only talks to the gateway on this computer. Messages stay in memory, are never logged or saved, and are forgotten when Coucou quits. No photo or media is ever downloaded.")),
    );

    // Your own gateway (OpenWA, another address, a password, the port): folded away.
    const disclosure = h("button", {
      class: "link-btn",
      style: "align-self:flex-start;background:none;border:0;padding:2px 0;font-weight:500;font-size:12px;color:inherit",
      text: `${showAdvanced ? "▾" : "▸"} ${t("Advanced: your own gateway")}`,
      onclick: () => {
        showAdvanced = !showAdvanced;
        draw();
      },
    });
    box.append(disclosure);
    if (showAdvanced) box.append(advanced(s));
  }

  /** The status and QR once there is a gateway to talk to (before the install, "the gateway doesn't answer" would only confuse). */
  function showsLinkState(s: WhatsAppState): boolean {
    if (s.prefs.gateway !== "gowa" || s.installed || s.url !== defaultUrl("gowa")) return true;
    return s.link.state === "connected" || s.link.state === "needsQr";
  }

  function installBlock(s: WhatsAppState): HTMLElement {
    const el = h("div", { style: "display:flex;flex-direction:column;gap:5px" });
    if (installing(s.install)) {
      el.append(h("div", { class: "row", style: "gap:8px" }, h("span", { style: MUTED, text: "…" }), h("span", { style: "font-size:12px", text: installLabel(s.install) })));
      return el;
    }
    if (s.installed) {
      el.append(h("div", { class: "row", style: "gap:8px" },
        h("span", { style: `color:${WHATSAPP_GREEN}`, text: "✔" }),
        h("span", {
          style: "font-size:12px;flex:1",
          text: s.prefs.installedVersion
            ? t("Gateway GOWA {0} installed, started by Coucou", { 0: s.prefs.installedVersion })
            : t("Your GOWA gateway is set up"),
        }),
        h("button", { text: t("Update"), onclick: () => void Bridge.whatsappInstall() }),
      ));
    } else {
      el.append(
        h("button", {
          class: "primary",
          style: `align-self:flex-start;background:${WHATSAPP_GREEN};border-color:${WHATSAPP_GREEN};font-weight:600;padding:6px 14px`,
          text: `⬇ ${t("Install WhatsApp")}`,
          onclick: () => void Bridge.whatsappInstall(),
        }),
        hint(t("Coucou downloads GOWA, the open-source gateway, from its GitHub page (about 15 MB, once), checks it and starts it. Then scan the QR code with your phone. No Terminal needed.")),
      );
    }
    if ("message" in s.install) el.append(hint(s.install.message, "#F4505E"));
    return el;
  }

  function linkState(s: WhatsAppState): HTMLElement[] {
    const out: HTMLElement[] = [];
    const label = s.link.state === "connected" && s.me
      ? t("Connected as {0}", { 0: displayNumber(s.me) })
      : linkLabel(s.link);
    out.push(h("div", { class: "row", style: "gap:6px" },
      h("span", { style: `width:6px;height:6px;border-radius:50%;background:${linkColor(s.link)}` }),
      h("span", { style: "font-size:12px", text: label }),
    ));
    if (s.link.state === "connected") out.push(hint(webhookLine(s)));
    if (s.link.state === "needsQr") {
      if (s.qr) {
        out.push(h("div", { style: "display:flex;gap:10px;align-items:flex-start" },
          h("img", { src: s.qr, alt: "", style: "width:168px;height:168px;image-rendering:pixelated;background:#fff;border-radius:6px" }),
          hint(t("On your phone: WhatsApp › Settings › Linked devices › Link a device, then scan this code.")),
        ));
      } else {
        out.push(h("span", { style: MUTED, text: "…" }));
      }
    }
    return out;
  }

  function webhookLine(s: WhatsAppState): string {
    switch (s.webhook.state) {
      case "registered": return t("Live: new messages arrive at once.");
      case "portBusy": return t("Port {0} is taken: pick another one. Checking every 20 s meanwhile.", { 0: s.prefs.port });
      case "refused": return t("The gateway refused Coucou’s address ({0}). Checking every 20 s instead.", { 0: s.webhook.detail });
      default: return t("Checking for new messages every 20 s.");
    }
  }

  function ignoredChats(s: WhatsAppState): HTMLElement[] {
    const out: HTMLElement[] = [h("div", { style: "font-size:12px;font-weight:500;padding-top:4px", text: t("Ignored chats") })];
    for (const chat of [...s.prefs.ignored].sort()) {
      const name = s.conversations.find((c) => c.id === chat)?.name ?? displayNumber(chat);
      out.push(h("div", { class: "row", style: "gap:6px" },
        h("span", { style: "font-size:12px;flex:1", text: name }),
        h("button", { text: t("Remove"), onclick: () => void Bridge.whatsappUnignore(chat) }),
      ));
    }
    const input = h("input", {
      type: "text", placeholder: t("Phone number or chat id to ignore"), style: "flex:1;min-width:0", "data-keep": "1",
    }) as HTMLInputElement;
    input.value = ignoreEntry;
    const add = h("button", { text: t("Add") }) as HTMLButtonElement;
    add.disabled = !ignoreEntry.trim();
    const submit = () => {
      const chat = chatFromEntry(input.value);
      if (!chat) return;
      ignoreEntry = "";
      input.value = "";
      input.blur();
      void Bridge.whatsappIgnore(chat);
    };
    input.addEventListener("input", () => {
      ignoreEntry = input.value;
      add.disabled = !ignoreEntry.trim();
    });
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") submit();
    });
    add.addEventListener("click", submit);
    out.push(h("div", { class: "row", style: "gap:6px" }, input, add));
    return out;
  }

  function advanced(s: WhatsAppState): HTMLElement {
    const d = draft ?? (draft = {
      gateway: s.prefs.gateway,
      url: s.url === defaultUrl(s.prefs.gateway) ? "" : s.url,
      credential: "",
      port: String(s.prefs.port),
    });
    const el = h("div", { style: "display:flex;flex-direction:column;gap:7px;padding:4px 0 0 2px" });

    const picker = h("div", { class: "row", style: "gap:6px" },
      h("span", { style: "font-size:12px;min-width:70px", text: t("Gateway") }),
    );
    for (const kind of ["gowa", "openwa"] as const) {
      picker.append(h("button", {
        class: d.gateway === kind ? "primary" : "",
        text: kind === "gowa" ? "GOWA" : "OpenWA",
        onclick: () => {
          // Still on the other gateway's default address: follow the switch.
          if (d.url === "" || d.url === defaultUrl(d.gateway)) d.url = "";
          d.gateway = kind;
          draw();
        },
      }));
    }

    const url = h("input", { type: "text", placeholder: defaultUrl(d.gateway), style: "flex:1;min-width:0", "data-keep": "1" }) as HTMLInputElement;
    url.value = d.url;
    url.addEventListener("input", () => (d.url = url.value));
    const credential = h("input", {
      type: "password", style: "flex:1;min-width:0", "data-keep": "1",
      placeholder: s.hasCredential
        ? "••••••••"
        : d.gateway === "gowa" ? t("Basic auth  (user:password, if set)") : t("API key  (owa_k1_…)"),
    }) as HTMLInputElement;
    credential.value = d.credential;
    credential.addEventListener("input", () => (d.credential = credential.value));
    const port = h("input", { type: "text", placeholder: String(DEFAULT_PORT), style: "width:80px", "data-keep": "1" }) as HTMLInputElement;
    port.value = d.port;
    port.addEventListener("input", () => (d.port = port.value));

    const save = async () => {
      const n = Number(d.port);
      const next: WhatsAppPrefs = {
        ...prefs(),
        gateway: d.gateway,
        port: Number.isInteger(n) && n >= 1024 && n <= 65535 ? n : s.prefs.port,
      };
      d.port = String(next.port);
      // An empty credential field leaves the stored one alone.
      await setPrefs(next, d.url.trim(), d.credential.trim() ? d.credential.trim() : undefined);
      d.credential = "";
    };

    el.append(
      picker,
      h("div", { class: "row", style: "gap:6px" }, url),
      h("div", { class: "row", style: "gap:6px" }, credential),
    );
    if (d.gateway === "gowa") {
      el.append(
        toggleRow(t("Start GOWA automatically"), s.prefs.autostart, (on) => void setPrefs({ ...prefs(), autostart: on })),
      );
      if (s.prefs.autostart) {
        el.append(hint(t("Coucou runs it on this computer only (127.0.0.1, the URL’s port), without downloading media, and stops it when Coucou quits. Its WhatsApp session stays in Coucou’s GOWA folder in your local app data.")));
      }
    }
    el.append(
      h("div", { class: "row", style: "gap:6px" }, h("span", { style: "font-size:12px", text: t("Coucou’s webhook port") }), port),
      h("div", { class: "row", style: "gap:8px" },
        h("button", { class: "primary", text: t("Save WhatsApp"), onclick: () => void save().then(() => {
          (document.activeElement as HTMLElement | null)?.blur();
          draw();
        }) }),
        h("button", {
          text: t("Test connection"),
          disabled: testing,
          onclick: async () => {
            await save();
            testing = true;
            testResult = null;
            (document.activeElement as HTMLElement | null)?.blur();
            draw();
            testResult = (await Bridge.whatsappTest()) ?? null;
            testing = false;
            draw();
          },
        }),
        testing ? h("span", { style: MUTED, text: "…" }) : null,
      ),
    );
    if (testResult) el.append(h("div", { style: MUTED, text: testResult }));
    return el;
  }

  current = draw;
  if (!listening) {
    listening = true;
    void onEvent<WhatsAppState>("whatsapp", (s) => {
      WhatsApp.state = s;
      current?.();
    });
  }
  void Bridge.whatsappState().then((s) => {
    if (s) WhatsApp.state = s;
    draw();
  });
  draw();
  return box;
}
