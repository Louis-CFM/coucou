use super::*;
use serde_json::json;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Wallet {
    pub kind: String,
    pub address: String,
    pub label: String,
}

impl Wallet {
    pub fn id(&self) -> String {
        format!("{}:{}", self.kind, self.address)
    }
    pub fn validate(mut self) -> Result<Self, String> {
        let def = config()
            .wallets
            .get(&self.kind)
            .ok_or("Unknown wallet network")?;
        self.address = self.address.trim().to_string();
        self.label = self.label.trim().to_string();
        let a = self.address.as_str();
        if a.is_empty()
            || a.len() > 128
            || !a
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
            || self.label.len() > 120
            || self.label.chars().any(char::is_control)
        {
            return Err("Invalid wallet address or label".into());
        }
        let base58 = || {
            a.bytes()
                .all(|b| b"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".contains(&b))
        };
        let plausible = match def.protocol.as_str() {
            "evm" => {
                a.starts_with("0x")
                    && a.len() == 42
                    && a[2..].bytes().all(|b| b.is_ascii_hexdigit())
            }
            "bitcoin" => {
                (a.to_ascii_lowercase().starts_with("bc1") && (14..=90).contains(&a.len()))
                    || (a.starts_with(['1', '3']) && (25..=34).contains(&a.len()) && base58())
            }
            "blockchair" if self.kind == "dogecoin" => {
                a.starts_with(['D', 'A']) && (25..=34).contains(&a.len()) && base58()
            }
            "blockchair" => {
                (a.to_ascii_lowercase().starts_with("ltc1") && (26..=90).contains(&a.len()))
                    || (a.starts_with(['L', 'M', '3']) && (25..=34).contains(&a.len()) && base58())
            }
            "solana" => (32..=44).contains(&a.len()) && base58(),
            "tron" => a.starts_with('T') && a.len() == 34 && base58(),
            "xrp" => a.starts_with('r') && (25..=35).contains(&a.len()) && base58(),
            "cardano" => a.to_ascii_lowercase().starts_with("addr1") && a.len() >= 50,
            "cosmos" => a.to_ascii_lowercase().starts_with("cosmos1") && a.len() == 45,
            "near" => {
                (2..=64).contains(&a.len())
                    && a.bytes().all(|b| {
                        b.is_ascii_lowercase() || b.is_ascii_digit() || b"._-".contains(&b)
                    })
                    && !a.starts_with(['.', '_', '-'])
                    && !a.ends_with(['.', '_', '-'])
                    && !a
                        .as_bytes()
                        .windows(2)
                        .any(|w| b"._-".contains(&w[0]) && b"._-".contains(&w[1]))
            }
            _ => false,
        };
        if !plausible {
            return Err("Invalid wallet address for this network".into());
        }
        let bech32 = ["bc1", "ltc1", "addr1", "cosmos1"]
            .iter()
            .any(|p| a.to_ascii_lowercase().starts_with(p));
        if bech32 && a != a.to_ascii_lowercase() && a != a.to_ascii_uppercase() {
            return Err("Invalid mixed-case wallet address".into());
        }
        if def.protocol == "evm" || bech32 {
            self.address.make_ascii_lowercase();
        }
        Ok(self)
    }
}

pub async fn fetch(http: &reqwest::Client, wallet: &Wallet) -> Result<Vec<Holding>, String> {
    let def = config()
        .wallets
        .get(&wallet.kind)
        .ok_or("Unknown wallet network")?;
    let address = &wallet.address;
    let rpc = |method: &str, params: Value| {
        http.post(&def.url)
            .json(&json!({"jsonrpc":"2.0", "id":1, "method":method, "params":params}))
    };
    let request = match def.protocol.as_str() {
        "bitcoin" => http.get(&def.url).query(&[("active", address)]),
        "blockchair" | "tron" => http.get(format!("{}{address}", def.url)),
        "evm" => rpc("eth_getBalance", json!([address, "latest"])),
        "solana" => rpc("getBalance", json!([address, {"commitment":"finalized"}])),
        "xrp" => rpc(
            "account_info",
            json!([{"account":address, "ledger_index":"validated"}]),
        ),
        "near" => rpc(
            "query",
            json!({"request_type":"view_account", "finality":"final", "account_id":address}),
        ),
        "cardano" => http.post(&def.url).json(&json!({"_addresses":[address]})),
        "cosmos" => return cosmos(http, wallet, def).await,
        _ => return Err("Unknown wallet protocol".into()),
    };
    let value = json(request).await?;
    let balance = parse(&def.protocol, address, &value)? / def.scale;
    if !balance.is_finite() || balance < 0.0 {
        return Err("Invalid wallet balance".into());
    }
    Ok(vec![Holding::new(def.symbol.clone(), balance)])
}

fn parse(protocol: &str, address: &str, value: &Value) -> Result<f64, String> {
    if value.get("error").is_some_and(|e| !e.is_null()) || value["result"].get("error").is_some() {
        return Err("Wallet service rejected the request".into());
    }
    let balance = match protocol {
        "bitcoin" => &value[address]["final_balance"],
        "blockchair" => &value["data"][address]["address"]["balance"],
        "evm" => {
            let hex = value["result"]
                .as_str()
                .and_then(|s| s.strip_prefix("0x"))
                .filter(|s| !s.is_empty() && s.len() <= 64)
                .ok_or("Invalid wallet balance")?;
            let mut n = 0.0;
            for c in hex.chars() {
                n = n * 16.0 + c.to_digit(16).ok_or("Invalid wallet balance")? as f64;
            }
            return Ok(n);
        }
        "solana" => &value["result"]["value"],
        "tron" => {
            if value["success"].as_bool() != Some(true) {
                return Err("Wallet service rejected the request".into());
            }
            let rows = value["data"].as_array().ok_or("Invalid wallet balance")?;
            if rows.is_empty() {
                return Ok(0.0);
            }
            // TRON omits the field for a valid account whose native balance is zero.
            if rows[0].get("balance").is_none() && rows[0].get("address").is_some() {
                return Ok(0.0);
            }
            &rows[0]["balance"]
        }
        "xrp" => &value["result"]["account_data"]["Balance"],
        "cardano" => {
            let rows = value.as_array().ok_or("Invalid wallet balance")?;
            if rows.is_empty() {
                return Ok(0.0);
            }
            &rows[0]["balance"]
        }
        "near" => &value["result"]["amount"],
        _ => return Err("Unknown wallet protocol".into()),
    };
    number(balance)
        .filter(|n| *n >= 0.0)
        .ok_or_else(|| "Invalid wallet balance".into())
}

