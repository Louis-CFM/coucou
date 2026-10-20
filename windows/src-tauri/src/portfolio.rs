// The Portfolio pill — port of PortfolioController.swift. Real balances from
// connected exchange accounts (read-only API keys, kept in the credential
// store) and self-custody wallets (public addresses only, in portfolio.json),
// valued in dollars from Coinbase's public prices. Read every 2 min, only while
// the pill is declared and Coucou isn't paused.
//
// The keys never reach a webview: Settings hands them to `portfolio_add_exchange`,
// which tests them against the exchange and only then stores them.

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager};

use crate::i18n::t;

pub const PILL_ID: &str = "integration_portfolio";
const TIMEOUT: Duration = Duration::from_secs(10);

// ── Data model ────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Holding {
    /// "BTC", "ETH", "USDT".
    pub symbol: String,
    /// Raw units (BTC, not satoshi).
    pub amount: f64,
    /// USD price; filled after the price pass.
    pub price: f64,
    /// % change vs 24 h ago; None = unavailable.
    pub change24h: Option<f64>,
    /// The last 7 daily closes, oldest first.
    pub price_history: Vec<f64>,
}

impl Holding {
    fn new(symbol: impl Into<String>, amount: f64) -> Self {
        Holding { symbol: symbol.into(), amount, price: 0.0, change24h: None, price_history: Vec::new() }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ExchangeKind {
    Binance,
    Okx,
    Bybit,
    Kraken,
    Coinbase,
}

pub const EXCHANGES: [ExchangeKind; 5] =
    [ExchangeKind::Binance, ExchangeKind::Okx, ExchangeKind::Bybit, ExchangeKind::Kraken, ExchangeKind::Coinbase];

impl ExchangeKind {
    pub fn name(self) -> &'static str {
        match self {
            ExchangeKind::Binance => "Binance",
            ExchangeKind::Okx => "OKX",
            ExchangeKind::Bybit => "Bybit",
            ExchangeKind::Kraken => "Kraken",
            ExchangeKind::Coinbase => "Coinbase",
        }
    }

    fn raw(self) -> &'static str {
        match self {
            ExchangeKind::Binance => "binance",
            ExchangeKind::Okx => "okx",
            ExchangeKind::Bybit => "bybit",
            ExchangeKind::Kraken => "kraken",
            ExchangeKind::Coinbase => "coinbase",
        }
    }

