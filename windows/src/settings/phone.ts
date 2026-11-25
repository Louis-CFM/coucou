// Settings → Android phone: the switch for the phone link and the code that
// pairs a phone with this computer. Off until the user turns it on.

import { Bridge, type PhoneChatStatus, type PhoneLinkPairing, type PhoneLinkStatus, type PhoneRelayState, type PhoneRelayStatus } from "../core/bridge";
import { modelId, modelsOf, toggleModel, usableProviders } from "../core/phone-chat";
import { pillDefinition } from "../core/pills";
import { PROVIDERS, type ProviderDef } from "../core/providers";
import type { Settings } from "../core/state";
import { animate, MACOS_JELLY } from "../hub/motion";
import { icon } from "../hub/ui";
import { dot, h, svg } from "../views/dom";
import { ICONS } from "../views/icons";
import { t, tl } from "../i18n/i18n";

type Toggle = (on: boolean, onChange: (v: boolean) => void) => HTMLElement;

function prefersReducedMotion(): boolean {
  return typeof window !== "undefined" && window.matchMedia?.("(prefers-reduced-motion: reduce)")?.matches === true;
}

function revealSmoothly(el: HTMLElement) {
  if (prefersReducedMotion()) return;
  animate(el, { opacity: [0, 1], y: [-6, 0] }, MACOS_JELLY.snappy);
}

/** Accessible native checkbox rendered with a clean macOS rounded check indicator. */
function macCheckBox(checked: boolean, onChange: (next: boolean) => void): { box: HTMLInputElement; indicator: HTMLElement } {
  const box = h("input", { type: "checkbox", class: "phone-check-native" }) as HTMLInputElement;
  box.checked = checked;
  box.addEventListener("change", () => onChange(box.checked));
  const indicator = h(
    "span",
    { class: "phone-check-box", "aria-hidden": "true" },
    svg(ICONS.check, 10, { stroke: 2.6 }),
  );
  return { box, indicator };
}

/** Shared inset-grouped macOS settings row with right-aligned switch and async error feedback. */
function settingToggleRow(
  title: string,
  description: string,
  makeToggle: Toggle,
  load: () => Promise<{ enabled: boolean } | null | undefined>,
  save: (next: boolean) => Promise<unknown>,
): HTMLElement {
  const note = h("div", { class: "notice err" });
  const noteWrap = h("div", { class: "phone-inline-notice" });

  const switchEl = makeToggle(false, (next) => {
    void (async () => {
      noteWrap.replaceChildren();
      try {
        await save(next);
      } catch (err) {
        switchEl.classList.remove("on");
        switchEl.setAttribute("aria-pressed", "false");
        note.textContent = String(err);
        noteWrap.append(note);
      }
    })();
  });

  // The switch shows what Rust says, not what the page remembers.
  void load().then((status) => {
    if (!status) return;
    switchEl.classList.toggle("on", status.enabled);
    switchEl.setAttribute("aria-pressed", String(status.enabled));
  });

  const row = h(
    "div",
    { class: "phone-row" },
    h(
      "div",
      { class: "phone-row-label" },
      h("span", { class: "phone-row-title", text: title }),
      h("span", { class: "phone-row-desc", text: description }),
    ),
    switchEl,
  );

  return h("div", { class: "phone-row-wrap" }, row, noteWrap);
}

/**
 * The relay block ("Away from home Wi-Fi") is hidden until a relay is ready to use: the code and its tests stay.
 * Testers who start Coucou with COUCOU_RELAY_SETTINGS=1 see it (docs/RELAY_DEPLOY.md), and so does anyone whose relay
 * is already on. Nothing else changes.
 */
function relaySlot(makeToggle: Toggle, refreshPairing: () => void): HTMLElement {
  const slot = h("div", { class: "phone-relay-slot" });
  void Bridge.phoneRelayStatus().then((status) => {
    if (status?.shown) slot.replaceWith(relayBlock(makeToggle, refreshPairing));
  });
  return slot;
}

