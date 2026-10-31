use super::signatures as sign;
use super::*;
use std::collections::HashSet;

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Credentials {
    pub key: String,
    pub secret: String,
    #[serde(default)]
    pub passphrase: String,
}

pub fn validate_credentials(exchange: &str, c: &Credentials) -> Result<(), String> {
    if !config().exchanges.contains_key(exchange)
        || c.key.trim().is_empty()
        || c.secret.trim().is_empty()
        || c.key.len() > 512
        || c.secret.len() > 8192
        || c.passphrase.len() > 512
        || c.key.chars().any(char::is_control)
        || c.passphrase.chars().any(char::is_control)
    {
        return Err("Invalid exchange credentials".into());
    }
    if exchange == "okx" && c.passphrase.is_empty() {
        return Err("A passphrase is required".into());
    }
    if exchange == "coinbase" {
        sign::signing_key(&c.secret)?;
    } else if c.secret.chars().any(char::is_control) {
        return Err("Invalid exchange secret".into());
    }
    if exchange == "kraken" {
        sign::decode(&c.secret)?;
    }
    Ok(())
}

fn credential_key(exchange: &str) -> Result<String, String> {
    if !config().exchanges.contains_key(exchange) {
        return Err("Unknown exchange".into());
    }
    Ok(format!("portfolio-{exchange}"))
}

pub fn connected(exchange: &str) -> Result<bool, String> {
    Ok(crate::secrets::read_internal(&credential_key(exchange)?)?.is_some())
}

pub fn save(exchange: &str, credentials: Credentials) -> Result<(), String> {
    validate_credentials(exchange, &credentials)?;
    crate::secrets::set_internal(
        &credential_key(exchange)?,
        &serde_json::to_string(&credentials).map_err(|_| "Cannot encode credentials")?,
    )
}

pub fn remove(exchange: &str) -> Result<(), String> {
    crate::secrets::set_internal(&credential_key(exchange)?, "")
}

static NONCE: AtomicU64 = AtomicU64::new(0);
fn nonce() -> String {
    let now = now_ms().saturating_mul(1000);
    let mut previous = NONCE.load(Ordering::SeqCst);
    loop {
        let next = now.max(previous.saturating_add(1));
        match NONCE.compare_exchange(previous, next, Ordering::SeqCst, Ordering::SeqCst) {
            Ok(_) => return next.to_string(),
            Err(current) => previous = current,
        }
    }
}

pub async fn fetch(http: &reqwest::Client, exchange: &str) -> Result<Vec<Holding>, String> {
    let stored = crate::secrets::read_internal(&credential_key(exchange)?)?
        .ok_or("Credentials unavailable")?;
    let credentials: Credentials =
        serde_json::from_str(&stored).map_err(|_| "Invalid stored credentials")?;
    validate_credentials(exchange, &credentials)?;
    fetch_with(http, exchange, &credentials).await
}

pub(super) async fn fetch_with(
    http: &reqwest::Client,
    exchange: &str,
    c: &Credentials,
) -> Result<Vec<Holding>, String> {
    let base = config().exchanges.get(exchange).ok_or("Unknown exchange")?;
    let timestamp = now_ms().to_string();
    let receive = config().receive_window_ms.to_string();
    let value = match exchange {
        "binance" => {
            let query = format!("recvWindow={receive}&timestamp={timestamp}");
            json(
                http.get(format!(
                    "{base}/api/v3/account?{query}&signature={}",
                    sign::sha256_hex(&c.secret, &query)
                ))
                .header("X-MBX-APIKEY", &c.key),
            )
            .await?
        }
        "okx" => {
            let timestamp = crate::whatsapp::gateway::iso_utc(now_ms() as i64);
            let timestamp = format!("{}.000Z", timestamp.trim_end_matches('Z'));
            let path = "/api/v5/account/balance";
            json(
                http.get(format!("{base}{path}"))
                    .header("OK-ACCESS-KEY", &c.key)
                    .header("OK-ACCESS-TIMESTAMP", &timestamp)
                    .header("OK-ACCESS-PASSPHRASE", &c.passphrase)
                    .header(
                        "OK-ACCESS-SIGN",
                        sign::sha256_base64(&c.secret, &format!("{timestamp}GET{path}")),
                    ),
            )
            .await?
        }
        "bybit" => {
            let query = "accountType=UNIFIED";
            let signature =
                sign::sha256_hex(&c.secret, &format!("{timestamp}{}{receive}{query}", c.key));
            json(
                http.get(format!("{base}/v5/account/wallet-balance?{query}"))
                    .header("X-BAPI-API-KEY", &c.key)
                    .header("X-BAPI-TIMESTAMP", &timestamp)
                    .header("X-BAPI-RECV-WINDOW", &receive)
                    .header("X-BAPI-SIGN", signature),
            )
            .await?
        }
        "kraken" => {
            let nonce = nonce();
            let body = format!("nonce={nonce}");
            let path = "/0/private/Balance";
            json(
                http.post(format!("{base}{path}"))
                    .header("API-Key", &c.key)
                    .header("API-Sign", sign::kraken(&c.secret, path, &nonce, &body)?)
                    .header("Content-Type", "application/x-www-form-urlencoded")
                    .body(body),
            )
            .await?
        }
        "coinbase" => return coinbase(http, base, c).await,
        _ => return Err("Unknown exchange".into()),
    };
    parse(exchange, &value)
}

