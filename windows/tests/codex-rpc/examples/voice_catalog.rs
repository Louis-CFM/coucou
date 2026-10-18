//! Read-only discovery. Does not start a voice session or submit audio/text.
use coucou_codex_rpc_tests::Client;
use serde_json::json;
use std::{path::PathBuf, time::Duration};

fn main() -> Result<(), String> {
    let exe = std::env::args_os().nth(1).map(PathBuf::from).ok_or("Pass the Codex executable path.")?;
    let mut client = Client::start(&exe, &std::env::temp_dir(), Duration::from_secs(30), true)?;
    let account = client.request("account/read", json!({"refreshToken":false}))?;
    println!("Account type: {}; plan: {}", account["account"]["type"], account["account"]["planType"]);
    let voices = client.request("thread/realtime/listVoices", json!({}))?;
    println!("Native voice catalog: {}", voices);
    if let Ok(features) = client.request("experimentalFeature/list", json!({"limit":100})) {
        if let Some(flags) = features["data"].as_array() {
            for flag in flags {
                let name = flag["name"].as_str().unwrap_or("");
                if name.contains("realtime") || name.contains("voice") {
                    println!("Feature: {}", json!({"name":name,"stage":flag["stage"],"enabled":flag["enabled"]}));
                }
            }
        }
    }
    Ok(())
}