export function phoneSection(on: boolean, makeToggle: Toggle, settings: Settings): HTMLElement {
  const detail = h("div", { class: "phone-detail-stack" });
  const noteWrap = h("div", { class: "phone-inline-notice" });
  /** Where the pairing code is drawn, so showing it never hides the switches below. */
  const pairingBox = h("div", { class: "phone-pairing-slot" });

  // Compact Hero Overview elements
  const heroIcon = h("div", { class: `phone-hero-icon ${on ? "on" : ""}` }, icon("phone"));
  const heroStatusDot = h("i", { class: "phone-status-dot" });
  const heroStatusText = h("span", { text: on ? t("Enabled · Listening") : t("Off") });
  const heroStatusPill = h("div", { class: `phone-status-pill ${on ? "listening" : ""}` }, heroStatusDot, heroStatusText);

  const heroCard = h(
    "div",
    { class: "phone-hero" },
    h(
      "div",
      { class: "phone-hero-main" },
      heroIcon,
      h(
        "div",
        { class: "phone-hero-copy" },
        h("h1", { class: "phone-hero-title", text: t("Android phone") }),
        h("p", { class: "phone-hero-subtitle", text: t("View agent activity, answer approvals, and chat from your phone over local Wi-Fi.") }),
      ),
    ),
    heroStatusPill,
  );

  // Live metadata nodes updated in-place on poll so open pairing UI never flickers
  const clientsEl = h("span", {});
  const endpointEl = h("code", { class: "phone-endpoint" });
  const networkAddressEl = h("div", { class: "hint" });
  let lastRunning: boolean | null = null;
  let pairingOpen = false;
  let showBtn: HTMLButtonElement | null = null;

  const updateHeroAndMeta = (status: PhoneLinkStatus | null) => {
    const running = Boolean(status?.running);
    const count = status?.clients ?? 0;
    const hasError = Boolean(status?.error);

    heroIcon.classList.toggle("on", running);
    heroStatusPill.classList.remove("listening", "connected", "err");
    if (hasError) {
      heroStatusPill.classList.add("err");
      heroStatusText.textContent = t("Unavailable");
    } else if (!running) {
      heroStatusText.textContent = t("Off");
    } else if (count > 0) {
      heroStatusPill.classList.add("connected");
      heroStatusText.textContent = t("Connected · {count}", { count });
    } else {
      heroStatusPill.classList.add("listening");
      heroStatusText.textContent = t("Enabled · Listening");
    }

    if (running && status) {
      const address = status.host ? `${status.host}:${status.port}` : `:${status.port}`;
      clientsEl.textContent = t("Phones connected: {count}", { count });
      endpointEl.textContent = address;
      networkAddressEl.textContent = t("The phone connects to {address}", { address });
    }
  };

  const showError = (message: string) => {
    noteWrap.replaceChildren(
      h("div", { class: "notice err", text: t("Could not turn it on: {error}", { error: message }) }),
    );
  };

  const syncPairingButton = () => {
    if (!showBtn) return;
    showBtn.textContent = pairingOpen ? t("Hide pairing code") : t("Show pairing code");
    showBtn.classList.toggle("primary", !pairingOpen);
    showBtn.setAttribute("aria-expanded", String(pairingOpen));
  };

  /** The code itself, which lets a phone in: shown only when asked for. */
  const reveal = async (status: PhoneLinkStatus | null, newCode: boolean) => {
    if (showBtn) showBtn.disabled = true;
    try {
      const pairing = newCode ? await Bridge.phoneLinkNewPairing() : await Bridge.phoneLinkPairing();
      const panel = h("div", { class: "phone-qr-panel" }, ...pairingRows(pairing, () => void reveal(status, true)));
      pairingBox.replaceChildren(panel);
      pairingOpen = true;
      syncPairingButton();
      revealSmoothly(panel);
    } catch (err) {
      showError(String(err));
    } finally {
      if (showBtn) showBtn.disabled = false;
    }
  };

  const collapsePairing = () => {
    pairingBox.replaceChildren();
    pairingOpen = false;
    syncPairingButton();
  };

  /** After the relay settings change, a code that is on screen would be stale: show the current one. */
  const refreshPairing = async () => {
    if (!pairingOpen || pairingBox.childElementCount === 0) return;
    try {
      const panel = h("div", { class: "phone-qr-panel" }, ...pairingRows(await Bridge.phoneLinkPairing(), () => void reveal(null, true)));
      pairingBox.replaceChildren(panel);
    } catch (err) {
      showError(String(err));
    }
  };

  const connectionGroup = h("div", { class: "phone-group" });
  const connectionExtras = h("div", { class: "phone-connection-extras" });

  /** Draws what is below the switch from the link's state. */
  const draw = (status: PhoneLinkStatus | null) => {
    noteWrap.replaceChildren();
    updateHeroAndMeta(status);
    if (status?.error) showError(status.error);

    const running = Boolean(status?.running);
    if (lastRunning === running) return;
    lastRunning = running;

    connectionExtras.replaceChildren();
    detail.replaceChildren();
    pairingBox.replaceChildren();
    pairingOpen = false;
    showBtn = null;

    if (!running || !status) return;

    const btn = h("button", {
      class: "phone-btn primary",
      type: "button",
      "aria-expanded": "false",
      text: t("Show pairing code"),
    }) as HTMLButtonElement;
    showBtn = btn;
    btn.addEventListener("click", () => {
      if (pairingOpen) collapsePairing();
      else void reveal(status, false);
    });

    const pairRow = h(
      "div",
      { class: "phone-row" },
      h(
        "div",
        { class: "phone-row-label" },
        h("span", { class: "phone-row-title", text: t("Pair a device") }),
        h("div", { class: "phone-meta-line" }, clientsEl, h("span", { text: "·" }), endpointEl),
      ),
      btn,
    );

    // Progressive disclosure for Wi-Fi / Windows Firewall / mDNS details
    const disclosureBody = h(
      "div",
      { class: "phone-disclosure-body" },
      networkAddressEl,
      h("div", { class: "hint", text: t("If Windows asks about the firewall, allow Coucou on private networks. The phone and this computer must be on the same Wi-Fi.") }),
      h("div", { class: "hint", text: t("Your phone finds this computer again by itself when the network changes. It is announced on your local network only while this switch is on. Some hotspots and guest networks block this.") }),
    );
    disclosureBody.hidden = true;

    const chevron = svg(ICONS.chevronDown, 13, { stroke: 2.2 });
    chevron.classList.add("phone-disclosure-chevron");
    const disclosureBtn = h(
      "button",
      {
        class: "phone-disclosure-btn",
        type: "button",
        "aria-expanded": "false",
      },
      h(
        "div",
        { class: "phone-row-label" },
        h("span", { class: "phone-row-title", text: t("Network & firewall details") }),
        h("span", { class: "phone-row-desc", text: t("Same Wi-Fi required · local discovery active") }),
      ),
      chevron,
    ) as HTMLButtonElement;
    disclosureBtn.addEventListener("click", () => {
      const expanded = disclosureBody.hidden;
      disclosureBody.hidden = !expanded;
      disclosureBtn.setAttribute("aria-expanded", String(expanded));
      if (expanded) revealSmoothly(disclosureBody);
    });

    connectionExtras.append(
      pairRow,
      pairingBox,
      h("div", { class: "phone-disclosure" }, disclosureBtn, disclosureBody),
    );

    const privacyGroup = h(
      "div",
      { class: "phone-group" },
      detailsBlock(makeToggle),
      answersBlock(makeToggle),
      diffsBlock(makeToggle),
      usageBlock(makeToggle),
      recapBlock(makeToggle),
    );

    detail.append(
      relaySlot(makeToggle, () => void refreshPairing()),
      h(
        "div",
        { class: "phone-section" },
        h(
          "div",
          { class: "phone-section-header" },
          h("span", { class: "phone-section-title", text: t("Privacy & approvals") }),
          h("span", { class: "phone-section-meta", text: t("Allow requires fingerprint or screen-lock confirmation.") }),
        ),
        privacyGroup,
      ),
      servicesBlock(),
      chatBlock(makeToggle, settings),
      coudropBlock(),
    );
  };

  /** Kept up to date while the window is open and the link is on; updates in place without flicker. */
  const watch = window.setInterval(() => {
    if (!page.isConnected) return window.clearInterval(watch);
    if (document.visibilityState !== "visible") return;
    void Bridge.phoneLinkStatus().then((s) => {
      if (!s) return;
      if (Boolean(s.running) !== lastRunning) {
        draw(s);
      } else {
        updateHeroAndMeta(s);
      }
    });
  }, 5000);

  const switchEl = makeToggle(on, (next) => {
    void (async () => {
      try {
        draw(await Bridge.phoneLinkSetEnabled(next));
      } catch (err) {
        // It could not start: the switch goes back off and says why.
        switchEl.classList.remove("on");
        switchEl.setAttribute("aria-pressed", "false");
        lastRunning = false;
        connectionExtras.replaceChildren();
        detail.replaceChildren();
        updateHeroAndMeta(null);
        showError(String(err));
      }
    })();
  });

  const phoneLinkRow = h(
    "div",
    { class: "phone-row" },
    h(
      "div",
      { class: "phone-row-label" },
      h("span", { class: "phone-row-title", text: t("Phone link") }),
      h("span", { class: "phone-row-desc", text: t("Listens only on your local network. Off by default.") }),
    ),
    switchEl,
  );

  connectionGroup.append(phoneLinkRow, noteWrap, connectionExtras);

  void Bridge.phoneLinkStatus().then(draw);

  const page = h(
    "div",
    { class: "phone-settings-page", "data-anchor": "phone.android" },
    heroCard,
    h(
      "div",
      { class: "phone-section" },
      h("div", { class: "phone-section-header" }, h("span", { class: "phone-section-title", text: t("Connection & pairing") })),
      connectionGroup,
    ),
    detail,
  );
  return page;
}