fn required(value: &Value) -> Result<f64, String> {
    number(value).ok_or_else(|| "Invalid balance response".into())
}
fn optional(value: &Value) -> Result<f64, String> {
    if value.is_null() || value.as_str() == Some("") {
        Ok(0.0)
    } else {
        required(value)
    }
}
fn array(value: &Value) -> Result<&Vec<Value>, String> {
    value
        .as_array()
        .ok_or_else(|| "Invalid balance response".into())
}

fn parse(exchange: &str, value: &Value) -> Result<Vec<Holding>, String> {
    let mut balances = BTreeMap::new();
    match exchange {
        "binance" => {
            for row in array(&value["balances"])? {
                add(
                    &mut balances,
                    row["asset"].as_str().ok_or("Missing currency")?,
                    required(&row["free"])? + required(&row["locked"])?,
                )?;
            }
        }
        "okx" => {
            if value["code"].as_str() != Some("0") {
                return Err("Exchange rejected balance request".into());
            }
            for row in array(&value["data"][0]["details"])? {
                add(
                    &mut balances,
                    row["ccy"].as_str().ok_or("Missing currency")?,
                    required(&row["cashBal"])? - optional(&row["liab"])?,
                )?;
            }
        }
        "bybit" => {
            if value["retCode"].as_i64() != Some(0) {
                return Err("Exchange rejected balance request".into());
            }
            for account in array(&value["result"]["list"])? {
                for row in array(&account["coin"])? {
                    add(
                        &mut balances,
                        row["coin"].as_str().ok_or("Missing currency")?,
                        required(&row["walletBalance"])? - optional(&row["spotBorrow"])?,
                    )?;
                }
            }
        }
        "kraken" => {
            if !array(&value["error"])?.is_empty() {
                return Err("Exchange rejected balance request".into());
            }
            for (symbol, amount) in value["result"]
                .as_object()
                .ok_or("Invalid balance response")?
            {
                add(&mut balances, kraken_symbol(symbol), required(amount)?)?;
            }
        }
        _ => return Err("Unknown exchange".into()),
    }
    holdings(balances)
}

fn kraken_symbol(symbol: &str) -> &str {
    let symbol = symbol
        .strip_suffix(".S")
        .or_else(|| symbol.strip_suffix(".F"))
        .unwrap_or(symbol);
    match symbol {
        "XXBT" | "XBT" => "BTC",
        "XETH" => "ETH",
        "XLTC" => "LTC",
        "XXRP" => "XRP",
        "XXDG" | "XDG" => "DOGE",
        "XXLM" => "XLM",
        "XETC" => "ETC",
        "ZUSD" => "USD",
        "ZEUR" => "EUR",
        "ZGBP" => "GBP",
        "ZCAD" => "CAD",
        "ZJPY" => "JPY",
        "ZAUD" => "AUD",
        _ => symbol,
    }
}

fn add(balances: &mut BTreeMap<String, f64>, symbol: &str, amount: f64) -> Result<(), String> {
    if symbol.is_empty()
        || symbol.len() > 32
        || !symbol
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
        || !amount.is_finite()
    {
        return Err("Invalid balance response".into());
    }
    let balance = balances.entry(symbol.to_ascii_uppercase()).or_default();
    *balance += amount;
    if !balance.is_finite() {
        return Err("Invalid balance response".into());
    }
    if balances.len() > config().max_holdings {
        return Err("Too many holdings to display".into());
    }
    Ok(())
}

fn holdings(balances: BTreeMap<String, f64>) -> Result<Vec<Holding>, String> {
    Ok(balances
        .into_iter()
        .filter(|(_, amount)| *amount != 0.0)
        .map(|(symbol, amount)| Holding::new(symbol, amount))
        .collect())
}