    /// OKX alone asks for a passphrase.
    pub fn needs_passphrase(self) -> bool {
        self == ExchangeKind::Okx
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum WalletKind {
    Bitcoin,
    Dogecoin,
    Litecoin,
    Ethereum,
    Polygon,
    BnbChain,
    Avalanche,
    Arbitrum,
    Optimism,
    Base,
    Solana,
    Tron,
    Xrp,
    Cardano,
    Cosmos,
    Near,
}

impl WalletKind {
    pub fn name(self) -> &'static str {
        match self {
            WalletKind::Bitcoin => "Bitcoin",
            WalletKind::Dogecoin => "Dogecoin",
            WalletKind::Litecoin => "Litecoin",
            WalletKind::Ethereum => "Ethereum",
            WalletKind::Polygon => "Polygon",
            WalletKind::BnbChain => "BNB Chain",
            WalletKind::Avalanche => "Avalanche",
            WalletKind::Arbitrum => "Arbitrum",
            WalletKind::Optimism => "Optimism",
            WalletKind::Base => "Base",
            WalletKind::Solana => "Solana",
            WalletKind::Tron => "TRON",
            WalletKind::Xrp => "XRP Ledger",
            WalletKind::Cardano => "Cardano",
            WalletKind::Cosmos => "Cosmos",
            WalletKind::Near => "NEAR",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Wallet {
    pub kind: WalletKind,
    pub address: String,
    /// The user's label, else the address cut short.
    pub label: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum Source {
    Exchange { exchange: ExchangeKind, name: &'static str },
    Wallet { wallet: Wallet, network: &'static str },
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Account {
    pub id: String,
    pub source: Source,
    pub holdings: Vec<Holding>,
    pub fetch_error: Option<String>,
}

impl Account {
    fn exchange(kind: ExchangeKind) -> Self {
        Account {
            id: kind.raw().to_string(),
            source: Source::Exchange { exchange: kind, name: kind.name() },
            holdings: Vec::new(),
            fetch_error: None,
        }
    }

    fn wallet(w: &Wallet) -> Self {
        Account {
            id: w.address.clone(),
            source: Source::Wallet { wallet: w.clone(), network: w.kind.name() },
            holdings: Vec::new(),
            fetch_error: None,
        }
    }
}

// ── Settings ──────────────────────────────────────────────────────────────────

/// The credential store's names for an exchange's key, secret and passphrase.
pub fn credential_keys(kind: ExchangeKind) -> [String; 3] {
    let p = format!("portfolio-{}", kind.raw());
    [format!("{p}-key"), format!("{p}-secret"), format!("{p}-passphrase")]
}

#[derive(Clone, Default)]
struct Credentials {
    key: String,
    secret: String,
    passphrase: String,
}

fn stored(kind: ExchangeKind) -> Option<Credentials> {
    let [k, s, p] = credential_keys(kind);
    let c = Credentials {
        key: crate::secrets::get_internal(&k)?,
        secret: crate::secrets::get_internal(&s)?,
        passphrase: crate::secrets::get_internal(&p).unwrap_or_default(),
    };
    (!kind.needs_passphrase() || !c.passphrase.is_empty()).then_some(c)
}

fn store(kind: ExchangeKind, c: &Credentials) -> Result<(), String> {
    let [k, s, p] = credential_keys(kind);
    crate::secrets::set_internal(&k, &c.key)?;
    crate::secrets::set_internal(&s, &c.secret)?;
    crate::secrets::set_internal(&p, if kind.needs_passphrase() { &c.passphrase } else { "" })
}

fn wallets_path() -> std::path::PathBuf {
    crate::platform::config_dir().join("portfolio.json")
}

fn load_wallets() -> Vec<Wallet> {
    std::fs::read(wallets_path()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

fn save_wallets(list: &[Wallet]) {
    if let Ok(json) = serde_json::to_vec_pretty(list) {
        let _ = std::fs::write(wallets_path(), json);
    }
}

/// All configured exchange accounts, then the wallets, in a fixed order.
fn configured() -> Vec<Account> {
    let mut out: Vec<Account> = EXCHANGES.iter().filter(|k| stored(**k).is_some()).map(|k| Account::exchange(*k)).collect();
    out.extend(load_wallets().iter().map(Account::wallet));
    out
}

// ── State ─────────────────────────────────────────────────────────────────────

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub accounts: Vec<Account>,
    pub loaded: bool,
    /// Exchanges with a key stored, for Settings.
    pub exchanges: Vec<ExchangeKind>,
    pub wallets: Vec<Wallet>,
}

struct Inner {
    accounts: Vec<Account>,
    loaded: bool,
    last_update: Option<Instant>,
    /// Bumped by every change in Settings: a read started before is dropped.
    generation: u64,
}

static STATE: Mutex<Inner> = Mutex::new(Inner { accounts: Vec::new(), loaded: false, last_update: None, generation: 0 });
static FETCHING: AtomicBool = AtomicBool::new(false);

fn snapshot() -> Snapshot {
    let i = STATE.lock().unwrap();
    Snapshot {
        accounts: i.accounts.clone(),
        loaded: i.loaded,
        exchanges: EXCHANGES.iter().copied().filter(|k| stored(*k).is_some()).collect(),
        wallets: load_wallets(),
    }
}

fn publish(app: &AppHandle) {
    let _ = app.emit("portfolio", snapshot());
}

fn pill_active(app: &AppHandle) -> bool {
    app.try_state::<crate::Shared>()
        .map(|s| s.settings.lock().unwrap().active_integrations.iter().any(|x| x == PILL_ID))
        .unwrap_or(false)
}

fn may_fetch(app: &AppHandle) -> bool {
    pill_active(app) && !crate::integrations::PAUSED.load(Ordering::Relaxed)
}

fn forget() -> bool {
    let mut i = STATE.lock().unwrap();
    let had = i.loaded || !i.accounts.is_empty();
    i.accounts.clear();
    i.loaded = false;
    i.last_update = None;
    had
}

/// The 2 min loop. Off (the pill not declared, or Coucou paused): nothing is
/// read, and what was read is forgotten.
pub fn start(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(Duration::from_secs(5)).await;
        let mut ticker = tokio::time::interval(Duration::from_secs(120));
        loop {
            ticker.tick().await;
            if may_fetch(&app) {
                refresh(&app).await;
            } else if forget() {
                publish(&app);
            }
        }
    });
}

/// Settings saved: the pill just turned on → read now; off → forget.
pub fn settings_saved(app: &AppHandle) {
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        if may_fetch(&app) {
            if STATE.lock().unwrap().last_update.is_none() {
                refresh(&app).await;
            }
        } else if forget() {
            publish(&app);
        }
    });
}

fn changed(app: &AppHandle) {
    {
        let mut i = STATE.lock().unwrap();
        i.generation += 1;
        i.accounts.clear();
        i.loaded = false;
        i.last_update = None;
    }
    publish(app);
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        if may_fetch(&app) {
            refresh(&app).await;
        }
    });
}

async fn refresh(app: &AppHandle) {
    if FETCHING.swap(true, Ordering::SeqCst) {
        return;
    }
    let generation = STATE.lock().unwrap().generation;
    let accounts = configured();
    if accounts.is_empty() {
        {
            let mut i = STATE.lock().unwrap();
            i.accounts.clear();
            i.loaded = true;
            i.last_update = Some(Instant::now());
        }
        FETCHING.store(false, Ordering::SeqCst);
        publish(app);
        return;
    }
    let client = client();
    let handles: Vec<_> = accounts
        .into_iter()
        .map(|a| {
            let client = client.clone();
            tauri::async_runtime::spawn(async move { fetch_account(&client, a).await })
        })
        .collect();
    let mut fetched = Vec::with_capacity(handles.len());
    for h in handles {
        if let Ok(a) = h.await {
            fetched.push(a);
        }
    }
    let symbols: Vec<String> = fetched
        .iter()
        .flat_map(|a| a.holdings.iter().map(|h| h.symbol.clone()))
        .collect::<HashSet<_>>()
        .into_iter()
        .collect();
    let prices = fetch_prices(&client, &symbols).await;
    for a in &mut fetched {
        for h in &mut a.holdings {
            if let Some(info) = prices.get(&h.symbol) {
                h.price = info.price;
                h.change24h = info.change24h;
                h.price_history = info.history.clone();
            } else if matches!(h.symbol.as_str(), "USDT" | "USDC" | "BUSD" | "DAI") {
                // Stable coins ≈ $1.
                h.price = 1.0;
            }
        }
        a.holdings.sort_by(|x, y| (y.amount * y.price).total_cmp(&(x.amount * x.price)));
    }
    FETCHING.store(false, Ordering::SeqCst);
    {
        let mut i = STATE.lock().unwrap();
        if i.generation != generation {
            return;
        }
        i.accounts = fetched;
        i.loaded = true;
        i.last_update = Some(Instant::now());
    }
    publish(app);
}

fn client() -> reqwest::Client {
    reqwest::Client::builder()
        .timeout(TIMEOUT)
        .user_agent(concat!("Coucou/", env!("CARGO_PKG_VERSION")))
        .build()
        .unwrap_or_default()
}

async fn fetch_account(client: &reqwest::Client, mut a: Account) -> Account {
    let result = match &a.source {
        Source::Exchange { exchange, .. } => match stored(*exchange) {
            Some(c) => fetch_exchange(client, *exchange, &c).await,
            None => Err(t("No credentials found. Add them in Settings.")),
        },
        Source::Wallet { wallet, .. } => fetch_wallet(client, wallet).await,
    };
    match result {
        Ok(h) => a.holdings = h,
        Err(e) => a.fetch_error = Some(e),
    }
    a
}

// ── Prices (Coinbase public, no key) ──────────────────────────────────────────

struct PriceInfo {
    price: f64,
    change24h: Option<f64>,
    /// 7 daily closes, oldest first.
    history: Vec<f64>,
}

/// Cash held on an exchange: valued with the day's exchange rate, no market data.
const FIAT: [&str; 7] = ["USD", "EUR", "GBP", "CHF", "CAD", "AUD", "JPY"];

/// USD price of every asset Coinbase knows (fiat and crypto), from its public
/// exchange rates: one request. `rates[X]` is how many X one dollar buys.
async fn usd_rates(client: &reqwest::Client) -> HashMap<String, f64> {
    let Ok(res) = client.get("https://api.coinbase.com/v2/exchange-rates?currency=USD").header("Accept", "application/json").send().await
    else {
        return HashMap::new();
    };
    if !res.status().is_success() {
        return HashMap::new();
    }
    let Ok(json) = res.json::<Value>().await else { return HashMap::new() };
    let Some(rates) = json.pointer("/data/rates").and_then(Value::as_object) else { return HashMap::new() };
    rates
        .iter()
        .filter_map(|(k, v)| number(v).filter(|r| *r > 0.0).map(|r| (k.to_uppercase(), 1.0 / r)))
        .collect()
}

async fn fetch_prices(client: &reqwest::Client, symbols: &[String]) -> HashMap<String, PriceInfo> {
    let mut out = HashMap::new();
    if symbols.is_empty() {
        return out;
    }
    // Cash and anything without a Coinbase market still get a price from the
    // exchange rates; markets add the 24 h change and the curve.
    let rates = usd_rates(client).await;
    for s in symbols {
        if s == "USD" {
            out.insert(s.clone(), PriceInfo { price: 1.0, change24h: None, history: Vec::new() });
        } else if let Some(p) = rates.get(s) {
            out.insert(s.clone(), PriceInfo { price: *p, change24h: None, history: Vec::new() });
        }
    }
    let handles: Vec<_> = symbols
        .iter()
        .filter(|s| !FIAT.contains(&s.as_str()) && s.chars().all(|c| c.is_ascii_alphanumeric()))
        .map(|s| {
            let (client, s) = (client.clone(), s.clone());
            tauri::async_runtime::spawn(async move {
                let info = market(&client, &s).await;
                (s, info)
            })
        })
        .collect();
    for h in handles {
        if let Ok((s, Some(info))) = h.await {
            out.insert(s, info);
        }
    }
    out
}

async fn market(client: &reqwest::Client, symbol: &str) -> Option<PriceInfo> {
    let base = format!("https://api.exchange.coinbase.com/products/{symbol}-USD");
    let res = client.get(format!("{base}/stats")).header("Accept", "application/json").send().await.ok()?;
    if res.status().as_u16() != 200 {
        return None;
    }
    let stats: Value = res.json().await.ok()?;
    let last = number(stats.get("last")?)?;
    let change = stats.get("open").and_then(number).map(|o| if o > 0.0 { (last - o) / o * 100.0 } else { 0.0 });
    let mut history = Vec::new();
    if let Ok(res) = client.get(format!("{base}/candles?granularity=86400")).header("Accept", "application/json").send().await {
        if res.status().as_u16() == 200 {
            if let Ok(Value::Array(rows)) = res.json::<Value>().await {
                // [time, low, high, open, close, volume], newest first.
                history = rows
                    .iter()
                    .take(7)
                    .filter_map(|r| r.as_array().filter(|a| a.len() > 4).and_then(|a| number(&a[4])))
                    .collect();
                history.reverse();
            }
        }
    }
    Some(PriceInfo { price: last, change24h: change, history })
}

fn number(v: &Value) -> Option<f64> {
    match v {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
}

// ── Signing ───────────────────────────────────────────────────────────────────

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn hmac_sha256(key: &[u8], message: &[u8]) -> Vec<u8> {
    ring::hmac::sign(&ring::hmac::Key::new(ring::hmac::HMAC_SHA256, key), message).as_ref().to_vec()
}

fn hmac_sha512(key: &[u8], message: &[u8]) -> Vec<u8> {
    ring::hmac::sign(&ring::hmac::Key::new(ring::hmac::HMAC_SHA512, key), message).as_ref().to_vec()
}

fn base64(bytes: &[u8]) -> String {
    crate::claude::base64_for(bytes)
}

fn base64_url(bytes: &[u8]) -> String {
    base64(bytes).replace('+', "-").replace('/', "_").replace('=', "")
}

fn now_ms() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0)
}

/// "2026-10-19T09:08:57.715Z" (OKX's timestamp).
fn iso8601(ms: u128) -> String {
    let secs = (ms / 1000) as i64;
    let (days, rem) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    // Howard Hinnant's days → civil date.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}.{:03}Z", rem / 3600, rem % 3600 / 60, rem % 60, ms % 1000)
}

fn http_error(status: reqwest::StatusCode, body: &str) -> String {
    let body = body.trim();
    if body.is_empty() {
        format!("HTTP {}", status.as_u16())
    } else {
        body.chars().take(200).collect()
    }
}

fn parse_error() -> String {
    t("Unexpected response from the exchange.")
}

async fn read_json(res: reqwest::Response) -> Result<Value, String> {
    let status = res.status();
    let body = res.text().await.map_err(|_| t("Network error. Check your connection."))?;
    if status.as_u16() != 200 {
        return Err(http_error(status, &body));
    }
    serde_json::from_str(&body).map_err(|_| parse_error())
}

fn network(_: reqwest::Error) -> String {
    t("Network error. Check your connection.")
}

// ── Exchanges ─────────────────────────────────────────────────────────────────

async fn fetch_exchange(client: &reqwest::Client, kind: ExchangeKind, c: &Credentials) -> Result<Vec<Holding>, String> {
    match kind {
        ExchangeKind::Binance => binance(client, c).await,
        ExchangeKind::Okx => okx(client, c).await,
        ExchangeKind::Bybit => bybit(client, c).await,
        ExchangeKind::Kraken => kraken(client, c).await,
        ExchangeKind::Coinbase => coinbase(client, c).await,
    }
}

fn str_number(v: Option<&Value>) -> Option<f64> {
    v.and_then(Value::as_str).and_then(|s| s.parse().ok())
}

async fn binance(client: &reqwest::Client, c: &Credentials) -> Result<Vec<Holding>, String> {
    let query = format!("timestamp={}", now_ms());
    let sig = hex(&hmac_sha256(c.secret.as_bytes(), query.as_bytes()));
    let res = client
        .get(format!("https://api.binance.com/api/v3/account?{query}&signature={sig}"))
        .header("X-MBX-APIKEY", &c.key)
        .send()
        .await
        .map_err(network)?;
    let json = read_json(res).await?;
    let balances = json.get("balances").and_then(Value::as_array).ok_or_else(parse_error)?;
    Ok(balances
        .iter()
        .filter_map(|b| {
            let asset = b.get("asset")?.as_str()?;
            let total = str_number(b.get("free"))? + str_number(b.get("locked"))?;
            (total > 0.000001).then(|| Holding::new(asset, total))
        })
        .collect())
}

async fn okx(client: &reqwest::Client, c: &Credentials) -> Result<Vec<Holding>, String> {
    let ts = iso8601(now_ms());
    let path = "/api/v5/account/balance";
    let sig = base64(&hmac_sha256(c.secret.as_bytes(), format!("{ts}GET{path}").as_bytes()));
    let res = client
        .get(format!("https://www.okx.com{path}"))
        .header("Content-Type", "application/json")
        .header("OK-ACCESS-KEY", &c.key)
        .header("OK-ACCESS-SIGN", sig)
        .header("OK-ACCESS-TIMESTAMP", ts)
        .header("OK-ACCESS-PASSPHRASE", &c.passphrase)
        .send()
        .await
        .map_err(network)?;
    let json = read_json(res).await?;
    let details = json.pointer("/data/0/details").and_then(Value::as_array).ok_or_else(parse_error)?;
    Ok(details
        .iter()
        .filter_map(|d| {
            let ccy = d.get("ccy")?.as_str()?;
            let total = str_number(d.get("availBal"))? + str_number(d.get("frozenBal"))?;
            (total > 0.000001).then(|| Holding::new(ccy, total))
        })
        .collect())
}

async fn bybit(client: &reqwest::Client, c: &Credentials) -> Result<Vec<Holding>, String> {
    let ts = now_ms().to_string();
    let recv = "5000";
    let query = "accountType=UNIFIED";
    let sig = hex(&hmac_sha256(c.secret.as_bytes(), format!("{ts}{}{recv}{query}", c.key).as_bytes()));
    let res = client
        .get(format!("https://api.bybit.com/v5/account/wallet-balance?{query}"))
        .header("X-BAPI-API-KEY", &c.key)
        .header("X-BAPI-SIGN", sig)
        .header("X-BAPI-TIMESTAMP", ts)
        .header("X-BAPI-RECV-WINDOW", recv)
        .send()
        .await
        .map_err(network)?;
    let json = read_json(res).await?;
    let coins = json.pointer("/result/list/0/coin").and_then(Value::as_array).ok_or_else(parse_error)?;
    Ok(coins
        .iter()
        .filter_map(|c| {
            let coin = c.get("coin")?.as_str()?;
            let bal = str_number(c.get("walletBalance"))?;
            (bal > 0.000001).then(|| Holding::new(coin, bal))
        })
        .collect())
}

/// Kraken's X/Z-prefixed names: XXBT = BTC, ZUSD = USD…
pub fn kraken_symbol(raw: &str) -> String {
    let known = [
        ("XXBT", "BTC"), ("XETH", "ETH"), ("XLTC", "LTC"), ("XXLM", "XLM"), ("XXMR", "XMR"), ("XXRP", "XRP"),
        ("XZEC", "ZEC"), ("ZUSD", "USD"), ("ZEUR", "EUR"), ("ZGBP", "GBP"), ("ZCAD", "CAD"), ("ZJPY", "JPY"),
    ];
    if let Some((_, s)) = known.iter().find(|(k, _)| *k == raw) {
        return s.to_string();
    }
    if raw.starts_with('X') || raw.starts_with('Z') { raw.chars().skip(1).collect() } else { raw.to_string() }
}

async fn kraken(client: &reqwest::Client, c: &Credentials) -> Result<Vec<Holding>, String> {
    let secret = crate::recap::decode_base64(c.secret.trim()).ok_or_else(|| t("No credentials found. Add them in Settings."))?;
    let nonce = now_ms().to_string();
    let path = "/0/private/Balance";
    let body = format!("nonce={nonce}");
    // SHA512-HMAC( path + SHA256(nonce + body) ).
    let inner = ring::digest::digest(&ring::digest::SHA256, format!("{nonce}{body}").as_bytes());
    let mut message = path.as_bytes().to_vec();
    message.extend_from_slice(inner.as_ref());
    let sig = base64(&hmac_sha512(&secret, &message));
    let res = client
        .post(format!("https://api.kraken.com{path}"))
        .header("Content-Type", "application/x-www-form-urlencoded")
        .header("API-Key", &c.key)
        .header("API-Sign", sig)
        .body(body)
        .send()
        .await
        .map_err(network)?;
    let json = read_json(res).await?;
    if let Some(first) = json.get("error").and_then(Value::as_array).and_then(|e| e.first()).and_then(Value::as_str) {
        return Err(first.to_string());
    }
    let result = json.get("result").and_then(Value::as_object).ok_or_else(parse_error)?;
    Ok(result
        .iter()
        .filter_map(|(k, v)| {
            let amount = number(v)?;
            (amount > 0.000001).then(|| Holding::new(kraken_symbol(k), amount))
        })
        .collect())
}

/// The EC private key from what the user pasted: a PEM ("EC PRIVATE KEY" or
/// "PRIVATE KEY"), its lines joined, or with "\n" escapes as in the downloaded
/// cdp_api_key.json.
pub fn coinbase_key(raw: &str) -> Option<ring::signature::EcdsaKeyPair> {
    use ring::signature::{EcdsaKeyPair, ECDSA_P256_SHA256_FIXED_SIGNING as ALG};
    let text = raw.replace("\\n", "\n");
    let mut body = text.trim_matches(|c: char| c == '"' || c.is_whitespace()).to_string();
    for marker in ["-----BEGIN EC PRIVATE KEY-----", "-----END EC PRIVATE KEY-----", "-----BEGIN PRIVATE KEY-----", "-----END PRIVATE KEY-----"] {
        body = body.replace(marker, "");
    }
    let body: String = body.chars().filter(|c| !c.is_whitespace()).collect();
    let der = crate::recap::decode_base64(&body)?;
    let rng = ring::rand::SystemRandom::new();
    if let Ok(k) = EcdsaKeyPair::from_pkcs8(&ALG, &der, &rng) {
        return Some(k);
    }
    // SEC1 ECPrivateKey: SEQUENCE { INTEGER 1, OCTET STRING (32-byte key), [0] curve, [1] BIT STRING (public key) }.
    let find = |pattern: &[u8]| der.windows(pattern.len()).position(|w| w == pattern).map(|i| i + pattern.len());
    let private = find(&[0x02, 0x01, 0x01, 0x04, 0x20]).and_then(|i| der.get(i..i + 32))?;
    let public = find(&[0xA1, 0x44, 0x03, 0x42, 0x00]).and_then(|i| der.get(i..i + 65))?;
    EcdsaKeyPair::from_private_key_and_public_key(&ALG, private, public, &rng).ok()
}

/// A JWT for Coinbase's CDP API keys: header {alg ES256, kid, nonce, typ},
/// claims {sub, iss "cdp", nbf, exp +120 s, uri "GET host/path"}. One per request.
fn coinbase_jwt(key_name: &str, key: &ring::signature::EcdsaKeyPair, host: &str, path: &str) -> Option<String> {
    let now = (now_ms() / 1000) as u64;
    let mut nonce = [0u8; 16];
    ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut nonce).ok()?;
    let header = json!({ "alg": "ES256", "kid": key_name, "nonce": hex(&nonce), "typ": "JWT" });
    let claims = json!({ "sub": key_name, "iss": "cdp", "nbf": now, "exp": now + 120, "uri": format!("GET {host}{path}") });
    let input = format!("{}.{}", base64_url(header.to_string().as_bytes()), base64_url(claims.to_string().as_bytes()));
    let sig = key.sign(&ring::rand::SystemRandom::new(), input.as_bytes()).ok()?;
    Some(format!("{input}.{}", base64_url(sig.as_ref())))
}

async fn coinbase(client: &reqwest::Client, c: &Credentials) -> Result<Vec<Holding>, String> {
    let key_name = c.key.trim();
    let key = coinbase_key(&c.secret).ok_or_else(|| {
        t("This private key can't be read. Paste the whole key, from BEGIN EC PRIVATE KEY to END EC PRIVATE KEY (ECDSA key).")
    })?;
    let (host, path) = ("api.coinbase.com", "/api/v3/brokerage/accounts");
    let mut totals: HashMap<String, f64> = HashMap::new();
    let mut cursor: Option<String> = None;
    // 250 accounts a page; ten pages is more than any account has.
    for _ in 0..10 {
        let jwt = coinbase_jwt(key_name, &key, host, path).ok_or_else(parse_error)?;
        let mut url = format!("https://{host}{path}?limit=250");
        if let Some(c) = &cursor {
            url.push_str("&cursor=");
            url.push_str(&c.chars().filter(|c| c.is_ascii_alphanumeric() || "-_".contains(*c)).collect::<String>());
        }
        let res = client.get(url).header("Authorization", format!("Bearer {jwt}")).header("Accept", "application/json").send().await.map_err(network)?;
        let json = read_json(res).await?;
        let accounts = json.get("accounts").and_then(Value::as_array).ok_or_else(parse_error)?;
        for a in accounts {
            let Some(currency) = a.get("currency").and_then(Value::as_str) else { continue };
            let amount = |k: &str| a.pointer(&format!("/{k}/value")).and_then(number).unwrap_or(0.0);
            *totals.entry(currency.to_string()).or_default() += amount("available_balance") + amount("hold");
        }
        match (json.get("has_next").and_then(Value::as_bool), json.get("cursor").and_then(Value::as_str)) {
            (Some(true), Some(next)) if !next.is_empty() => cursor = Some(next.to_string()),
            _ => break,
        }
    }
    Ok(totals.into_iter().filter(|(_, v)| *v > 0.000001).map(|(k, v)| Holding::new(k, v)).collect())
}

// ── Wallets ───────────────────────────────────────────────────────────────────

/// Quick local check before going to the network (AddressValidator).
pub fn plausible(address: &str, kind: WalletKind) -> bool {
    let a = address.trim();
    let n = a.chars().count();
    let lower = a.to_lowercase();
    match kind {
        WalletKind::Bitcoin => {
            if lower.starts_with("bc1") {
                (14..=90).contains(&n)
            } else {
                (a.starts_with('1') || a.starts_with('3')) && (25..=34).contains(&n)
            }
        }
        WalletKind::Dogecoin => (a.starts_with('D') || a.starts_with('A')) && (25..=34).contains(&n),
        WalletKind::Litecoin => {
            if lower.starts_with("ltc1") {
                (26..=90).contains(&n)
            } else {
                (a.starts_with('L') || a.starts_with('M')) && (25..=34).contains(&n)
            }
        }
        WalletKind::Ethereum
        | WalletKind::Polygon
        | WalletKind::BnbChain
        | WalletKind::Avalanche
        | WalletKind::Arbitrum
        | WalletKind::Optimism
        | WalletKind::Base => lower.starts_with("0x") && n == 42 && a[2..].chars().all(|c| c.is_ascii_hexdigit()),
        WalletKind::Solana => (32..=44).contains(&n),
        WalletKind::Tron => a.starts_with('T') && n == 34,
        WalletKind::Xrp => a.starts_with('r') && (25..=35).contains(&n),
        WalletKind::Cardano => lower.starts_with("addr1") && n >= 50,
        WalletKind::Cosmos => a.starts_with("cosmos1") && n == 45,
        WalletKind::Near => {
            if n == 64 {
                a.chars().all(|c| c.is_ascii_digit() || ('a'..='f').contains(&c))
            } else {
                (5..=64).contains(&n) && a.contains('.')
            }
        }
    }
}

/// Addresses only ever go into a URL path or a JSON body: anything outside
/// what addresses are made of is refused before a request is built.
fn safe_address(a: &str) -> bool {
    !a.is_empty() && a.len() <= 128 && a.chars().all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-' || c == '_')
}

async fn fetch_wallet(client: &reqwest::Client, w: &Wallet) -> Result<Vec<Holding>, String> {
    let a = w.address.trim();
    if !safe_address(a) {
        return Err(t("Invalid address format."));
    }
    let rpc = |urls: &'static [&'static str], symbol: &'static str| evm(client, a, urls, symbol);
    match w.kind {
        WalletKind::Bitcoin => btc(client, a).await,
        WalletKind::Dogecoin => blockchair(client, a, "dogecoin", "DOGE").await,
        WalletKind::Litecoin => blockchair(client, a, "litecoin", "LTC").await,
        // Two public RPCs per chain: the second answers when the first is down or rate-limited.
        WalletKind::Ethereum => rpc(&["https://ethereum-rpc.publicnode.com", "https://cloudflare-eth.com"], "ETH").await,
        WalletKind::Polygon => rpc(&["https://polygon-bor-rpc.publicnode.com", "https://polygon-rpc.com"], "POL").await,
        WalletKind::BnbChain => rpc(&["https://bsc-dataseed.binance.org", "https://bsc-rpc.publicnode.com"], "BNB").await,
        WalletKind::Avalanche => rpc(&["https://api.avax.network/ext/bc/C/rpc", "https://avalanche-c-chain-rpc.publicnode.com"], "AVAX").await,
        WalletKind::Arbitrum => rpc(&["https://arb1.arbitrum.io/rpc", "https://arbitrum-one-rpc.publicnode.com"], "ETH").await,
        WalletKind::Optimism => rpc(&["https://mainnet.optimism.io", "https://optimism-rpc.publicnode.com"], "ETH").await,
        WalletKind::Base => rpc(&["https://mainnet.base.org", "https://base-rpc.publicnode.com"], "ETH").await,
        WalletKind::Solana => solana(client, a).await,
        WalletKind::Tron => tron(client, a).await,
        WalletKind::Xrp => xrp(client, a).await,
        WalletKind::Cardano => cardano(client, a).await,
        WalletKind::Cosmos => cosmos(client, a).await,
        WalletKind::Near => near(client, a).await,
    }
}

