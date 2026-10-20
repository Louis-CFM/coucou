// The Crypto pill — port of CryptoController.swift. Prices of the coins the user
// picked, from Coinbase or OKX public market data (no key, no account). Read
// every 60 s and the 24 h curve every 10 min, only while the pill is declared
// and Coucou isn't paused: nothing goes over the network otherwise. An opt-in
// alert reveals the island when a coin moves more than the chosen percentage
// since the last alert.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::Value;
use tauri::{AppHandle, Emitter, Manager};

pub const PILL_ID: &str = "integration_crypto";
const MAX_COINS: usize = 8;
const DEFAULT_COINS: &str = "BTC, ETH, SOL";

// ── Exchange ──────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Exchange {
    #[default]
    Coinbase,
    Okx,
}

impl Exchange {
    pub fn name(self) -> &'static str {
        match self {
            Exchange::Coinbase => "Coinbase",
            Exchange::Okx => "OKX",
        }
    }

    /// Trading pair for a coin in a currency. OKX quotes dollars in USDT.
    pub fn pair(self, symbol: &str, currency: &str) -> String {
        match self {
            Exchange::Coinbase => format!("{symbol}-{currency}"),
            Exchange::Okx => format!("{symbol}-{}", if currency == "USD" { "USDT" } else { currency }),
        }
    }

    fn ticker_url(self, pair: &str) -> String {
        match self {
            Exchange::Coinbase => format!("https://api.exchange.coinbase.com/products/{pair}/stats"),
            Exchange::Okx => format!("https://www.okx.com/api/v5/market/ticker?instId={pair}"),
        }
    }

    fn candles_url(self, pair: &str) -> String {
        match self {
            Exchange::Coinbase => format!("https://api.exchange.coinbase.com/products/{pair}/candles?granularity=3600"),
            Exchange::Okx => format!("https://www.okx.com/api/v5/market/candles?instId={pair}&bar=1H&limit=24"),
        }
    }

    /// The coin's market page on the exchange's site.
    pub fn trade_url(self, pair: &str) -> String {
        match self {
            Exchange::Coinbase => format!("https://www.coinbase.com/advanced-trade/spot/{pair}"),
            Exchange::Okx => format!("https://www.okx.com/trade-spot/{}", pair.to_lowercase()),
        }
    }

    /// (price, price 24 h ago) from the ticker answer.
    pub fn parse_ticker(self, json: &Value) -> Option<(f64, f64)> {
        match self {
            Exchange::Coinbase => Some((number(json.get("last")?)?, number(json.get("open")?)?)),
            Exchange::Okx => {
                if json.get("code")?.as_str()? != "0" {
                    return None;
                }
                let row = json.get("data")?.as_array()?.first()?;
                Some((number(row.get("last")?)?, number(row.get("open24h")?)?))
            }
        }
    }

    /// Hourly closes, oldest first (both exchanges send newest first). Close is
    /// index 4 on both (Coinbase: time, low, high, open, close; OKX: ts, o, h, l, c).
    pub fn parse_candles(self, json: &Value) -> Vec<f64> {
        let rows = match self {
            Exchange::Coinbase => json.as_array(),
            Exchange::Okx => json.get("data").and_then(Value::as_array),
        };
        let Some(rows) = rows else { return Vec::new() };
        let mut closes: Vec<f64> = rows
            .iter()
            .take(24)
            .filter_map(|r| r.as_array().filter(|a| a.len() > 4).and_then(|a| number(&a[4])))
            .collect();
        closes.reverse();
        closes
    }
}

fn number(v: &Value) -> Option<f64> {
    match v {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
}

// ── Preferences ───────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Prefs {
    pub exchange: Exchange,
    /// "EUR" or "USD".
    pub currency: String,
    /// As typed: "BTC, ETH, SOL".
    pub coins: String,
    pub alert_enabled: bool,
    pub alert_percent: f64,
}

impl Default for Prefs {
    fn default() -> Self {
        Prefs {
            exchange: Exchange::Coinbase,
            currency: "EUR".into(),
            coins: DEFAULT_COINS.into(),
            alert_enabled: false,
            alert_percent: 5.0,
        }
    }
}

impl Prefs {
    fn currency(&self) -> &'static str {
        if self.currency == "USD" { "USD" } else { "EUR" }
    }

    fn percent(&self) -> f64 {
        if self.alert_percent > 0.0 { self.alert_percent.clamp(1.0, 50.0) } else { 5.0 }
    }

    fn key(&self) -> String {
        format!("{:?}|{}|{}", self.exchange, self.currency(), parse_coins(&self.coins).join(","))
    }
}

