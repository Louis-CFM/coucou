// Settings → Integrations → Portfolio — port of PortfolioSettingsSection
// (PortfolioSettingsView.swift). Exchange accounts with a read-only key and
// self-custody wallets by public address. The Mac's sheets are inline forms
// here. Keys go straight to Rust, which tests them and keeps them in the
// credential store; this page never reads them back.

import { Bridge, onEvent } from "../core/bridge";
import {
  EXCHANGES, Portfolio, WALLETS, shortAddress, type ExchangeKind, type PortfolioState, type WalletKind,
} from "../core/portfolio";
import { h } from "../views/dom";
import { N_, t } from "../i18n/i18n";

const INSTRUCTIONS: Record<ExchangeKind, string> = {
  binance: N_("In Binance → API Management, create a key with Read Info permission only. Do not enable Spot Trading or Withdrawals."),
  okx: N_("In OKX → API → Create V5 API Key. Set permission to Read only. Note your passphrase — it is shown only once."),
  bybit: N_("In Bybit → API Management, create a key with Read Only permissions. Uncheck all other scopes."),
  kraken: N_("In Kraken → Security → API, create a key with Query Funds permission only. Paste the Private Key (base64) as the secret."),
  coinbase: N_("On coinbase.com → Settings → API (CDP) → Create API key, signature ECDSA, permission View only. Paste the key name (organizations/…/apiKeys/…) and the whole private key (BEGIN EC PRIVATE KEY…)."),
};

let listening = false;
let current: (() => void) | null = null;

function label(text: string): HTMLElement {
  return h("span", { style: "font-size:12px;min-width:90px;color:#8E939C", text });
}