async fn get_json(client: &reqwest::Client, url: &str) -> Result<Value, String> {
    let res = client.get(url).header("Accept", "application/json").send().await.map_err(network)?;
    if res.status().as_u16() != 200 {
        return Err(t("Network error. Check your connection."));
    }
    res.json().await.map_err(|_| t("Unexpected response from the exchange."))
}

async fn post_json(client: &reqwest::Client, url: &str, body: &Value) -> Result<Value, String> {
    let res = client.post(url).header("Accept", "application/json").json(body).send().await.map_err(network)?;
    if res.status().as_u16() != 200 {
        return Err(t("Network error. Check your connection."));
    }
    res.json().await.map_err(|_| parse_error())
}

async fn btc(client: &reqwest::Client, a: &str) -> Result<Vec<Holding>, String> {
    let json = get_json(client, &format!("https://blockchain.info/balance?active={a}&cors=true")).await?;
    let sat = json.get(a).and_then(|d| d.get("final_balance")).and_then(number).ok_or_else(parse_error)?;
    Ok(vec![Holding::new("BTC", sat / 1e8)])
}

async fn blockchair(client: &reqwest::Client, a: &str, chain: &str, symbol: &str) -> Result<Vec<Holding>, String> {
    let json = get_json(client, &format!("https://api.blockchair.com/{chain}/dashboards/address/{a}")).await?;
    let sat = json.get("data").and_then(|d| d.get(a)).and_then(|d| d.pointer("/address/balance")).and_then(number).ok_or_else(parse_error)?;
    Ok(vec![Holding::new(symbol, sat / 1e8)])
}