/** What the status line says about the relay. */
export function relayStateText(state: PhoneRelayState): string {
  switch (state) {
    case "connecting": return t("Reaching the relay…");
    case "waiting": return t("Connected to the relay, waiting for the phone.");
    case "linked": return t("The phone is connected through the relay.");
    case "accessRefused": return t("The relay refused the access key.");
    case "unreachable": return t("The relay cannot be reached. Trying again.");
    case "roomTaken": return t("This pairing is in use somewhere else. Press Pair again.");
    case "tooMany": return t("The relay is limiting connections from here. Trying again later.");
    default: return t("Off");
  }
}

/**
 * "Away from home Wi-Fi": reach the phone through a relay the user deployed on their own account. Off until the user
 * enters the address and the access key and turns it on. The access key is write-only: it goes to the system keystore
 * and the window never gets it back. Rust re-reads the switch for every connection.
 */
function relayBlock(makeToggle: Toggle, changed: () => void): HTMLElement {
  const noteWrap = h("div", { class: "phone-inline-notice" });
  const stateEl = h("span", { class: "phone-section-meta" });
  const address = h("input", {
    type: "text",
    class: "phone-input",
    placeholder: "wss://",
    autocomplete: "off",
    spellcheck: "false",
  }) as HTMLInputElement;
  const access = h("input", {
    type: "password",
    class: "phone-input",
    autocomplete: "off",
    spellcheck: "false",
  }) as HTMLInputElement;
  let current: PhoneRelayStatus = { enabled: false, url: "", hasAccess: false, state: "off", shown: true };

  const show = (status: PhoneRelayStatus | null) => {
    if (!status) return;
    current = status;
    switchEl.classList.toggle("on", status.enabled);
    switchEl.setAttribute("aria-pressed", String(status.enabled));
    if (document.activeElement !== address) address.value = status.url;
    access.placeholder = status.hasAccess ? "••••••••" : "";
    stateEl.textContent = status.enabled ? relayStateText(status.state) : "";
  };
  const fail = (err: unknown) => {
    noteWrap.replaceChildren(h("div", { class: "notice err", text: String(err) }));
    switchEl.classList.remove("on");
    switchEl.setAttribute("aria-pressed", "false");
  };
  const apply = async (enabled: boolean) => {
    noteWrap.replaceChildren();
    try {
      show(await Bridge.phoneRelaySet(enabled, address.value));
      changed();
    } catch (err) {
      fail(err);
    }
  };
  const switchEl = makeToggle(false, (next) => void apply(next));
  const saveAddress = h("button", { class: "phone-btn", type: "button", text: t("Save address") });
  saveAddress.addEventListener("click", () => void apply(current.enabled));
  const saveKey = h("button", { class: "phone-btn", type: "button", text: t("Save key") });
  saveKey.addEventListener("click", () => {
    void (async () => {
      noteWrap.replaceChildren();
      try {
        const next = await Bridge.phoneRelaySetAccess(access.value);
        access.value = ""; // never kept on the page
        show(next);
        changed();
      } catch (err) {
        noteWrap.replaceChildren(h("div", { class: "notice err", text: String(err) }));
      }
    })();
  });

  void Bridge.phoneRelayStatus().then(show);
  // Kept up to date while the window is open; nothing runs while it is hidden.
  const watch = window.setInterval(() => {
    if (!stateEl.isConnected) return window.clearInterval(watch);
    if (document.visibilityState !== "visible") return;
    void Bridge.phoneRelayStatus().then(show);
  }, 5000);

  const group = h(
    "div",
    { class: "phone-group" },
    h(
      "div",
      { class: "phone-row" },
      h(
        "div",
        { class: "phone-row-label" },
        h("span", { class: "phone-row-title", text: t("Away from home Wi-Fi") }),
        h("span", { class: "phone-row-desc", text: t("Reach this computer from your phone on mobile data or another network, through a relay you deployed yourself. Everything is encrypted end to end: the relay only forwards data it cannot read. Off by default.") }),
      ),
      switchEl,
    ),
    h(
      "div",
      { class: "phone-row" },
      h("div", { class: "phone-row-label", style: "flex: 0 0 130px" }, h("span", { class: "phone-row-title", text: t("Relay address") })),
      h("div", { class: "phone-link-row", style: "flex: 1 1 auto" }, address, saveAddress),
    ),
    h(
      "div",
      { class: "phone-row" },
      h(
        "div",
        { class: "phone-row-label", style: "flex: 0 0 130px" },
        h("span", { class: "phone-row-title", text: t("Relay access key") }),
      ),
      h("div", { class: "phone-link-row", style: "flex: 1 1 auto" }, access, saveKey),
    ),
    h("div", { class: "phone-group-intro", style: "border-bottom: none", text: t("Paste the access key you set when you deployed the relay. It is kept in the system keystore and never shown again.") }),
    noteWrap,
  );

  return h(
    "div",
    { class: "phone-section" },
    h(
      "div",
      { class: "phone-section-header" },
      h("span", { class: "phone-section-title", text: t("Away from home Wi-Fi") }),
      stateEl,
    ),
    group,
  );
}

