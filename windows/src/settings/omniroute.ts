// Settings → Chat → OmniRoute: turn it on, see where it stands and fix what is
// missing, one step at a time — install it (from its official source, by the
// user), start it (Coucou does), give it a key, pick a model. The router itself
// lives in omniroute.rs; this card only asks it and shows the answer.

import { Bridge } from "../core/bridge";
import {
  DEFAULT_URL, INSTALL_COMMAND, OmniRouteBridge, REPO_URL, SITE_URL, chatAfterOff, featuresModel, omnirouteConfig, stage,
  type OmniRouteConfig, type OmniRouteStatus,
} from "../core/omniroute";
import type { Settings } from "../core/state";
import { h, clear } from "../views/dom";
import { t } from "../i18n/i18n";
import { statusDot } from "./parts";

/** What the page lends the card. `settings()` is the page's current object, edited in place. */
export interface OmniRouteHost {
  settings(): Settings;
  save(): Promise<void>;
  toggle(on: boolean, onChange: (v: boolean) => void): HTMLElement;
  /** Where secrets.rs keeps the keys on this OS, as the Claude key's row names it. */
  keyStore: string;
}

const S = {
  get intro() { return t("OmniRoute is a router you run on your computer, in front of every AI provider and account you connect to it. Coucou can chat with its models and combos, and send its own AI features through it."); },
  get use() { return t("Use OmniRoute"); },
  get checking() { return t("Connecting…"); },
  get notInstalled() { return t("OmniRoute isn't installed on this computer."); },
  get installHow() { return t("Install it once from its official source, with Node.js 22 or later, then come back: Coucou starts it for you."); },
  get copy() { return t("Copy"); },
  get copied() { return t("Copied"); },
  get stopped() { return t("Installed, not running."); },
  get start() { return t("Start OmniRoute"); },
  get starting() { return t("Starting OmniRoute…"); },
  get keyNeeded() { return t("It asks for an API key: create one in its dashboard, under API Manager, then paste it here."); },
  get keyRefused() { return t("It refused this key: create a new one in its dashboard, then paste it here."); },
  get empty() { return t("Running, but no models yet: connect a provider in its dashboard."); },
  ready: (count: number) => t("Connected · {count} models", { count }),
  unreachable: (url: string) => t("Cannot reach {url}. Is the server running?", { url }),
  get dashboard() { return t("Open dashboard"); },
  get address() { return t("Address"); },
  get apiKey() { return t("API key"); },
  get stored() { return t("(stored)"); },
  get keyOptional() { return t("API key (optional)"); },
  get save() { return t("Save"); },
  get remove() { return t("Remove"); },
  keySaved: (store: string) => t("Key saved in the {store}.", { store }),
  get savedNotice() { return t("Saved. It never touches disk."); },
  get removedNotice() { return t("Key removed."); },
  couldNotSave: (error: string) => t("Could not save: {error}", { error }),
  couldNotRemove: (error: string) => t("Could not remove: {error}", { error }),
  get useInChat() { return t("Use in chat"); },
  get inUse() { return t("In use"); },
  get features() { return t("Coucou's AI features"); },
  get featuresHint() { return t("Dictation clean-up, Notetaker summaries and « OK Coucou » go through OmniRoute with this model, instead of your Anthropic key. What you dictate and record then goes to the providers behind it."); },
  get model() { return t("Model"); },
};

/** Its last answer, kept while Settings is open: the card shows it at once on
 *  a new visit, then asks again. Keyed by the address it was asked for. */
let last: { url: string; status: OmniRouteStatus } | null = null;

function errorText(err: unknown): string {
  return String(err).replace(/^Error:\s*/, "");
}