/// A 0x-prefixed hex quantity, as a float (no integer overflow on wei).
pub fn hex_to_f64(hex: &str) -> Option<f64> {
    let s = hex.strip_prefix("0x").or_else(|| hex.strip_prefix("0X")).unwrap_or(hex);
    s.chars().try_fold(0.0, |acc, c| c.to_digit(16).map(|d| acc * 16.0 + f64::from(d)))
}

async fn evm(client: &reqwest::Client, a: &str, urls: &[&str], symbol: &str) -> Result<Vec<Holding>, String> {
    let body = json!({ "jsonrpc": "2.0", "id": 1, "method": "eth_getBalance", "params": [a, "latest"] });
    let mut last = t("Network error. Check your connection.");
    for url in urls {
        match post_json(client, url, &body).await {
            Ok(json) => match json.get("result").and_then(Value::as_str).and_then(hex_to_f64) {
                Some(wei) => return Ok(vec![Holding::new(symbol, wei / 1e18)]),
                None => last = parse_error(),
            },
            Err(e) => last = e,
        }
    }
    Err(last)
}

async fn solana(client: &reqwest::Client, a: &str) -> Result<Vec<Holding>, String> {
    let json = post_json(client, "https://api.mainnet-beta.solana.com", &json!({ "jsonrpc": "2.0", "id": 1, "method": "getBalance", "params": [a] })).await?;
    let lamports = json.pointer("/result/value").and_then(number).ok_or_else(parse_error)?;
    Ok(vec![Holding::new("SOL", lamports / 1e9)])
}