/**
 * Session details for the phone (the steps, the last line, the folder name, the colour): off until the
 * user turns it on. The phone is told only if it asks; Rust re-reads this switch for every connection.
 */
function detailsBlock(makeToggle: Toggle): HTMLElement {
  return settingToggleRow(
    t("Show session details on the phone"),
    t("Shares recent steps, final line, and project folder name. Never full paths."),
    makeToggle,
    Bridge.phoneDetailsStatus,
    Bridge.phoneDetailsSetEnabled,
  );
}

/**
 * Answering the questions Claude Code asks, from the phone: off until the user turns it on. The phone shows the question
 * and its options; its screen lock confirms every answer. Rust re-reads this switch for every connection.
 */
function answersBlock(makeToggle: Toggle): HTMLElement {
  return settingToggleRow(
    t("Let the phone answer Claude Code's questions"),
    t("Shows question options on your phone. Every answer requires screen-lock confirmation."),
    makeToggle,
    Bridge.phoneAnswersStatus,
    Bridge.phoneAnswersSetEnabled,
  );
}

/** The service pills the phone may show, with the names the pills carry (brand names, not translated). */
const PHONE_SERVICES: [string, string][] = [
  ["integration_stripe", "Stripe"], ["integration_github", "GitHub"], ["integration_vercel", "Vercel"],
  ["integration_n8n", "n8n"], ["integration_resend", "Resend"], ["integration_notion", "Notion"], ["integration_calcom", "Cal.com"],
];

