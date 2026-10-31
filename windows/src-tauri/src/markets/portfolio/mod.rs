mod exchanges;
mod signatures;
mod wallets;

use super::{client, json, now_ms, number};
use crate::integrations::{self, IntegrationUpdate};
use futures_util::{stream, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Mutex, OnceLock,
};
use std::time::Duration;
use tauri::AppHandle;
use wallets::Wallet;

const ID: &str = "integration_portfolio";
static WRITE: Mutex<()> = Mutex::new(());
static REVISION: AtomicU64 = AtomicU64::new(0);
static POLLING: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Config {
    exchanges: BTreeMap<String, String>,
    wallets: BTreeMap<String, WalletNetwork>,
    rates: String,
    max_wallets: usize,
    max_pages: usize,
    max_holdings: usize,
    receive_window_ms: u64,
    pub poll_seconds: u64,
    account_timeout_seconds: u64,
    price_timeout_seconds: u64,
}

#[derive(Deserialize)]
struct WalletNetwork {
    name: String,
    symbol: String,
    scale: f64,
    url: String,
    protocol: String,
}

pub fn config() -> &'static Config {
    static CONFIG: OnceLock<Config> = OnceLock::new();
    CONFIG.get_or_init(|| {
        serde_json::from_str(include_str!("defaults.json")).expect("portfolio defaults")
    })
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct Holding {
    symbol: String,
    amount: f64,
    price_usd: Option<f64>,
    change: Option<f64>,
    history: Vec<f64>,
}