export function portfolioSection(): HTMLElement {
  const box = h("div", { style: "display:flex;flex-direction:column;gap:6px" });
  let form: "exchange" | "wallet" | null = null;
  let busy = false;
  let error: string | null = null;
  let confirming: string | null = null;
  // The open form's fields survive a redraw (a snapshot arriving mid-typing).
  const ex = { kind: "binance" as ExchangeKind, key: "", secret: "", passphrase: "" };
  const wa = { kind: "bitcoin" as WalletKind, address: "", label: "" };

  function removeRow(name: string, kind: string, id: string, remove: () => void): HTMLElement {
    const row = h("div", { class: "row", style: "gap:6px" },
      h("span", { style: "color:#22c55e", text: "✔" }),
      h("span", { style: "font-size:12px", text: name }),
      h("span", { style: "font-size:11px;color:#8E939C", text: kind }),
      h("span", { style: "flex:1" }),
    );
    if (confirming === id) {
      row.append(
        h("span", { style: "font-size:11px", text: t("Remove {0}?", { 0: name }) }),
        h("button", { class: "danger", text: t("Remove"), onclick: () => { confirming = null; remove(); } }),
        h("button", { text: t("Cancel"), onclick: () => { confirming = null; draw(); } }),
      );
    } else {
      row.append(h("button", { text: t("Remove"), onclick: () => { confirming = id; draw(); } }));
    }
    return row;
  }

  function exchangeForm(): HTMLElement {
    const def = EXCHANGES.find((e) => e.id === ex.kind)!;
    const select = h("select", {}) as HTMLSelectElement;
    for (const e of EXCHANGES) select.append(h("option", { value: e.id, text: e.name }));
    select.value = ex.kind;
    select.addEventListener("change", () => {
      ex.kind = select.value as ExchangeKind;
      ex.key = ex.secret = ex.passphrase = "";
      error = null;
      draw();
    });
    const field = (value: string, secret: boolean, set: (v: string) => void, multiline = false) => {
      const input = (multiline
        ? h("textarea", { rows: "3", style: "flex:1;min-width:0;font-family:var(--mono, monospace);font-size:11px", spellcheck: "false" })
        : h("input", { type: secret ? "password" : "text", style: "flex:1;min-width:0;font-family:var(--mono, monospace)", autocomplete: "off", spellcheck: "false" })) as HTMLInputElement;
      input.value = value;
      input.dataset.keep = "1";
      input.addEventListener("input", () => {
        set(input.value);
        save.disabled = !ready();
      });
      return input;
    };
    const ready = () => !busy && ex.key.trim() !== "" && ex.secret.trim() !== "" && (!def.passphrase || ex.passphrase.trim() !== "");
    const save = h("button", { class: "primary", text: busy ? t("Testing…") : t("Test & Save") }) as HTMLButtonElement;
    save.disabled = !ready();
    save.addEventListener("click", async () => {
      busy = true;
      error = null;
      draw();
      error = (await Bridge.portfolioAddExchange(ex.kind, ex.key, ex.secret, ex.passphrase)) ?? null;
      busy = false;
      if (!error) {
        form = null;
        ex.key = ex.secret = ex.passphrase = "";
      }
      draw();
    });
    const keyLabel = ex.kind === "coinbase" ? t("Key name") : t("API Key");
    const secretLabel = ex.kind === "coinbase" ? t("Private key") : t("API Secret");
    return h("div", { style: "display:flex;flex-direction:column;gap:6px;padding:8px;border-radius:8px;background:rgba(255,255,255,0.03)" },
      h("b", { style: "font-size:12px", text: t("Add exchange") }),
      h("div", { class: "row", style: "gap:8px" }, label(t("Exchange")), select),
      h("div", { class: "hint", style: "font-size:11px", text: t(INSTRUCTIONS[ex.kind]) }),
      h("div", { class: "row", style: "gap:8px" }, label(keyLabel), field(ex.key, false, (v) => (ex.key = v))),
      h("div", { class: "row", style: "gap:8px;align-items:flex-start" }, label(secretLabel),
        field(ex.secret, true, (v) => (ex.secret = v), ex.kind === "coinbase")),
      def.passphrase ? h("div", { class: "row", style: "gap:8px" }, label(t("Passphrase")), field(ex.passphrase, true, (v) => (ex.passphrase = v))) : null,
      error ? h("div", { style: "font-size:11px;color:#F4505E", text: error }) : null,
      h("div", { class: "row", style: "gap:8px" },
        h("button", { text: t("Cancel"), onclick: () => { form = null; error = null; draw(); } }),
        h("span", { style: "flex:1" }),
        save,
      ),
    );
  }

  function walletForm(): HTMLElement {
    const def = WALLETS.find((w) => w.id === wa.kind)!;
    const select = h("select", {}) as HTMLSelectElement;
    for (const w of WALLETS) select.append(h("option", { value: w.id, text: w.name }));
    select.value = wa.kind;
    select.addEventListener("change", () => {
      wa.kind = select.value as WalletKind;
      wa.address = "";
      error = null;
      draw();
    });
    const address = h("input", { type: "text", placeholder: def.placeholder, style: "flex:1;min-width:0;font-family:var(--mono, monospace);font-size:11px", spellcheck: "false" }) as HTMLInputElement;
    address.value = wa.address;
    address.dataset.keep = "1";
    const name = h("input", { type: "text", placeholder: t("My wallet"), style: "flex:1;min-width:0" }) as HTMLInputElement;
    name.value = wa.label;
    name.dataset.keep = "1";
    const save = h("button", { class: "primary", text: busy ? t("Testing…") : t("Verify & Save") }) as HTMLButtonElement;
    const ready = () => !busy && wa.address.trim().length > 0;
    save.disabled = !ready();
    address.addEventListener("input", () => {
      wa.address = address.value;
      save.disabled = !ready();
    });
    name.addEventListener("input", () => (wa.label = name.value));
    save.addEventListener("click", async () => {
      busy = true;
      error = null;
      draw();
      error = (await Bridge.portfolioAddWallet(wa.kind, wa.address, wa.label)) ?? null;
      busy = false;
      if (!error) {
        form = null;
        wa.address = wa.label = "";
      }
      draw();
    });
    return h("div", { style: "display:flex;flex-direction:column;gap:6px;padding:8px;border-radius:8px;background:rgba(255,255,255,0.03)" },
      h("b", { style: "font-size:12px", text: t("Add wallet") }),
      h("div", { class: "row", style: "gap:8px" }, label(t("Network")), select),
      h("div", { class: "row", style: "gap:8px" }, label(t("Address")), address),
      h("div", { class: "row", style: "gap:8px" }, label(t("Label (optional)")), name),
      h("div", { class: "hint", style: "font-size:11px", text: t("Public address only. Coucou never touches your private keys.") }),
      error ? h("div", { style: "font-size:11px;color:#F4505E", text: error }) : null,
      h("div", { class: "row", style: "gap:8px" },
        h("button", { text: t("Cancel"), onclick: () => { form = null; error = null; draw(); } }),
        h("span", { style: "flex:1" }),
        save,
      ),
    );
  }

  function draw() {
    const focused = document.activeElement as HTMLElement | null;
    if (focused && box.contains(focused) && focused.dataset.keep) return;
    const s = Portfolio.state;
    box.replaceChildren();
    for (const id of s.exchanges) {
      const def = EXCHANGES.find((e) => e.id === id);
      if (!def) continue;
      box.append(removeRow(def.name, t("read-only"), `ex:${id}`, () => void Bridge.portfolioRemoveExchange(id)));
    }
    for (const w of s.wallets) {
      const name = w.label || shortAddress(w.address);
      const network = WALLETS.find((x) => x.id === w.kind)?.name ?? w.kind;
      box.append(removeRow(name, network, `w:${w.address}`, () => void Bridge.portfolioRemoveWallet(w.address)));
    }
    if (form === "exchange") box.append(exchangeForm());
    else if (form === "wallet") box.append(walletForm());
    else {
      box.append(h("div", { class: "row", style: "gap:8px" },
        h("button", { text: t("Add exchange"), onclick: () => { form = "exchange"; error = null; draw(); } }),
        h("button", { text: t("Add wallet"), onclick: () => { form = "wallet"; error = null; draw(); } }),
      ));
    }
    box.append(h("div", { class: "hint", text: t("Read-only access only. Keys stored in Windows Credential Manager, sent only to their exchange.") }));
  }

  current = draw;
  if (!listening) {
    listening = true;
    void onEvent<PortfolioState>("portfolio", (s) => {
      Portfolio.state = s;
      current?.();
    });
  }
  void Bridge.portfolioState().then((s) => {
    if (s) Portfolio.state = s;
    draw();
  });
  draw();
  return box;
}