async fn cosmos(
    http: &reqwest::Client,
    wallet: &Wallet,
    def: &WalletNetwork,
) -> Result<Vec<Holding>, String> {
    let url = format!("{}{}", def.url, wallet.address);
    let mut next = String::new();
    let mut seen = std::collections::HashSet::new();
    for _ in 0..config().max_pages {
        let mut request = http.get(&url).query(&[("pagination.limit", "100")]);
        if !next.is_empty() {
            request = request.query(&[("pagination.key", &next)]);
        }
        let response = json(request).await?;
        let balances = response["balances"]
            .as_array()
            .ok_or("Invalid wallet balance")?;
        if let Some(row) = balances
            .iter()
            .find(|b| b["denom"].as_str() == Some("uatom"))
        {
            let amount = number(&row["amount"])
                .filter(|n| *n >= 0.0)
                .ok_or("Invalid wallet balance")?
                / def.scale;
            return Ok(vec![Holding::new(def.symbol.clone(), amount)]);
        }
        let pagination = response["pagination"]
            .as_object()
            .ok_or("Missing wallet pagination")?;
        match pagination
            .get("next_key")
            .ok_or("Missing wallet pagination")?
        {
            Value::Null => return Ok(vec![Holding::new(def.symbol.clone(), 0.0)]),
            Value::String(key) if key.is_empty() => {
                return Ok(vec![Holding::new(def.symbol.clone(), 0.0)])
            }
            Value::String(key) if key.len() <= 2048 && seen.insert(key.clone()) => {
                next = key.clone()
            }
            _ => return Err("Incomplete wallet pagination".into()),
        }
    }
    Err("Incomplete wallet pagination".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn addresses_are_bounded_and_identity_includes_the_network() {
        let a = "0x0000000000000000000000000000000000000000";
        let eth = Wallet {
            kind: "ethereum".into(),
            address: a.into(),
            label: String::new(),
        }
        .validate()
        .unwrap();
        let base = Wallet {
            kind: "base".into(),
            ..eth.clone()
        }
        .validate()
        .unwrap();
        assert_ne!(eth.id(), base.id());
        for a in ["../../key", "0x123", "x?active=other", "a\nb"] {
            assert!(Wallet {
                kind: "ethereum".into(),
                address: a.into(),
                label: String::new()
            }
            .validate()
            .is_err());
        }
        assert_eq!(config().wallets.len(), 16);
    }
    #[test]
    fn invalid_native_balances_are_never_treated_as_zero() {
        assert_eq!(
            parse("evm", "a", &json!({"result":"0xde0b6b3a7640000"})).unwrap() / 1e18,
            1.0
        );
        assert_eq!(
            parse(
                "near",
                "a",
                &json!({"result":{"amount":"1000000000000000000000000"}})
            )
            .unwrap()
                / 1e24,
            1.0
        );
        assert!(parse("near", "a", &json!({"result":{"amount":"12bad"}})).is_err());
        assert!(parse("tron", "a", &json!({"success":false,"data":[]})).is_err());
        assert!(parse("cardano", "a", &json!([{"balance":"oops"}])).is_err());
        assert_eq!(
            parse("tron", "a", &json!({"success":true,"data":[]})).unwrap(),
            0.0
        );
        assert!(parse("evm", "a", &json!({"error":{"message":"rate limited"}})).is_err());
    }

    #[test]
    fn each_native_response_uses_the_balance_field_for_that_protocol() {
        for (protocol, response) in [
            ("bitcoin", json!({"a":{"final_balance":100}})),
            (
                "blockchair",
                json!({"data":{"a":{"address":{"balance":100}}}}),
            ),
            ("solana", json!({"result":{"value":100}})),
            ("tron", json!({"success":true,"data":[{"balance":100}]})),
            ("xrp", json!({"result":{"account_data":{"Balance":"100"}}})),
            ("cardano", json!([{"balance":"100"}])),
        ] {
            assert_eq!(
                parse(protocol, "a", &response).unwrap(),
                100.0,
                "{protocol}"
            );
        }
    }

    #[tokio::test]
    #[ignore = "Live public RPCs with protocol-owned or zero addresses; no user wallets"]
    async fn public_native_wallets_live() {
        let http = client().unwrap();
        for kind in [
            "ethereum",
            "polygon",
            "bnbChain",
            "avalanche",
            "arbitrum",
            "optimism",
            "base",
            "solana",
            "near",
        ] {
            let address = match kind {
                "solana" => "11111111111111111111111111111111",
                "near" => "near",
                _ => "0x0000000000000000000000000000000000000000",
            };
            let wallet = Wallet {
                kind: kind.into(),
                address: address.into(),
                label: String::new(),
            }
            .validate()
            .unwrap();
            let result = fetch(&http, &wallet).await;
            assert!(
                result.is_ok(),
                "{kind}: {}",
                result.err().unwrap_or_default()
            );
        }
    }
}