/// "btc, Eth;sol" → ["BTC", "ETH", "SOL"]: letters and digits only, no repeats, eight at most.
pub fn parse_coins(raw: &str) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    raw.to_uppercase()
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty() && w.chars().count() <= 10 && seen.insert(w.to_string()))
        .take(MAX_COINS)
        .map(str::to_string)
        .collect()
}

fn prefs_path() -> std::path::PathBuf {
    crate::platform::config_dir().join("crypto.json")
}

fn load_prefs() -> Prefs {
    std::fs::read(prefs_path()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

fn save_prefs(p: &Prefs) {
    if let Ok(json) = serde_json::to_vec_pretty(p) {
        let _ = std::fs::write(prefs_path(), json);
    }
}

// ── State ─────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Quote {
    pub symbol: String,
    pub price: f64,
    pub open24h: f64,
    /// Hourly closes over the last 24 h, oldest first (empty until the candles are read).
    pub spark: Vec<f64>,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub prefs: Prefs,
    pub exchange_name: &'static str,
    /// In the order the coins were listed; a coin the exchange doesn't list is absent.
    pub quotes: Vec<Quote>,
    /// Coins the exchange did not answer for (unknown pair, or no network).
    pub missing: Vec<String>,
    pub loaded: bool,
    /// The coin that set off the last alert, for the card to show it first.
    pub alert_symbol: Option<String>,
}

struct Inner {
    prefs: Prefs,
    quotes: Vec<Quote>,
    missing: Vec<String>,
    loaded: bool,
    last_update: Option<Instant>,
    last_candles: Option<Instant>,
    alert_symbol: Option<String>,
    /// Price each coin had at the last alert (or when first seen).
    reference: HashMap<String, f64>,
    settings_key: String,
}

static STATE: std::sync::LazyLock<Mutex<Inner>> = std::sync::LazyLock::new(|| {
    let prefs = load_prefs();
    Mutex::new(Inner {
        settings_key: prefs.key(),
        prefs,
        quotes: Vec::new(),
        missing: Vec::new(),
        loaded: false,
        last_update: None,
        last_candles: None,
        alert_symbol: None,
        reference: HashMap::new(),
    })
});

static FETCHING: AtomicBool = AtomicBool::new(false);

fn snapshot() -> Snapshot {
    let i = STATE.lock().unwrap();
    Snapshot {
        exchange_name: i.prefs.exchange.name(),
        prefs: i.prefs.clone(),
        quotes: i.quotes.clone(),
        missing: i.missing.clone(),
        loaded: i.loaded,
        alert_symbol: i.alert_symbol.clone(),
    }
}

fn publish(app: &AppHandle) {
    let _ = app.emit("crypto", snapshot());
}

fn forget(i: &mut Inner) {
    i.quotes.clear();
    i.missing.clear();
    i.loaded = false;
    i.last_update = None;
    i.last_candles = None;
    i.alert_symbol = None;
    i.reference.clear();
}

fn pill_active(app: &AppHandle) -> bool {
    app.try_state::<crate::Shared>()
        .map(|s| s.settings.lock().unwrap().active_integrations.iter().any(|x| x == PILL_ID))
        .unwrap_or(false)
}

fn may_fetch(app: &AppHandle) -> bool {
    pill_active(app) && !crate::integrations::PAUSED.load(Ordering::Relaxed)
}

/// The 60 s loop. Off (the pill not declared, or Coucou paused): no request, and
/// what was read is forgotten.
pub fn start(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(Duration::from_secs(4)).await;
        let mut ticker = tokio::time::interval(Duration::from_secs(60));
        loop {
            ticker.tick().await;
            if may_fetch(&app) {
                refresh(&app).await;
            } else {
                let had = {
                    let mut i = STATE.lock().unwrap();
                    let had = i.loaded || !i.quotes.is_empty();
                    forget(&mut i);
                    had
                };
                if had {
                    publish(&app);
                }
            }
        }
    });
}

/// Settings saved: the pill on → read at once; off → forget.
pub fn settings_saved(app: &AppHandle) {
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        if may_fetch(&app) {
            let stale = STATE.lock().unwrap().last_update.is_none();
            if stale {
                refresh(&app).await;
            }
        } else {
            forget(&mut STATE.lock().unwrap());
            publish(&app);
        }
    });
}