/**
 * Service cards on the phone, read-only, one tick per service and none ticked until the user does it: what each card
 * says is a headline and three short lines, never an address, a link or a secret. Rust re-reads the ticks for every
 * connection and sends a phone only the services ticked here.
 */
function servicesBlock(): HTMLElement {
  const noteWrap = h("div", { class: "phone-inline-notice" });
  let ticked: string[] = [];

  const boxes = PHONE_SERVICES.map(([id, name]) => {
    const { box, indicator } = macCheckBox(false, () => {
      void (async () => {
        noteWrap.replaceChildren();
        const next = box.checked ? [...new Set([...ticked, id])] : ticked.filter((x) => x !== id);
        try {
          ticked = (await Bridge.phoneServicesSet(next)).services;
        } catch (err) {
          box.checked = ticked.includes(id);
          noteWrap.replaceChildren(h("div", { class: "notice err", text: String(err) }));
        }
      })();
    });

    const color = pillDefinition(id)?.color ?? "#8e939c";
    const tile = h(
      "label",
      { class: "phone-service-tile" },
      box,
      indicator,
      dot(color, 7),
      h("span", { class: "phone-service-name", text: name }),
    );
    return { id, box, tile };
  });

  void Bridge.phoneServicesStatus().then((status) => {
    if (!status) return;
    ticked = status.services;
    for (const b of boxes) b.box.checked = ticked.includes(b.id);
  });

  const group = h(
    "div",
    { class: "phone-group" },
    h("div", { class: "phone-group-intro", text: t("Lets your paired phone view read-only summary cards. No addresses, links, or keys are sent.") }),
    h("div", { class: "phone-services-grid" }, ...boxes.map((b) => b.tile)),
    noteWrap,
  );

  return h(
    "div",
    { class: "phone-section" },
    h(
      "div",
      { class: "phone-section-header" },
      h("span", { class: "phone-section-title", text: t("Service visibility") }),
      h("span", { class: "phone-section-meta", text: t("Show these services on the phone") }),
    ),
    group,
  );
}