export function omnirouteSection(host: OmniRouteHost): HTMLElement {
  const config = (): OmniRouteConfig => omnirouteConfig(host.settings());
  let status: OmniRouteStatus | null = last?.url === config().url ? last.status : null;
  let hasKey = false;
  /** Starting it: the one line the state row shows. */
  let busy: string | null = null;
  /** OmniRoute is being asked; the last answer, if any, stays on screen meanwhile. */
  let checking = false;
  /** Bumped by every refresh, so an older answer never overwrites a newer one. */
  let asked = 0;

  const update = async (change: Partial<OmniRouteConfig>) => {
    host.settings().omniroute = { ...config(), ...change };
    await host.save();
  };

  // The parts that redraw are slots; the inputs are built once, so a refresh
  // landing while the user types never takes their text or focus away.
  const stateRow = h("div", { class: "row" });
  const installSlot = h("div", { style: "display:flex;flex-direction:column;gap:8px" });
  const featuresSlot = h("div", { style: "display:flex;flex-direction:column;gap:6px" });
  let featuresDrawn = "";

  // The key row: what is saved, said in words, as the Claude key's row does.
  const keyInput = h("input", {
    type: "password",
    style: "flex:1 1 auto;min-width:0",
    autocomplete: "off",
    spellcheck: "false",
  }) as HTMLInputElement;
  const keyState = h("span", { class: "hint" });
  const keyLine = h("div", { class: "row" }, statusDot(true), keyState);
  const removeKey = h("button", { class: "danger", text: S.remove });
  const keyFeedback = h("div", {});

  const details = h("div", { style: "display:flex;flex-direction:column;gap:12px" },
    stateRow, installSlot, addressRow(), keyBlock(), featuresSlot);

  /** Asks omniroute.rs again, then settles what follows from the answer. */
  async function refresh() {
    const ticket = ++asked;
    checking = true;
    draw();
    void OmniRouteBridge.keySaved().catch(() => false).then((saved) => {
      if (ticket !== asked) return;
      hasKey = saved;
      drawKey();
    });
    try {
      const fresh = await OmniRouteBridge.status().catch((err) => failed(err));
      if (ticket !== asked) return;
      show(fresh);
      await settle().catch(() => {});
    } finally {
      if (ticket === asked) {
        checking = false;
        draw();
      }
    }
  }

  function show(fresh: OmniRouteStatus) {
    status = fresh;
    last = { url: config().url, status: fresh };
  }

  function failed(err: unknown): OmniRouteStatus {
    return {
      url: config().url || DEFAULT_URL, local: true, installed: false, running: false,
      key: "none", models: [], error: errorText(err),
    };
  }

  /** Once its models are known: the features' model and the chat's are ones it has. */
  async function settle() {
    const offered = status?.models ?? [];
    if (!offered.length) return;
    const settings = host.settings();
    const chosen = featuresModel(config().featuresModel, offered);
    const chatModel = settings.chatModels.omniroute ?? "";
    if (chosen === config().featuresModel && offered.includes(chatModel)) return;
    settings.chatModels = { ...settings.chatModels, omniroute: offered.includes(chatModel) ? chatModel : chosen };
    await update({ featuresModel: chosen });
  }

  async function start() {
    asked++;
    checking = false;
    busy = S.starting;
    draw();
    try {
      show(await OmniRouteBridge.start());
    } catch (err) {
      show(failed(err));
    }
    busy = null;
    await settle().catch(() => {});
    draw();
  }

  /** The chat goes to it, and remembers where it went before. */
  async function takeChat() {
    const settings = host.settings();
    if (settings.chatProvider === "omniroute") return;
    const before = settings.chatProvider;
    settings.chatProvider = "omniroute";
    await update({ chatBefore: before });
  }

  async function turn(next: boolean) {
    if (!next) {
      // The chat goes back to where it was before OmniRoute took it.
      const settings = host.settings();
      settings.chatProvider = chatAfterOff(settings.chatProvider, config());
      asked++;
      checking = false;
      busy = null;
      await update({ enabled: false, chatBefore: undefined });
      return draw();
    }
    await update({ enabled: true });
    await refresh();
    // Turned on: started if it can be, and the chat goes to it once it answers.
    if (stage(config(), status) === "stopped") await start();
    if (stage(config(), status) === "ready") await takeChat();
    draw();
  }

  function draw() {
    const on = config().enabled;
    details.style.display = on ? "flex" : "none";
    if (!on) return;
    drawState();
    clear(installSlot);
    const guide = !!status && !status.running && status.local && !status.installed && !busy && !checking;
    installSlot.style.display = guide ? "flex" : "none";
    if (guide) installSlot.append(...installGuide());
    drawKey();
    drawFeatures();
  }

  /** Where it stands, in one line, with the one action that moves it forward. */
  function drawState() {
    const row = stateRow;
    clear(row);
    if (busy || (checking && !status)) {
      row.append(h("div", { class: "hint", text: busy ?? S.checking }));
      return;
    }
    const now = stage(config(), status);
    const line = (ok: boolean, text: string) => row.append(statusDot(ok), h("span", { text, style: "flex:1 1 auto;min-width:0" }));
    switch (now) {
      case "not-installed":
        line(false, S.notInstalled);
        break;
      case "stopped": {
        line(false, S.stopped);
        const go = h("button", { class: "primary", text: S.start });
        go.addEventListener("click", () => void start());
        row.append(go);
        break;
      }
      case "key":
      case "refused":
        line(false, now === "key" ? S.keyNeeded : S.keyRefused);
        row.append(dashboardButton());
        break;
      case "empty":
        line(false, S.empty);
        row.append(dashboardButton());
        break;
      case "ready": {
        line(true, S.ready(status!.models.length));
        const inUse = host.settings().chatProvider === "omniroute";
        const use = h("button", { class: inUse ? "" : "primary", text: inUse ? S.inUse : S.useInChat });
        use.disabled = inUse;
        use.addEventListener("click", async () => {
          await takeChat();
          draw();
        });
        row.append(dashboardButton(), use);
        break;
      }
      default:
        line(false, status?.error || S.unreachable(status?.url || DEFAULT_URL));
    }
    // An earlier answer stays up while it is asked again.
    if (checking) row.append(h("span", { class: "hint", text: S.checking }));
  }

  function dashboardButton(): HTMLElement {
    const b = h("button", { text: S.dashboard });
    b.addEventListener("click", () => void OmniRouteBridge.dashboard().catch(() => {}));
    return b;
  }

  /** Not installed: where it comes from, and the one command that installs it. */
  function installGuide(): HTMLElement[] {
    const copy = h("button", { text: S.copy });
    copy.addEventListener("click", async () => {
      await navigator.clipboard.writeText(INSTALL_COMMAND).catch(() => {});
      copy.textContent = S.copied;
    });
    const site = h("button", { text: "omniroute.online" });
    site.addEventListener("click", () => void Bridge.openUrl(SITE_URL));
    const repo = h("button", { text: "GitHub" });
    repo.addEventListener("click", () => void Bridge.openUrl(REPO_URL));
    const again = h("button", { text: S.start });
    again.addEventListener("click", () => void refresh().then(() => stage(config(), status) === "stopped" ? start() : undefined));
    return [
      h("div", { class: "hint", text: S.installHow }),
      h("div", { class: "row" },
        h("code", { class: "path", text: INSTALL_COMMAND, style: "flex:1 1 auto;user-select:text" }),
        copy, site, repo, again,
      ),
    ];
  }

  function addressRow(): HTMLElement {
    const input = h("input", {
      type: "text",
      placeholder: DEFAULT_URL,
      value: config().url,
      style: "flex:1 1 auto;min-width:0",
      spellcheck: "false",
      autocomplete: "off",
    }) as HTMLInputElement;
    input.addEventListener("change", async () => {
      // The key stays with the address it was entered for: a new one needs it again.
      await update({ url: input.value.trim() });
      status = null;
      await refresh();
    });
    return h("div", { class: "row" }, h("label", { text: S.address }), input);
  }

  function drawKey() {
    keyInput.placeholder = hasKey ? `••••••••••••  ${S.stored}` : S.keyOptional;
    keyState.textContent = S.keySaved(host.keyStore);
    keyLine.style.display = hasKey ? "flex" : "none";
    removeKey.style.display = hasKey ? "" : "none";
  }

  function notice(ok: boolean, text: string) {
    clear(keyFeedback);
    keyFeedback.append(h("div", { class: ok ? "notice ok" : "notice err", text }));
  }

  function keyBlock(): HTMLElement {
    const save = h("button", { class: "primary", text: S.save });
    const submit = async () => {
      const value = keyInput.value.trim();
      if (!value) return;
      save.disabled = true;
      try {
        await OmniRouteBridge.setKey(config().url, value);
        keyInput.value = "";
        hasKey = true;
        drawKey();
        notice(true, S.savedNotice);
        await refresh();
      } catch (err) {
        notice(false, S.couldNotSave(errorText(err)));
      } finally {
        save.disabled = false;
      }
    };
    save.addEventListener("click", () => void submit());
    keyInput.addEventListener("keydown", (e) => {
      if (e.key === "Enter") void submit();
    });
    removeKey.addEventListener("click", async () => {
      try {
        await OmniRouteBridge.setKey(config().url, "");
        hasKey = false;
        drawKey();
        notice(true, S.removedNotice);
        await refresh();
      } catch (err) {
        notice(false, S.couldNotRemove(errorText(err)));
      }
    });
    drawKey();
    return h("div", { style: "display:flex;flex-direction:column;gap:6px" },
      h("div", { class: "row" }, h("label", { text: S.apiKey }), keyInput, save, removeKey),
      keyLine,
      keyFeedback,
    );
  }

  /** Dictation, the Notetaker and « OK Coucou » through it, with their model.
   *  Shown whether or not its list has arrived: the saved model meanwhile. */
  function drawFeatures() {
    const { features, featuresModel: saved } = config();
    const models = status?.models ?? [];
    const offered = saved && !models.includes(saved) ? [saved, ...models] : models;
    const drawn = JSON.stringify([features, saved, offered]);
    if (drawn === featuresDrawn) return;
    featuresDrawn = drawn;
    clear(featuresSlot);
    featuresSlot.append(
      h("div", { class: "row" },
        h("label", { text: S.features }),
        h("span", { style: "flex:1 1 auto" }),
        host.toggle(features, (next) => void update({ features: next }).then(draw)),
      ),
      h("div", { class: "hint", text: S.featuresHint }),
    );
    if (!features) return;
    const select = h("select", { style: "flex:1 1 auto;min-width:0" }) as HTMLSelectElement;
    for (const id of offered) select.append(h("option", { value: id, text: id }));
    select.value = saved;
    select.disabled = !offered.length;
    select.addEventListener("change", () => void update({ featuresModel: select.value }).then(draw));
    featuresSlot.append(h("div", { class: "row" }, h("label", { text: S.model }), select));
  }

  const body = h("div", { style: "display:flex;flex-direction:column;gap:12px" },
    h("div", { class: "row" },
      h("label", {}, h("i", { class: "dot", style: "background:#8B5CF6;margin-right:8px" }), h("span", { text: S.use })),
      h("span", { style: "flex:1 1 auto" }),
      host.toggle(config().enabled, (next) => void turn(next)),
    ),
    details,
  );
  draw();
  if (config().enabled) void refresh();
  return h("section", {},
    h("h2", {}, h("span", { text: "OmniRoute" })),
    h("div", { class: "hint", text: S.intro }),
    body,
  );
}