async fn refresh(app: &AppHandle) {
    if FETCHING.swap(true, Ordering::SeqCst) {
        return;
    }
    let (prefs, with_candles) = {
        let i = STATE.lock().unwrap();
        (i.prefs.clone(), i.last_candles.is_none_or(|t| t.elapsed() > Duration::from_secs(600)))
    };
    let coins = parse_coins(&prefs.coins);
    if coins.is_empty() {
        {
            let mut i = STATE.lock().unwrap();
            i.quotes.clear();
            i.missing.clear();
            i.loaded = true;
        }
        FETCHING.store(false, Ordering::SeqCst);
        publish(app);
        return;
    }
    let client = reqwest::Client::builder().timeout(Duration::from_secs(10)).build().unwrap_or_default();
    let currency = prefs.currency();
    // Every coin at once, as the Mac's task group does.
    let handles: Vec<_> = coins
        .iter()
        .map(|c| {
            let (client, coin, exchange) = (client.clone(), c.clone(), prefs.exchange);
            tauri::async_runtime::spawn(async move { fetch(&client, exchange, &coin, currency, with_candles).await })
        })
        .collect();
    let mut results = Vec::with_capacity(handles.len());
    for handle in handles {
        results.push(handle.await.ok().flatten());
    }
    FETCHING.store(false, Ordering::SeqCst);

    let alert = {
        let mut i = STATE.lock().unwrap();
        // Settings changed while reading: these prices are for another list.
        if i.settings_key != prefs.key() {
            return;
        }
        let previous: HashMap<String, Vec<f64>> = i.quotes.iter().map(|q| (q.symbol.clone(), q.spark.clone())).collect();
        let mut fresh = Vec::new();
        let mut missing = Vec::new();
        for (coin, result) in coins.iter().zip(results) {
            match result {
                Some(mut q) => {
                    // Keep the previous curve until a new one is read.
                    if q.spark.is_empty() {
                        q.spark = previous.get(&q.symbol).cloned().unwrap_or_default();
                    }
                    fresh.push(q);
                }
                None => missing.push(coin.clone()),
            }
        }
        if with_candles && !fresh.is_empty() {
            i.last_candles = Some(Instant::now());
        }
        i.quotes = fresh;
        i.missing = missing;
        i.loaded = true;
        i.last_update = Some(Instant::now());
        check_alerts(&mut i)
    };
    publish(app);
    if let Some(symbol) = alert {
        let _ = app.emit_to(crate::island::WINDOW_LABEL, "crypto-alert", symbol);
    }
}

async fn fetch(client: &reqwest::Client, exchange: Exchange, coin: &str, currency: &str, candles: bool) -> Option<Quote> {
    let pair = exchange.pair(coin, currency);
    let get = |url: String| client.get(url).header("Accept", "application/json").header("User-Agent", "Coucou").send();
    let res = get(exchange.ticker_url(&pair)).await.ok()?;
    if res.status().as_u16() != 200 {
        return None;
    }
    let json: Value = res.json().await.ok()?;
    let (price, open24h) = exchange.parse_ticker(&json)?;
    let mut quote = Quote { symbol: coin.to_string(), price, open24h, spark: Vec::new() };
    if candles {
        if let Ok(res) = get(exchange.candles_url(&pair)).await {
            if res.status().as_u16() == 200 {
                if let Ok(json) = res.json::<Value>().await {
                    quote.spark = exchange.parse_candles(&json);
                }
            }
        }
    }
    Some(quote)
}

/// A coin that moved more than the chosen percentage since the last alert (or
/// since it was first seen): its symbol, one alert at a time. Off by default.
fn check_alerts(i: &mut Inner) -> Option<String> {
    let enabled = i.prefs.alert_enabled;
    let percent = i.prefs.percent();
    let quotes = i.quotes.clone();
    for q in quotes {
        let Some(&reference) = i.reference.get(&q.symbol).filter(|r| **r > 0.0) else {
            i.reference.insert(q.symbol.clone(), q.price);
            continue;
        };
        let moved = (q.price - reference).abs() / reference * 100.0;
        if !enabled || moved < percent {
            continue;
        }
        i.reference.insert(q.symbol.clone(), q.price);
        i.alert_symbol = Some(q.symbol.clone());
        return Some(q.symbol);
    }
    None
}

// ── Commands ──────────────────────────────────────────────────────────────────

#[tauri::command]
pub fn crypto_state() -> Snapshot {
    snapshot()
}

/// Exchange, currency, coins or the alert changed in Settings: start over with the new list.
#[tauri::command]
pub fn crypto_set_prefs(app: AppHandle, prefs: Prefs) {
    let mut prefs = prefs;
    prefs.currency = prefs.currency().to_string();
    prefs.alert_percent = prefs.percent();
    let changed = {
        let mut i = STATE.lock().unwrap();
        let key = prefs.key();
        let changed = key != i.settings_key;
        i.prefs = prefs.clone();
        if changed {
            i.settings_key = key;
            forget(&mut i);
        }
        changed
    };
    save_prefs(&prefs);
    publish(&app);
    if changed {
        tauri::async_runtime::spawn(async move {
            if may_fetch(&app) {
                refresh(&app).await;
            }
        });
    }
}

