import { Bridge } from "../core/bridge";
import { EXCHANGE_NAMES, type PortfolioSettings } from "../core/portfolio";
import { h, clear } from "../views/dom";
import { t } from "../i18n/i18n";

export function portfolioSection(): HTMLElement {
  const body = h("div", { class: "hint", text: t("Loading…") });
  const section = h("section", {}, h("h2", { text: "Portfolio" }),
    h("p", { class: "hint", text: t("Read-only balances. Use keys with read permission only. Wallet addresses show native coins only.") }), body);
  void Bridge.portfolioSettings().then((settings) => {
    clear(body);
    if (!settings) { body.textContent = t("Error"); return; }
    render(settings);
  });

  function render(settings: PortfolioSettings) {
    clear(body);
    const exchange = h("select", { "aria-label": t("Exchange") }, ...Object.entries(EXCHANGE_NAMES).map(([value, name]) =>
      h("option", { value, text: `${name}${settings.exchanges[value] ? " ✓" : ""}` })));
    const key = h("input", { type: "password", autocomplete: "off", spellcheck: "false", "aria-label": t("API key"), placeholder: t("API key") });
    const secret = h("input", { type: "password", autocomplete: "new-password", spellcheck: "false", "aria-label": t("Secret key"), placeholder: t("Secret key") });
    const privateKey = h("textarea", { autocomplete: "off", spellcheck: "false", rows: 4, "aria-label": t("Private key"), placeholder: t("Private key") });
    const passphrase = h("input", { type: "password", autocomplete: "new-password", "aria-label": t("Passphrase"), placeholder: t("Passphrase") });
    const status = h("div", { class: "hint", role: "status" });
    const connection = h("div", { class: "row" });
    const connect = h("button", { text: t("Connect") });
    const disconnect = h("button", { text: t("Disconnect") });
    const run = async (operation: () => Promise<unknown>) => {
      for (const el of [exchange, key, secret, privateKey, passphrase, connect, disconnect]) el.disabled = true;
      status.textContent = t("Connecting…");
      try {
        await operation();
        key.value = secret.value = privateKey.value = passphrase.value = "";
        const next = await Bridge.portfolioSettings();
        if (next) render(next); else status.textContent = t("Error");
      } catch (error) { status.textContent = String(error); }
      finally { for (const el of [exchange, key, secret, privateKey, passphrase, connect, disconnect]) el.disabled = false; }
    };
    connect.addEventListener("click", () => void run(() => Bridge.portfolioConnect(exchange.value, { key: key.value.trim(), secret: (exchange.value === "coinbase" ? privateKey.value : secret.value).trim(), passphrase: passphrase.value.trim() })));
    disconnect.addEventListener("click", () => void run(() => Bridge.portfolioDisconnect(exchange.value)));
    const updateFields = () => {
      key.value = secret.value = privateKey.value = passphrase.value = "";
      key.placeholder = exchange.value === "coinbase" ? t("Key name") : t("API key");
      privateKey.hidden = exchange.value !== "coinbase";
      secret.hidden = exchange.value === "coinbase";
      key.setAttribute("aria-label", key.placeholder); secret.setAttribute("aria-label", secret.placeholder);
      passphrase.hidden = exchange.value !== "okx";
      disconnect.hidden = !settings.exchanges[exchange.value];
      status.textContent = settings.exchanges[exchange.value] ? t("Connected") : t("Not connected");
    };
    exchange.addEventListener("change", updateFields); updateFields();
    connection.append(connect, disconnect, status);
    body.append(h("div", { class: "row" }, exchange, key), h("div", { class: "row" }, secret, privateKey, passphrase), connection);

    const list = h("div", { style: "display:flex;flex-direction:column;gap:8px;margin-top:16px" });
    const walletStatus = h("div", { class: "hint", role: "status" });
    let saving = false;
    const walletRun = async (wallets: PortfolioSettings["wallets"]) => {
      if (saving) return; saving = true;
      try { await Bridge.portfolioSaveWallets(wallets); const next = await Bridge.portfolioSettings(); if (next) render(next); }
      catch (error) { walletStatus.textContent = String(error); }
      finally { saving = false; }
    };
    for (const wallet of settings.wallets) {
      list.append(h("div", { class: "row" }, h("span", { style: "flex:1;overflow-wrap:anywhere", text: `${settings.networks[wallet.kind]} · ${wallet.label || wallet.address}` }),
        h("button", { text: t("Remove"), onclick: () => void walletRun(settings.wallets.filter((w) => w.kind !== wallet.kind || w.address !== wallet.address)) })));
    }
    const network = h("select", { "aria-label": t("Network") }, ...Object.entries(settings.networks).map(([value, text]) => h("option", { value, text })));
    const address = h("input", { autocomplete: "off", spellcheck: "false", maxlength: 128, placeholder: t("Public address"), "aria-label": t("Public address") });
    const label = h("input", { maxlength: 120, placeholder: t("Label (optional)"), "aria-label": t("Label (optional)") });
    body.append(list, h("div", { class: "row", style: "margin-top:12px" }, network, address),
      h("div", { class: "row" }, label, h("button", { text: t("Add"), onclick: () => void walletRun([...settings.wallets, { kind: network.value, address: address.value.trim(), label: label.value.trim() }]) })), walletStatus);
  }
  return section;
}