/**
 * The plan usage on the phone: off until the user turns it on. Only the percentages and reset times the pills show,
 * for the Claude and Codex plans. Rust re-reads this switch for every connection.
 */
function usageBlock(makeToggle: Toggle): HTMLElement {
  return settingToggleRow(
    t("Show my plan usage on the phone"),
    t("Shares Claude and Codex plan usage percentages and reset times."),
    makeToggle,
    Bridge.phoneUsageStatus,
    Bridge.phoneUsageSetEnabled,
  );
}

/**
 * Last week's recap on the phone: off until the user turns it on. Only counts (minutes, sessions, files, lines, commands, permissions) and the
 * name of the busiest agent; the project's folder name only reaches a phone that also shows session details. Rust re-reads this switch for every
 * connection.
 */
function recapBlock(makeToggle: Toggle): HTMLElement {
  return settingToggleRow(
    t("Show my weekly recap on the phone"),
    t("Shares last week's counts and busiest agent. Project name requires session details."),
    makeToggle,
    Bridge.phoneRecapStatus,
    Bridge.phoneRecapSetEnabled,
  );
}

/**
 * The files an agent changed, on the phone: off until the user turns it on. The list (names and counts) rides on the
 * session; the lines of a file are sent only when the phone asks for that file. Rust re-reads this for every connection.
 */
function diffsBlock(makeToggle: Toggle): HTMLElement {
  return settingToggleRow(
    t("Show the files an agent changed on the phone"),
    t("Lists modified files and streams requested diffs (up to 200 lines) over the encrypted link."),
    makeToggle,
    Bridge.phoneDiffsStatus,
    Bridge.phoneDiffsSetEnabled,
  );
}

/**
 * Chat from the phone: off until the user turns it on, and then only the models ticked here.
 * The phone gets text; the keys stay on this computer (src-tauri/src/phone_link/chat.rs).
 */
