use super::*;
use crate::integrations::{self, IntegrationEvent, IntegrationUpdate};
use serde_json::json;
use std::collections::HashMap;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Quote {
    pub symbol: String,
    pub currency: String,
    pub price: Option<f64>,
    pub change: Option<f64>,
    pub history: Vec<f64>,
    pub fetched_at: u64,
    pub error: Option<String>,
}

#[derive(Default)]
struct Cache {
    prefs: Option<Prefs>,
    history: HashMap<String, (u64, Vec<f64>)>,
    alert_prices: HashMap<String, f64>,
}

static CACHE: OnceLock<tokio::sync::Mutex<Cache>> = OnceLock::new();

pub async fn poll(app: AppHandle) {
    if integrations::PAUSED.load(Ordering::Relaxed)
        || !integrations::enabled(&app, "integration_crypto")
    {
        return;
    }
    let mut cache = CACHE.get_or_init(Default::default).lock().await;
    // Queued refreshes must recheck after acquiring the lock.
    if integrations::PAUSED.load(Ordering::Relaxed)
        || !integrations::enabled(&app, "integration_crypto")
    {
        return;
    }
    let revision = REVISION.load(Ordering::SeqCst);
    let prefs = match markets_prefs() {
        Ok(p) => p,
        Err(error) => {
            integrations::emit(
                &app,
                IntegrationUpdate {
                    id: "integration_crypto",
                    data: json!({}),
                    error: Some(error),
                    event: None,
                },
            );
            return;
        }
    };
    if cache.prefs.as_ref() != Some(&prefs) {
        *cache = Cache {
            prefs: Some(prefs.clone()),
            ..Default::default()
        };
    }
    let Ok(http) = client() else { return };
    let mut quotes = Vec::new();
    let mut alerts = Vec::new();
    for coin in &prefs.coins {
        if integrations::PAUSED.load(Ordering::Relaxed)
            || !integrations::enabled(&app, "integration_crypto")
            || REVISION.load(Ordering::SeqCst) != revision
        {
            return;
        }
        let old_history = cache.history.get(coin).cloned();
        let history_due = old_history
            .as_ref()
            .is_none_or(|(at, _)| now_ms().saturating_sub(*at) >= network().history_seconds * 1000);
        let quote = fetch(&http, &prefs.exchange, &prefs.currency, coin, history_due).await;
        match quote {
            Ok(mut quote) => {
                if history_due && quote.error.is_none() {
                    cache
                        .history
                        .insert(coin.clone(), (now_ms(), quote.history.clone()));
                }
                if quote.history.is_empty() {
                    quote.history = old_history.map(|(_, h)| h).unwrap_or_default();
                }
                if let Some(price) = quote.price {
                    let baseline = cache.alert_prices.entry(coin.clone()).or_insert(price);
                    if prefs.alerts
                        && *baseline > 0.0
                        && ((price / *baseline - 1.0) * 100.0).abs() >= prefs.alert_percent
                    {
                        alerts.push(format!("{coin} {:+.1}%", (price / *baseline - 1.0) * 100.0));
                        *baseline = price;
                    }
                }
                quotes.push(quote);
            }
            Err(error) => quotes.push(Quote {
                symbol: coin.clone(),
                currency: quote_currency(&prefs.exchange, &prefs.currency).into(),
                price: None,
                change: None,
                history: Vec::new(),
                fetched_at: now_ms(),
                error: Some(error),
            }),
        }
        tokio::time::sleep(Duration::from_millis(network().request_spacing_ms)).await;
    }
    if REVISION.load(Ordering::SeqCst) != revision
        || integrations::PAUSED.load(Ordering::Relaxed)
        || !integrations::enabled(&app, "integration_crypto")
    {
        return;
    }
    integrations::emit(
        &app,
        IntegrationUpdate {
            id: "integration_crypto",
            data: json!({"quotes": quotes, "exchange": prefs.exchange, "fetchedAt": now_ms()}),
            error: None,
            event: (!alerts.is_empty()).then(|| IntegrationEvent {
                success: true,
                label: alerts.join(" · "),
                detail: None,
            }),
        },
    );
}

// OKX's dollar pairs use Tether. Keep USDT explicit in the UI; it is not USD.
fn quote_currency<'a>(exchange: &str, currency: &'a str) -> &'a str {
    if exchange == "okx" && currency == "USD" {
        "USDT"
    } else {
        currency
    }
}

