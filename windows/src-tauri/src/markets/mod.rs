// Read-only market integrations. Nothing is requested until its pill is enabled.
pub mod portfolio;
mod quotes;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Mutex, OnceLock,
};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::AppHandle;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Network {
    coinbase: String,
    okx: String,
    pub poll_seconds: u64,
    history_seconds: u64,
    timeout_seconds: u64,
    request_spacing_ms: u64,
    max_response_bytes: usize,
    max_coins: usize,
    history_points: usize,
}

pub fn network() -> &'static Network {
    static CONFIG: OnceLock<Network> = OnceLock::new();
    CONFIG.get_or_init(|| {
        serde_json::from_str(include_str!("defaults.json")).expect("market defaults")
    })
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct Prefs {
    pub exchange: String,
    pub currency: String,
    pub coins: Vec<String>,
    pub alerts: bool,
    pub alert_percent: f64,
}

impl Default for Prefs {
    fn default() -> Self {
        Self {
            exchange: "coinbase".into(),
            currency: "EUR".into(),
            coins: ["BTC", "ETH", "SOL"].map(String::from).to_vec(),
            alerts: false,
            alert_percent: 5.0,
        }
    }
}

impl Prefs {
    fn validate(mut self) -> Result<Self, String> {
        if !matches!(self.exchange.as_str(), "coinbase" | "okx")
            || !matches!(self.currency.as_str(), "EUR" | "USD")
        {
            return Err("Invalid exchange or currency".into());
        }
        if self.coins.len() > network().max_coins
            || !self.alert_percent.is_finite()
            || !(0.1..=100.0).contains(&self.alert_percent)
        {
            return Err("Invalid coin count or alert threshold".into());
        }
        let mut coins = Vec::new();
        for coin in &self.coins {
            let coin = coin.trim().to_ascii_uppercase();
            if coin.is_empty()
                || coin.len() > 15
                || !coin.bytes().all(|b| b.is_ascii_alphanumeric())
            {
                return Err("Invalid coin symbol".into());
            }
            if !coins.contains(&coin) {
                coins.push(coin);
            }
        }
        self.coins = coins;
        Ok(self)
    }
}

static WRITE: Mutex<()> = Mutex::new(());
static REVISION: AtomicU64 = AtomicU64::new(0);

fn path() -> std::path::PathBuf {
    crate::platform::config_dir().join("markets.json")
}

#[tauri::command]
pub fn markets_prefs() -> Result<Prefs, String> {
    let _guard = WRITE.lock().unwrap();
    match std::fs::read(path()) {
        Ok(bytes) => serde_json::from_slice::<Prefs>(&bytes)
            .map_err(|_| "Cannot read markets.json".to_string())?
            .validate(),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Prefs::default()),
        Err(_) => Err("Cannot read markets.json".into()),
    }
}

#[tauri::command]
pub fn markets_save(app: AppHandle, prefs: Prefs) -> Result<Prefs, String> {
    let prefs = prefs.validate()?;
    {
        let _guard = WRITE.lock().unwrap();
        let path = path();
        let temp = path.with_extension("json.tmp");
        let result = crate::platform::ensure_private_dir(path.parent().unwrap())
            .and_then(|()| serde_json::to_vec_pretty(&prefs).map_err(std::io::Error::other))
            .and_then(|bytes| std::fs::write(&temp, bytes))
            .and_then(|()| std::fs::rename(&temp, &path));
        if result.is_err() {
            let _ = std::fs::remove_file(&temp);
            return Err("Cannot save markets.json".into());
        }
        REVISION.fetch_add(1, Ordering::SeqCst);
    }
    crate::integrations::emit(
        &app,
        crate::integrations::IntegrationUpdate {
            id: "integration_crypto",
            data: serde_json::json!({}),
            error: None,
            event: None,
        },
    );
    tauri::async_runtime::spawn(quotes::poll(app));
    Ok(prefs)
}

pub async fn poll(app: AppHandle) {
    quotes::poll(app).await;
}

pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

pub fn client() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .timeout(Duration::from_secs(network().timeout_seconds))
        .redirect(reqwest::redirect::Policy::none())
        .user_agent(concat!("Coucou/", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|_| "Cannot create network client".into())
}

pub async fn json(request: reqwest::RequestBuilder) -> Result<Value, String> {
    let mut response = request
        .send()
        .await
        .map_err(|_| "Network request failed".to_string())?;
    if !response.status().is_success() {
        return Err(format!("HTTP {}", response.status().as_u16()));
    }
    if response.content_length().unwrap_or(0) > network().max_response_bytes as u64 {
        return Err("Response too large".into());
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| "Incomplete response".to_string())?
    {
        if bytes.len() + chunk.len() > network().max_response_bytes {
            return Err("Response too large".into());
        }
        bytes.extend_from_slice(&chunk);
    }
    serde_json::from_slice(&bytes).map_err(|_| "Invalid response".into())
}

pub fn number(value: &Value) -> Option<f64> {
    value
        .as_f64()
        .or_else(|| value.as_str()?.parse().ok())
        .filter(|n| n.is_finite())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn symbols_cannot_inject_request_paths_and_bad_prefs_are_rejected() {
        for symbol in ["BTC/../accounts", "BTC?x=1", "", "A B", "BTC&x"] {
            assert!(Prefs {
                coins: vec![symbol.into()],
                ..Prefs::default()
            }
            .validate()
            .is_err());
        }
        assert_eq!(
            Prefs {
                coins: vec![" btc ".into(), "BTC".into()],
                ..Prefs::default()
            }
            .validate()
            .unwrap()
            .coins,
            ["BTC"]
        );
        assert!(Prefs {
            alert_percent: f64::NAN,
            ..Prefs::default()
        }
        .validate()
        .is_err());
        assert!(Prefs {
            coins: vec!["BTC".into(); 9],
            ..Prefs::default()
        }
        .validate()
        .is_err());
        assert!(number(&serde_json::json!("NaN")).is_none());
    }
}