function chatBlock(makeToggle: Toggle, settings: Settings): HTMLElement {
  let allowed: string[] = [];
  const body = h("div", { class: "phone-chat-body" });
  const noteWrap = h("div", { class: "phone-inline-notice" });
  const summaryUpdaters: (() => void)[] = [];

  const emptyNote = h("span", {
    class: "phone-chat-empty-tag",
    text: t("No models selected yet: tick at least one model to enable phone chat."),
  });

  const refreshSummaries = () => {
    emptyNote.hidden = allowed.length > 0;
    for (const fn of summaryUpdaters) fn();
  };

  const save = async (next: string[]) => {
    noteWrap.replaceChildren();
    try {
      allowed = (await Bridge.phoneChatSetModels(next)).models;
    } catch (err) {
      noteWrap.replaceChildren(h("div", { class: "notice err", text: String(err) }));
    }
    refreshSummaries();
  };

  /** One provider: a button that asks it for its models (only now), then a tick box per model. */
  const providerRow = (p: ProviderDef): HTMLElement => {
    const list = h("div", { class: "phone-models-drawer" });
    const button = h("button", { class: "phone-btn", type: "button", text: t("Choose models") }) as HTMLButtonElement;
    const summaryEl = h("span", { class: "phone-provider-models-summary" });
    let expanded = false;

    const updateSummary = () => {
      const picked = modelsOf(allowed, p.id);
      if (picked.length === 0) {
        summaryEl.textContent = t("No models selected");
        summaryEl.title = "";
      } else {
        summaryEl.textContent = `${t("{count} allowed", { count: picked.length })} · ${picked.join(", ")}`;
        summaryEl.title = picked.join(", ");
      }
    };
    summaryUpdaters.push(updateSummary);
    updateSummary();

    const show = (models: string[]) => {
      const allModels = [...new Set([...models, ...modelsOf(allowed, p.id)])];
      list.replaceChildren(
        ...allModels.map((model) => {
          const id = modelId(p.id, model);
          const { box, indicator } = macCheckBox(allowed.includes(id), (checked) => {
            void save(toggleModel(allowed, id, checked));
          });
          return h(
            "label",
            { class: "phone-model-option" },
            box,
            indicator,
            h("span", { class: "phone-model-name", text: model }),
          );
        }),
      );
      revealSmoothly(list);
    };

    button.addEventListener("click", () => {
      if (expanded) {
        expanded = false;
        list.replaceChildren();
        button.textContent = t("Choose models");
        return;
      }
      expanded = true;
      button.textContent = t("Done");
      list.replaceChildren(h("div", { class: "hint", text: t("Loading models…") }));
      Bridge.chatModels(p.id).then(
        (models) => {
          if (expanded) show(models.map((m) => m.id));
        },
        (err) => {
          if (expanded) {
            list.replaceChildren(h("div", { class: "notice err", text: String(err).replace(/^Error:\s*/, "") }));
          }
        },
      );
    });

    const head = h(
      "div",
      { class: "phone-provider-row" },
      h(
        "div",
        { class: "phone-provider-info" },
        h(
          "div",
          { class: "phone-provider-head" },
          dot(p.accent, 7),
          h("span", { class: "phone-provider-name", text: p.name }),
        ),
        summaryEl,
      ),
      button,
    );

    return h("div", { class: "phone-provider-wrap" }, head, list);
  };

  const draw = async (status: PhoneChatStatus) => {
    allowed = status.models;
    summaryUpdaters.length = 0;
    body.replaceChildren();
    if (!status.enabled) return;

    const hasKey: Record<string, boolean> = {};
    for (const p of usableProvidersCandidates()) hasKey[p.id] = (await Bridge.keyReady(p.key!)) ?? false;
    const providers = usableProviders(settings, hasKey);

    body.append(
      h(
        "div",
        { class: "phone-chat-subheader" },
        h("span", { class: "phone-chat-sublabel", text: t("Models the phone may use") }),
        emptyNote,
      ),
    );

    if (providers.length === 0) {
      body.append(
        h("div", { class: "phone-group-intro", style: "border-bottom: none", text: t("No provider is ready: add an API key or connect a local model first.") }),
      );
    } else {
      const list = h("div", { class: "phone-provider-list" }, ...providers.map(providerRow));
      body.append(list);
    }

    refreshSummaries();
    revealSmoothly(body);
  };

  const switchEl = makeToggle(false, (next) => {
    void (async () => {
      noteWrap.replaceChildren();
      try {
        await draw(await Bridge.phoneChatSetEnabled(next));
      } catch (err) {
        switchEl.classList.remove("on");
        switchEl.setAttribute("aria-pressed", "false");
        body.replaceChildren();
        noteWrap.replaceChildren(h("div", { class: "notice err", text: String(err) }));
      }
    })();
  });

  // The switch shows what Rust says, not what the page remembers.
  void Bridge.phoneChatStatus().then((status) => {
    if (!status) return;
    switchEl.classList.toggle("on", status.enabled);
    switchEl.setAttribute("aria-pressed", String(status.enabled));
    void draw(status);
  });

  const group = h(
    "div",
    { class: "phone-group" },
    h(
      "div",
      { class: "phone-row" },
      h(
        "div",
        { class: "phone-row-label" },
        h("span", { class: "phone-row-title", text: t("Let the phone chat with my AI providers") }),
        h("span", { class: "phone-row-desc", text: t("Uses API keys saved on this computer. Keys never leave your PC; messages may incur costs.") }),
      ),
      switchEl,
    ),
    noteWrap,
    body,
  );

  return h(
    "div",
    { class: "phone-section" },
    h("div", { class: "phone-section-header" }, h("span", { class: "phone-section-title", text: t("AI chat") })),
    group,
  );
}