async fn tron(client: &reqwest::Client, a: &str) -> Result<Vec<Holding>, String> {
    let json = get_json(client, &format!("https://api.trongrid.io/v1/accounts/{a}")).await?;
    let data = json.get("data").and_then(Value::as_array).ok_or_else(parse_error)?;
    let sun = data.first().and_then(|d| d.get("balance")).and_then(number).unwrap_or(0.0);
    Ok(vec![Holding::new("TRX", sun / 1e6)])
}

async fn xrp(client: &reqwest::Client, a: &str) -> Result<Vec<Holding>, String> {
    let json = post_json(client, "https://xrplcluster.com", &json!({ "method": "account_info", "params": [{ "account": a, "ledger_index": "current" }] })).await?;
    let drops = json.pointer("/result/account_data/Balance").and_then(number).ok_or_else(parse_error)?;
    Ok(vec![Holding::new("XRP", drops / 1e6)])
}

async fn cardano(client: &reqwest::Client, a: &str) -> Result<Vec<Holding>, String> {
    let json = post_json(client, "https://api.koios.rest/api/v1/address_info", &json!({ "_addresses": [a] })).await?;
    let first = json.as_array().and_then(|v| v.first()).ok_or_else(parse_error)?;
    let lovelace = first.get("balance").and_then(number).unwrap_or(0.0);
    Ok(vec![Holding::new("ADA", lovelace / 1e6)])
}