/// The card came on screen: read again if the last read is older than 20 s.
#[tauri::command]
pub async fn crypto_refresh(app: AppHandle) {
    let stale = STATE.lock().unwrap().last_update.is_none_or(|t| t.elapsed() > Duration::from_secs(20));
    if stale && may_fetch(&app) {
        refresh(&app).await;
    }
}

/// A row's click: the coin's page on the exchange.
#[tauri::command]
pub fn crypto_open(symbol: String) {
    let prefs = STATE.lock().unwrap().prefs.clone();
    let symbol: String = symbol.chars().filter(|c| c.is_ascii_alphanumeric()).take(10).collect();
    if symbol.is_empty() {
        return;
    }
    crate::platform::open_url(&prefs.exchange.trade_url(&prefs.exchange.pair(&symbol, prefs.currency())));
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn coins_are_letters_and_digits_without_repeats() {
        assert_eq!(parse_coins("btc, Eth;sol  eth"), vec!["BTC", "ETH", "SOL"]);
        assert_eq!(parse_coins("a b c d e f g h i j").len(), MAX_COINS);
        assert!(parse_coins(" ,; ").is_empty());
        assert!(parse_coins("ABCDEFGHIJK").is_empty());
    }

    #[test]
    fn okx_quotes_dollars_in_usdt() {
        assert_eq!(Exchange::Coinbase.pair("BTC", "USD"), "BTC-USD");
        assert_eq!(Exchange::Okx.pair("BTC", "USD"), "BTC-USDT");
        assert_eq!(Exchange::Okx.pair("BTC", "EUR"), "BTC-EUR");
        assert_eq!(Exchange::Okx.trade_url("BTC-EUR"), "https://www.okx.com/trade-spot/btc-eur");
    }

    #[test]
    fn tickers_are_read_from_both_exchanges() {
        let cb = json!({ "open": "60000.5", "last": "61000", "volume": "1" });
        assert_eq!(Exchange::Coinbase.parse_ticker(&cb), Some((61000.0, 60000.5)));
        let okx = json!({ "code": "0", "data": [{ "last": "2.5", "open24h": "2" }] });
        assert_eq!(Exchange::Okx.parse_ticker(&okx), Some((2.5, 2.0)));
        let refused = json!({ "code": "51001", "data": [] });
        assert_eq!(Exchange::Okx.parse_ticker(&refused), None);
    }

    #[test]
    fn candles_come_back_oldest_first() {
        let cb = json!([[3, 0, 0, 0, 30.0], [2, 0, 0, 0, 20.0], [1, 0, 0, 0, 10.0]]);
        assert_eq!(Exchange::Coinbase.parse_candles(&cb), vec![10.0, 20.0, 30.0]);
        let okx = json!({ "data": [["3", "0", "0", "0", "3"], ["2", "0", "0", "0", "2"]] });
        assert_eq!(Exchange::Okx.parse_candles(&okx), vec![2.0, 3.0]);
    }

    fn inner(alert: bool) -> Inner {
        Inner {
            prefs: Prefs { alert_enabled: alert, alert_percent: 5.0, ..Prefs::default() },
            quotes: Vec::new(),
            missing: Vec::new(),
            loaded: true,
            last_update: None,
            last_candles: None,
            alert_symbol: None,
            reference: HashMap::new(),
            settings_key: String::new(),
        }
    }

    fn quote(symbol: &str, price: f64) -> Quote {
        Quote { symbol: symbol.into(), price, open24h: price, spark: Vec::new() }
    }

    #[test]
    fn an_alert_needs_the_move_since_the_last_one() {
        let mut i = inner(true);
        i.quotes = vec![quote("BTC", 100.0)];
        assert_eq!(check_alerts(&mut i), None, "first seen: the reference");
        i.quotes = vec![quote("BTC", 104.0)];
        assert_eq!(check_alerts(&mut i), None);
        i.quotes = vec![quote("BTC", 105.0)];
        assert_eq!(check_alerts(&mut i).as_deref(), Some("BTC"));
        i.quotes = vec![quote("BTC", 106.0)];
        assert_eq!(check_alerts(&mut i), None, "measured from the alert's price");
    }

    #[test]
    fn no_alert_while_turned_off() {
        let mut i = inner(false);
        i.quotes = vec![quote("ETH", 100.0)];
        check_alerts(&mut i);
        i.quotes = vec![quote("ETH", 200.0)];
        assert_eq!(check_alerts(&mut i), None);
    }
}