function usableProvidersCandidates(): ProviderDef[] {
  return PROVIDERS.filter((p) => p.key !== null);
}

/**
 * Said after the link is copied: the link is the pairing code itself, so whoever reads it (the clipboard, a chat, a
 * screenshot) can pair a phone until a new code is made. Hidden until the link has been copied.
 */
export function copyLinkHint(): HTMLElement {
  const hint = h("div", {
    class: "phone-copy-warning",
    text: t("The link you copied contains the pairing code: anyone who gets it can pair a phone with this computer. If it ends up somewhere it should not, press Pair again to make a new code; the old one stops working."),
  });
  hint.hidden = true;
  return hint;
}

function pairingRows(pairing: PhoneLinkPairing, again: () => void): HTMLElement[] {
  // The QR comes from Rust (qrcode crate) as an SVG made only of paths.
  const qr = h("div", { class: "qr" });
  if (typeof DOMParser !== "undefined") {
    const parsed = new DOMParser().parseFromString(pairing.qrSvg, "image/svg+xml").documentElement;
    if (parsed && parsed.tagName.toLowerCase() === "svg") {
      qr.append(document.importNode(parsed, true));
    }
  } else if (pairing.qrSvg) {
    qr.setAttribute("data-qr", "ready");
  }

  const link = h("input", {
    type: "text",
    class: "phone-link-input",
    readonly: "true",
    value: pairing.link,
  }) as HTMLInputElement;
  link.addEventListener("focus", () => link.select());

  const copy = h("button", { class: "phone-btn", type: "button", text: t("Copy link") });
  const copied = copyLinkHint();
  copy.addEventListener("click", () => {
    void navigator.clipboard?.writeText(pairing.link).then(() => {
      copied.hidden = false; // stays after the button text is restored
      copy.textContent = t("Copied");
      window.setTimeout(() => (copy.textContent = t("Copy link")), 1500);
    });
  });

  const repair = h("button", { class: "phone-btn subtle", type: "button", text: t("Pair again") });
  repair.addEventListener("click", again);

  const details = h(
    "div",
    { class: "phone-qr-details" },
    h("div", { class: "phone-qr-instruction", text: t("In Coucou for Android, scan this code with the camera or paste the link.") }),
    h("div", { class: "phone-link-row" }, link, copy),
    copied,
    ...(pairing.relay ? [h("div", { class: "hint", text: t("This code also carries the access key and the end-to-end key for the relay {host}. Pair again makes a new key and a new room.", { host: pairing.relay }) })] : []),
    h("div", { class: "phone-repair-row" }, repair, h("span", { class: "phone-repair-note", text: t("The phone that was paired is disconnected and needs the new code.") })),
  );

  return [
    h(
      "div",
      { class: "phone-qr-layout" },
      h("div", { class: "phone-qr-frame" }, qr),
      details,
    ),
  ];
}

/**
 * Coudrop settings summary and direct navigation link in Android phone section.
 */
function coudropBlock(): HTMLElement {
  const openBtn = h("button", {
    class: "phone-btn",
    type: "button",
    text: t("Open Coudrop settings"),
    onclick: () => {
      window.location.hash = "#coudrop";
    },
  });

  const folderBtn = h("button", {
    class: "phone-btn",
    type: "button",
    text: tl("Downloads"),
    onclick: () => void Bridge.coudropOpenFolder(),
  });

  const group = h(
    "div",
    { class: "phone-group" },
    h(
      "div",
      { class: "phone-row" },
      h(
        "div",
        { class: "phone-row-label" },
        h(
          "div",
          { class: "phone-row-title-line" },
          h("span", { class: "phone-row-title", text: "Coudrop" }),
          h("span", { class: "phone-inline-badge", text: t("Peer-to-peer file transfer") }),
        ),
        h("span", {
          class: "phone-row-desc",
          text: t("Zero-cloud file transfer between PC and phone over your private TLS link."),
        }),
      ),
      h("div", { class: "phone-row-actions" }, folderBtn, openBtn),
    ),
  );

  return h(
    "div",
    { class: "phone-section" },
    h("div", { class: "phone-section-header" }, h("span", { class: "phone-section-title", text: t("File transfer") })),
    group,
  );
}