async fn cosmos(client: &reqwest::Client, a: &str) -> Result<Vec<Holding>, String> {
    let json = get_json(client, &format!("https://rest.cosmos.directory/cosmoshub/cosmos/bank/v1beta1/balances/{a}")).await?;
    let balances = json.get("balances").and_then(Value::as_array).ok_or_else(parse_error)?;
    Ok(balances
        .iter()
        .filter(|b| b.get("denom").and_then(Value::as_str) == Some("uatom"))
        .filter_map(|b| b.get("amount").and_then(number).filter(|v| *v > 0.0))
        .map(|v| Holding::new("ATOM", v / 1e6))
        .collect())
}

async fn near(client: &reqwest::Client, a: &str) -> Result<Vec<Holding>, String> {
    let body = json!({ "jsonrpc": "2.0", "id": "dontcare", "method": "query",
        "params": { "request_type": "view_account", "finality": "final", "account_id": a } });
    let json = post_json(client, "https://rpc.mainnet.near.org", &body).await?;
    let yocto = json.pointer("/result/amount").and_then(Value::as_str).ok_or_else(parse_error)?;
    // yoctoNEAR: 1 NEAR = 1e24.
    let near = yocto.chars().filter_map(|c| c.to_digit(10)).fold(0.0, |acc, d| acc * 10.0 + f64::from(d)) / 1e24;
    Ok(vec![Holding::new("NEAR", near)])
}