fn coinbase_page(
    value: &Value,
    balances: &mut BTreeMap<String, f64>,
    ids: &mut HashSet<String>,
) -> Result<Option<String>, String> {
    for row in array(&value["accounts"])? {
        let id = row["uuid"].as_str().ok_or("Missing account identifier")?;
        if !ids.insert(id.into()) {
            return Err("Repeated account in paginated response".into());
        }
        add(
            balances,
            row["currency"].as_str().ok_or("Missing currency")?,
            required(&row["available_balance"]["value"])? + required(&row["hold"]["value"])?,
        )?;
    }
    if value["has_next"]
        .as_bool()
        .ok_or("Missing pagination status")?
    {
        let cursor = value["cursor"]
            .as_str()
            .filter(|s| !s.is_empty() && s.len() <= 2048)
            .ok_or("Incomplete account pagination")?;
        Ok(Some(cursor.into()))
    } else {
        Ok(None)
    }
}

async fn coinbase(
    http: &reqwest::Client,
    base: &str,
    c: &Credentials,
) -> Result<Vec<Holding>, String> {
    let mut balances = BTreeMap::new();
    let mut ids = HashSet::new();
    let mut cursors = HashSet::new();
    let mut cursor = None;
    let host = reqwest::Url::parse(base)
        .ok()
        .and_then(|u| u.host_str().map(String::from))
        .ok_or("Invalid exchange origin")?;
    let path = "/api/v3/brokerage/accounts";
    for _ in 0..config().max_pages {
        let token = sign::coinbase(&c.key, &c.secret, &host, path, now_ms() / 1000)?;
        let mut request = http
            .get(format!("{base}{path}"))
            .query(&[("limit", "250")])
            .bearer_auth(token);
        if let Some(cursor) = cursor {
            request = request.query(&[("cursor", cursor)]);
        }
        let value = json(request).await?;
        cursor = coinbase_page(&value, &mut balances, &mut ids)?;
        match &cursor {
            None => return holdings(balances),
            Some(cursor) if !cursors.insert(cursor.clone()) => {
                return Err("Repeated pagination cursor".into())
            }
            Some(_) => {
                tokio::time::sleep(Duration::from_millis(
                    super::super::network().request_spacing_ms,
                ))
                .await
            }
        }
    }
    Err("Incomplete account pagination".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn balances_include_locked_funds_and_preserve_borrowed_liabilities() {
        assert_eq!(
            parse(
                "binance",
                &json!({"balances":[{"asset":"BTC","free":"1","locked":"2"}]})
            )
            .unwrap()[0]
                .amount,
            3.0
        );
        assert_eq!(
            parse(
                "okx",
                &json!({"code":"0","data":[{"details":[{"ccy":"BTC","cashBal":"3","liab":"1"}]}]})
            )
            .unwrap()[0]
                .amount,
            2.0
        );
        assert_eq!(parse("bybit", &json!({"retCode":0,"result":{"list":[{"coin":[{"coin":"ETH","walletBalance":"1","spotBorrow":"2"}]}]}})).unwrap()[0].amount, -1.0);
        assert!(parse("okx", &json!({"code":"500","data":[]})).is_err());
        assert!(parse("kraken", &json!({"error":["bad nonce"],"result":{}})).is_err());
        assert!(parse(
            "binance",
            &json!({"balances":[{"asset":"BTC","free":"bad","locked":"2"}]})
        )
        .is_err());
    }
    #[test]
    fn kraken_preserves_real_asset_symbols() {
        let rows = parse(
            "kraken",
            &json!({"error":[],"result":{"XXBT":"1","XBT.F":"2","ZRX":"4","XLM":"5","ZUSD":"6"}}),
        )
        .unwrap();
        assert_eq!(rows.iter().find(|r| r.symbol == "BTC").unwrap().amount, 3.0);
        assert!(rows.iter().any(|r| r.symbol == "ZRX"));
        assert!(rows.iter().any(|r| r.symbol == "XLM"));
        assert!(nonce().parse::<u64>().unwrap() < nonce().parse::<u64>().unwrap());
    }
    #[test]
    fn coinbase_pagination_requires_continuation_and_never_counts_an_account_twice() {
        let mut balances = BTreeMap::new();
        let mut ids = HashSet::new();
        let page = json!({"accounts":[{"uuid":"one","currency":"ETH","available_balance":{"value":"1"},"hold":{"value":"2"}}],"has_next":true,"cursor":"next"});
        assert_eq!(
            coinbase_page(&page, &mut balances, &mut ids)
                .unwrap()
                .as_deref(),
            Some("next")
        );
        assert_eq!(balances["ETH"], 3.0);
        assert!(coinbase_page(&page, &mut balances, &mut ids).is_err());
        assert!(coinbase_page(
            &json!({"accounts":[],"has_next":true}),
            &mut balances,
            &mut ids
        )
        .is_err());
    }
}