pub async fn fetch(
    http: &reqwest::Client,
    exchange: &str,
    currency: &str,
    coin: &str,
    history: bool,
) -> Result<Quote, String> {
    let currency = quote_currency(exchange, currency);
    let pair = format!("{coin}-{currency}");
    let (stats_url, history_url) = match exchange {
        "okx" => (
            format!("{}/api/v5/market/ticker?instId={pair}", network().okx),
            format!(
                "{}/api/v5/market/candles?instId={pair}&bar=1H&limit={}",
                network().okx,
                network().history_points
            ),
        ),
        _ => (
            format!("{}/products/{pair}/stats", network().coinbase),
            format!(
                "{}/products/{pair}/candles?granularity=3600",
                network().coinbase
            ),
        ),
    };
    let stats = json(http.get(stats_url)).await?;
    let (price, change) = parse_stats(exchange, &stats)?;
    let mut quote = Quote {
        symbol: coin.into(),
        currency: currency.into(),
        price: Some(price),
        change,
        history: Vec::new(),
        fetched_at: now_ms(),
        error: None,
    };
    if history {
        tokio::time::sleep(Duration::from_millis(network().request_spacing_ms)).await;
        match json(http.get(history_url))
            .await
            .and_then(|v| parse_history(exchange, &v))
        {
            Ok(values) => quote.history = values,
            Err(error) => quote.error = Some(format!("{}: {error}", crate::i18n::t("History"))),
        }
    }
    Ok(quote)
}

fn okx_rows(value: &Value) -> Result<&Vec<Value>, String> {
    if value["code"].as_str() != Some("0") {
        return Err("Exchange request failed".into());
    }
    value["data"]
        .as_array()
        .ok_or_else(|| "Invalid response".into())
}

fn parse_stats(exchange: &str, value: &Value) -> Result<(f64, Option<f64>), String> {
    let row = if exchange == "okx" {
        okx_rows(value)?.first().ok_or("Pair unavailable")?
    } else {
        value
    };
    let price = number(&row["last"])
        .filter(|n| *n > 0.0)
        .ok_or("Pair unavailable")?;
    let open =
        number(&row[if exchange == "okx" { "open24h" } else { "open" }]).filter(|n| *n > 0.0);
    Ok((
        price,
        open.map(|open| (price / open - 1.0) * 100.0)
            .filter(|n| n.is_finite()),
    ))
}

fn parse_history(exchange: &str, value: &Value) -> Result<Vec<f64>, String> {
    let rows = if exchange == "okx" {
        okx_rows(value)?
    } else {
        value.as_array().ok_or("Invalid history")?
    };
    let mut points: Vec<(f64, f64)> = rows
        .iter()
        .filter_map(|row| Some((number(&row[0])?, number(&row[4]).filter(|p| *p > 0.0)?)))
        .collect();
    points.sort_by(|a, b| a.0.total_cmp(&b.0));
    points.dedup_by(|a, b| a.0 == b.0);
    if points.is_empty() {
        return Err("No price history".into());
    }
    Ok(points
        .iter()
        .rev()
        .take(network().history_points)
        .rev()
        .map(|p| p.1)
        .collect())
}

pub async fn daily_history(http: &reqwest::Client, symbol: &str) -> Result<Vec<f64>, String> {
    let url = format!(
        "{}/products/{symbol}-USD/candles?granularity=86400",
        network().coinbase
    );
    let points = parse_history("coinbase", &json(http.get(url)).await?)?;
    Ok(points
        .into_iter()
        .rev()
        .take(7)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parses_both_exchanges_without_inventing_zero_prices() {
        let (p, change) = parse_stats("coinbase", &json!({"last":"120", "open":"100"})).unwrap();
        assert_eq!(p, 120.0);
        assert!((change.unwrap() - 20.0).abs() < 0.00001);
        assert!(parse_stats("coinbase", &json!({"last":"NaN"})).is_err());
        assert!(parse_stats("okx", &json!({"code":"500", "data":[{"last":"100"}]})).is_err());
        assert_eq!(
            parse_stats(
                "okx",
                &json!({"code":"0", "data":[{"last":"100", "open24h":"0"}]})
            )
            .unwrap(),
            (100.0, None)
        );
        assert_eq!(quote_currency("okx", "USD"), "USDT");
    }
    #[test]
    fn history_is_chronological_deduplicated_and_bounded() {
        let data = json!([
            [20, 0, 0, 0, 2],
            [30, 0, 0, 0, 3],
            [10, 0, 0, 0, 1],
            [20, 0, 0, 0, 2],
            [40, 0, 0, 0, "NaN"]
        ]);
        assert_eq!(parse_history("coinbase", &data).unwrap(), [1.0, 2.0, 3.0]);
        assert_eq!(
            parse_history("okx", &json!({"code":"0","data":data})).unwrap(),
            [1.0, 2.0, 3.0]
        );
        assert!(parse_history("coinbase", &json!([])).is_err());
    }
    #[tokio::test]
    #[ignore = "Live public market APIs; no account or credentials"]
    async fn public_quote_live() {
        let http = client().unwrap();
        for exchange in ["coinbase", "okx"] {
            let quote = fetch(&http, exchange, "USD", "BTC", true).await.unwrap();
            assert!(quote.price.unwrap() > 0.0);
            assert!(quote.history.len() >= 2, "{exchange}: {:?}", quote.error);
        }
    }
}