// ── Commands ──────────────────────────────────────────────────────────────────

#[tauri::command]
pub fn portfolio_state() -> Snapshot {
    snapshot()
}

/// Tests the keys with a real read, and stores them only when the exchange took
/// them. None on success, else what went wrong.
#[tauri::command]
pub async fn portfolio_add_exchange(app: AppHandle, exchange: ExchangeKind, key: String, secret: String, passphrase: String) -> Option<String> {
    let c = Credentials { key: key.trim().to_string(), secret: secret.trim().to_string(), passphrase: passphrase.trim().to_string() };
    if c.key.is_empty() || c.secret.is_empty() || (exchange.needs_passphrase() && c.passphrase.is_empty()) {
        return Some(t("No credentials found. Add them in Settings."));
    }
    if let Err(e) = fetch_exchange(&client(), exchange, &c).await {
        return Some(e);
    }
    if let Err(e) = store(exchange, &c) {
        return Some(e);
    }
    changed(&app);
    None
}

#[tauri::command]
pub fn portfolio_remove_exchange(app: AppHandle, exchange: ExchangeKind) {
    let _ = store(exchange, &Credentials::default());
    changed(&app);
}

/// Checks the address's balance can be read before keeping it.
#[tauri::command]
pub async fn portfolio_add_wallet(app: AppHandle, kind: WalletKind, address: String, label: String) -> Option<String> {
    let address = address.trim().to_string();
    if !plausible(&address, kind) || !safe_address(&address) {
        return Some(t("Invalid address format."));
    }
    let label = label.trim();
    let label = if label.is_empty() { format!("{}…", address.chars().take(12).collect::<String>()) } else { label.chars().take(60).collect() };
    let wallet = Wallet { kind, address: address.clone(), label };
    if let Err(e) = fetch_wallet(&client(), &wallet).await {
        return Some(e);
    }
    let mut list: Vec<Wallet> = load_wallets().into_iter().filter(|w| w.address != address).collect();
    list.push(wallet);
    save_wallets(&list);
    changed(&app);
    None
}