impl Holding {
    fn new(symbol: String, amount: f64) -> Self {
        Self {
            symbol,
            amount,
            price_usd: None,
            change: None,
            history: Vec::new(),
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Account {
    id: String,
    label: String,
    network: String,
    holdings: Vec<Holding>,
    fetched_at: u64,
    error: Option<String>,
}

#[derive(Default, Serialize, Deserialize)]
struct Prefs {
    wallets: Vec<Wallet>,
}

#[derive(Serialize)]
pub struct Settings {
    wallets: Vec<Wallet>,
    exchanges: BTreeMap<String, bool>,
    networks: BTreeMap<String, String>,
}

fn path() -> std::path::PathBuf {
    crate::platform::config_dir().join("portfolio.json")
}

fn read() -> Result<Prefs, String> {
    match std::fs::read(path()) {
        Ok(bytes) => {
            let mut prefs: Prefs =
                serde_json::from_slice(&bytes).map_err(|_| "Cannot read portfolio.json")?;
            prefs.wallets = validate_wallets(prefs.wallets)?;
            Ok(prefs)
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Prefs::default()),
        Err(_) => Err("Cannot read portfolio.json".into()),
    }
}

fn validate_wallets(wallets: Vec<Wallet>) -> Result<Vec<Wallet>, String> {
    if wallets.len() > config().max_wallets {
        return Err("Too many wallets".into());
    }
    let mut seen = BTreeSet::new();
    let mut out = Vec::new();
    for wallet in wallets {
        let wallet = wallet.validate()?;
        if !seen.insert(wallet.id()) {
            return Err("This wallet is already listed on this network".into());
        }
        out.push(wallet);
    }
    Ok(out)
}

#[tauri::command]
pub fn portfolio_settings() -> Result<Settings, String> {
    let _lock = WRITE.lock().unwrap();
    Ok(Settings {
        wallets: read()?.wallets,
        exchanges: config()
            .exchanges
            .keys()
            .map(|name| exchanges::connected(name).map(|connected| (name.clone(), connected)))
            .collect::<Result<_, _>>()?,
        networks: config()
            .wallets
            .iter()
            .map(|(kind, def)| (kind.clone(), def.name.clone()))
            .collect(),
    })
}

fn changed(app: AppHandle) {
    integrations::emit(
        &app,
        IntegrationUpdate {
            id: ID,
            data: json!({}),
            error: None,
            event: None,
        },
    );
    tauri::async_runtime::spawn(poll(app));
}

#[tauri::command]
pub fn portfolio_save_wallets(app: AppHandle, wallets: Vec<Wallet>) -> Result<(), String> {
    let prefs = Prefs {
        wallets: validate_wallets(wallets)?,
    };
    {
        let _lock = WRITE.lock().unwrap();
        let path = path();
        let temp = path.with_extension("json.tmp");
        let result = crate::platform::ensure_private_dir(path.parent().unwrap())
            .and_then(|()| serde_json::to_vec_pretty(&prefs).map_err(std::io::Error::other))
            .and_then(|bytes| std::fs::write(&temp, bytes))
            .and_then(|()| std::fs::rename(&temp, &path));
        if result.is_err() {
            let _ = std::fs::remove_file(&temp);
            return Err("Cannot save portfolio.json".into());
        }
        REVISION.fetch_add(1, Ordering::SeqCst);
    }
    changed(app);
    Ok(())
}

#[tauri::command]
pub async fn portfolio_connect(
    app: AppHandle,
    exchange: String,
    credentials: exchanges::Credentials,
) -> Result<(), String> {
    if integrations::PAUSED.load(Ordering::Relaxed) {
        return Err("Coucou is paused".into());
    }
    exchanges::validate_credentials(&exchange, &credentials)?;
    let revision = REVISION.load(Ordering::SeqCst);
    // Test in memory first. A failed connection cannot replace working credentials.
    tokio::time::timeout(
        Duration::from_secs(config().account_timeout_seconds),
        exchanges::fetch_with(&client()?, &exchange, &credentials),
    )
    .await
    .map_err(|_| "Balance request timed out")??;
    {
        let _lock = WRITE.lock().unwrap();
        if REVISION.load(Ordering::SeqCst) != revision {
            return Err("Connection settings changed; try again".into());
        }
        exchanges::save(&exchange, credentials)?;
        REVISION.fetch_add(1, Ordering::SeqCst);
    }
    changed(app);
    Ok(())
}

#[tauri::command]
pub fn portfolio_disconnect(app: AppHandle, exchange: String) -> Result<(), String> {
    {
        let _lock = WRITE.lock().unwrap();
        exchanges::remove(&exchange)?;
        REVISION.fetch_add(1, Ordering::SeqCst);
    }
    changed(app);
    Ok(())
}

fn active(app: &AppHandle) -> bool {
    !integrations::PAUSED.load(Ordering::Relaxed) && integrations::enabled(app, ID)
}

enum Source {
    Exchange(String),
    Wallet(Wallet),
}

pub async fn poll(app: AppHandle) {
    if !active(&app) {
        return;
    }
    let _poll = POLLING.lock().await;
    if !active(&app) {
        return;
    }
    let revision = REVISION.load(Ordering::SeqCst);
    let settings = match portfolio_settings() {
        Ok(settings) => settings,
        Err(error) => {
            integrations::emit(
                &app,
                IntegrationUpdate {
                    id: ID,
                    data: json!({}),
                    error: Some(error),
                    event: None,
                },
            );
            return;
        }
    };
    let Ok(http) = client() else { return };
    let mut sources: Vec<Source> = settings
        .exchanges
        .into_iter()
        .filter(|(_, on)| *on)
        .map(|(name, _)| Source::Exchange(name))
        .collect();
    sources.extend(settings.wallets.into_iter().map(Source::Wallet));
    let mut accounts: Vec<Account> = stream::iter(sources)
        .map(|source| {
            let http = &http;
            let app = &app;
            async move {
                let (id, label, network) = match &source {
                    Source::Exchange(name) => (name.clone(), name.clone(), name.clone()),
                    Source::Wallet(w) => (
                        w.id(),
                        if w.label.is_empty() {
                            if w.address.len() <= 12 {
                                w.address.clone()
                            } else {
                                format!("{}…{}", &w.address[..6], &w.address[w.address.len() - 4..])
                            }
                        } else {
                            w.label.clone()
                        },
                        config().wallets[&w.kind].name.clone(),
                    ),
                };
                let result = if !active(app) || REVISION.load(Ordering::SeqCst) != revision {
                    Err("Refresh cancelled".into())
                } else {
                    tokio::time::timeout(
                        Duration::from_secs(config().account_timeout_seconds),
                        async {
                            match &source {
                                Source::Exchange(name) => exchanges::fetch(http, name).await,
                                Source::Wallet(w) => wallets::fetch(http, w).await,
                            }
                        },
                    )
                    .await
                    .unwrap_or_else(|_| Err("Balance request timed out".into()))
                };
                match result {
                    Ok(holdings) => Account {
                        id,
                        label,
                        network,
                        holdings,
                        fetched_at: now_ms(),
                        error: None,
                    },
                    Err(error) => Account {
                        id,
                        label,
                        network,
                        holdings: Vec::new(),
                        fetched_at: now_ms(),
                        error: Some(error),
                    },
                }
            }
        })
        .buffered(3)
        .collect()
        .await;
    if !active(&app) || REVISION.load(Ordering::SeqCst) != revision {
        return;
    }
    let symbols: BTreeSet<String> = accounts
        .iter()
        .flat_map(|a| a.holdings.iter().map(|h| h.symbol.clone()))
        .collect();
    let mut prices = BTreeMap::new();
    let price_error = if symbols.is_empty() {
        None
    } else {
        tokio::time::timeout(
            Duration::from_secs(config().price_timeout_seconds),
            prices_for(&app, revision, &http, symbols, &mut prices),
        )
        .await
        .err()
        .map(|_| "Price refresh timed out".to_string())
    };
    for account in &mut accounts {
        for holding in &mut account.holdings {
            if let Some(price) = prices.get(&holding.symbol) {
                holding.price_usd = Some(price.price);
                holding.change = price.change;
                holding.history = price.history.clone();
            }
        }
    }
    let (total_usd, unpriced, failed) = totals(&accounts);
    if !active(&app) || REVISION.load(Ordering::SeqCst) != revision {
        return;
    }
    integrations::emit(
        &app,
        IntegrationUpdate {
            id: ID,
            data: json!({"accounts":accounts,"totalUsd":total_usd,"unpriced":unpriced,
        "failed":failed,"complete":unpriced == 0 && failed == 0 && total_usd.is_some(),"priceError":price_error,"fetchedAt":now_ms()}),
            error: None,
            event: None,
        },
    );
}

struct Price {
    price: f64,
    change: Option<f64>,
    history: Vec<f64>,
}

async fn prices_for(
    app: &AppHandle,
    revision: u64,
    http: &reqwest::Client,
    symbols: BTreeSet<String>,
    prices: &mut BTreeMap<String, Price>,
) {
    static HISTORY: OnceLock<Mutex<BTreeMap<String, (u64, Vec<f64>)>>> = OnceLock::new();
    let history = HISTORY.get_or_init(Default::default);
    prices.insert(
        "USD".into(),
        Price {
            price: 1.0,
            change: None,
            history: Vec::new(),
        },
    );
    if let Ok(rates) = json(http.get(&config().rates)).await {
        for symbol in &symbols {
            if let Some(rate) = number(&rates["data"]["rates"][symbol])
                .filter(|r| *r > 0.0 && (1.0 / r).is_finite())
            {
                prices.insert(
                    symbol.clone(),
                    Price {
                        price: 1.0 / rate,
                        change: None,
                        history: Vec::new(),
                    },
                );
            }
        }
    }
    // A bounded public quote pass; unavailable pairs retain a rate, or remain unpriced.
    for symbol in symbols.iter().take(config().max_holdings) {
        if !active(app) || REVISION.load(Ordering::SeqCst) != revision {
            return;
        }
        if !symbol.bytes().all(|b| b.is_ascii_alphanumeric())
            || matches!(
                symbol.as_str(),
                "USD" | "EUR" | "GBP" | "JPY" | "CAD" | "AUD" | "CHF"
            )
        {
            continue;
        }
        if let Ok(quote) = super::quotes::fetch(http, "coinbase", "USD", symbol, false).await {
            if let Some(price) = quote.price {
                let cached = history.lock().unwrap().get(symbol).cloned();
                let points = if let Some((_, points)) = cached.filter(|(at, _)| {
                    now_ms().saturating_sub(*at) < super::network().history_seconds * 1000
                }) {
                    points
                } else {
                    tokio::time::sleep(Duration::from_millis(super::network().request_spacing_ms))
                        .await;
                    if !active(app) || REVISION.load(Ordering::SeqCst) != revision {
                        return;
                    }
                    match super::quotes::daily_history(http, symbol).await {
                        Ok(points) => {
                            let mut history = history.lock().unwrap();
                            if history.len() >= config().max_holdings {
                                history.clear();
                            }
                            history.insert(symbol.clone(), (now_ms(), points.clone()));
                            points
                        }
                        Err(_) => Vec::new(),
                    }
                };
                prices.insert(
                    symbol.clone(),
                    Price {
                        price,
                        change: quote.change,
                        history: points,
                    },
                );
            }
        }
        tokio::time::sleep(Duration::from_millis(super::network().request_spacing_ms)).await;
    }
}

fn totals(accounts: &[Account]) -> (Option<f64>, usize, usize) {
    let mut sum = 0.0;
    let mut unpriced = 0;
    let mut priced = 0;
    for h in accounts
        .iter()
        .flat_map(|a| &a.holdings)
        .filter(|h| h.amount != 0.0)
    {
        match h.price_usd.map(|p| p * h.amount).filter(|n| n.is_finite()) {
            Some(value) => {
                sum += value;
                priced += 1;
            }
            None => unpriced += 1,
        }
    }
    let failed = accounts.iter().filter(|a| a.error.is_some()).count();
    let known_empty = unpriced == 0 && failed == 0 && !accounts.is_empty();
    (
        (sum.is_finite() && (priced > 0 || known_empty)).then_some(sum),
        unpriced,
        failed,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn a_partial_portfolio_never_looks_complete_or_turns_unknown_prices_into_zero() {
        let mut account = Account {
            id: "one".into(),
            label: String::new(),
            network: String::new(),
            holdings: vec![Holding::new("ABC".into(), 2.0)],
            fetched_at: 0,
            error: None,
        };
        assert_eq!(totals(std::slice::from_ref(&account)), (None, 1, 0));
        account.holdings.push(Holding {
            price_usd: Some(3.0),
            ..Holding::new("USD".into(), 5.0)
        });
        assert_eq!(totals(std::slice::from_ref(&account)), (Some(15.0), 1, 0));
        account.error = Some("HTTP 503".into());
        account.holdings.clear();
        assert_eq!(totals(&[account]), (None, 0, 1));
    }
}