#[tauri::command]
pub fn portfolio_remove_wallet(app: AppHandle, address: String) {
    let list: Vec<Wallet> = load_wallets().into_iter().filter(|w| w.address != address).collect();
    save_wallets(&list);
    changed(&app);
}

/// The card came on screen: read again if the last read is older than 30 s.
#[tauri::command]
pub async fn portfolio_refresh(app: AppHandle) {
    let stale = STATE.lock().unwrap().last_update.is_none_or(|t| t.elapsed() > Duration::from_secs(30));
    if stale && may_fetch(&app) {
        refresh(&app).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn okx_timestamps_are_utc_with_milliseconds() {
        assert_eq!(iso8601(0), "1970-01-01T00:00:00.000Z");
        assert_eq!(iso8601(1_607_418_537_715), "2020-12-08T09:08:57.715Z");
        assert_eq!(iso8601(951_782_400_000), "2000-02-29T00:00:00.000Z");
    }

    #[test]
    fn kraken_names_lose_their_prefix() {
        assert_eq!(kraken_symbol("XXBT"), "BTC");
        assert_eq!(kraken_symbol("ZEUR"), "EUR");
        assert_eq!(kraken_symbol("XDOT"), "DOT");
        assert_eq!(kraken_symbol("SOL"), "SOL");
    }

    #[test]
    fn wei_does_not_overflow() {
        assert_eq!(hex_to_f64("0x0"), Some(0.0));
        assert_eq!(hex_to_f64("0xde0b6b3a7640000"), Some(1e18));
        assert_eq!(hex_to_f64("0xzz"), None);
    }

    #[test]
    fn addresses_are_checked_before_any_request() {
        assert!(plausible("0x52908400098527886E0F7030069857D2E4169EE7", WalletKind::Ethereum));
        assert!(!plausible("0x5290840009852788", WalletKind::Ethereum));
        assert!(plausible("bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq", WalletKind::Bitcoin));
        assert!(plausible("alice.near", WalletKind::Near));
        assert!(!plausible("alice", WalletKind::Near));
        assert!(plausible("TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7", WalletKind::Tron));
        assert!(!safe_address("abc/../x"));
        assert!(!safe_address("abc?x=1"));
    }

    #[test]
    fn a_hmac_matches_binances_documented_example() {
        // https://developers.binance.com/docs/binance-spot-api-docs/rest-api (HMAC example).
        let secret = "NhqPtmdSJYdKjVHjA7PZj4Mge3R5YNiP1e3UZjInClVN65XAbvqqM6A7H5fATj0j";
        let query = "symbol=LTCBTC&side=BUY&type=LIMIT&timeInForce=GTC&quantity=1&price=0.1&recvWindow=5000&timestamp=1499827319559";
        assert_eq!(
            hex(&hmac_sha256(secret.as_bytes(), query.as_bytes())),
            "c8db56825ae71d6d79447849e617115f4a920fa2acdcab2b053c4b2838bd6b71"
        );
    }

    #[test]
    fn coinbase_keys_are_read_as_sec1_or_pkcs8() {
        use ring::signature::{EcdsaKeyPair, KeyPair, ECDSA_P256_SHA256_FIXED_SIGNING};
        let rng = ring::rand::SystemRandom::new();
        let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
        let pem = format!("-----BEGIN PRIVATE KEY-----\\n{}\\n-----END PRIVATE KEY-----\\n", base64(pkcs8.as_ref()));
        let key = coinbase_key(&pem).expect("pkcs8 with escaped newlines");
        // The same key as SEC1, the way Coinbase hands it out: the PKCS#8 wraps it.
        let der = pkcs8.as_ref();
        let start = der.windows(3).position(|w| w == [0x30, 0x6B, 0x02]).or_else(|| der.windows(2).rposition(|w| w == [0x30, 0x77]));
        if let Some(start) = start {
            let sec1 = &der[start..];
            let pem = format!("-----BEGIN EC PRIVATE KEY-----\n{}\n-----END EC PRIVATE KEY-----", base64(sec1));
            let again = coinbase_key(&pem).expect("sec1");
            assert_eq!(again.public_key().as_ref(), key.public_key().as_ref());
        }
        let jwt = coinbase_jwt("organizations/x/apiKeys/y", &key, "api.coinbase.com", "/api/v3/brokerage/accounts").unwrap();
        assert_eq!(jwt.split('.').count(), 3);
        assert!(coinbase_key("not a key").is_none());
    }
}
