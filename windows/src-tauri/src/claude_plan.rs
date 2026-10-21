// Claude plan usage from the Claude desktop app. Its Code tab never runs Claude
// Code's status line, so the relay hears no `rate_limits` there; but the app
// keeps its own record of the plan's use, `plan-usage-history.json`, sampled
// while it runs: `fh` is the 5-hour window and `sd` the week, in percent.
// Only the newest sample is read; nothing is written, nothing goes anywhere.
//
// The app writes that record now and then, sometimes hours apart. The live
// numbers come from Anthropic's usage endpoint instead, asked with Claude Code's
// own sign-in (`claude`, then /login, keeps it in ~/.claude/.credentials.json),
// as Claude Code itself does. The token is only read: never refreshed, written
// or sent anywhere else. Once it expires (Claude Code renews it when it runs)
// the app's record is used again.

use std::path::PathBuf;
use std::time::Duration;

use serde::Serialize;
use serde_json::Value;

#[derive(Serialize, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DesktopPlan {
    /// When the Claude app took the sample (epoch ms).
    pub at: f64,
    pub five_hour: Option<f64>,
    pub seven_day: Option<f64>,
}

/// Where the Claude app keeps the file: one folder per Windows account in
/// `%LOCALAPPDATA%\Claude-Data`, or `%APPDATA%\Claude` for older installs.
fn candidates() -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Some(local) = std::env::var_os("LOCALAPPDATA") {
        let base = PathBuf::from(local).join("Claude-Data");
        if let Ok(dirs) = std::fs::read_dir(&base) {
            for d in dirs.flatten() {
                out.push(d.path().join("plan-usage-history.json"));
            }
        }
    }
    if let Some(roaming) = std::env::var_os("APPDATA") {
        out.push(PathBuf::from(roaming).join("Claude").join("plan-usage-history.json"));
    }
    out
}

fn percent(v: Option<&Value>) -> Option<f64> {
    v.and_then(Value::as_f64).filter(|p| (0.0..=200.0).contains(p)).map(|p| p.min(100.0))
}

/// The newest sample that holds a number.
pub fn latest(json: &Value) -> Option<DesktopPlan> {
    json.get("samples")?
        .as_array()?
        .iter()
        .filter_map(|s| {
            let at = s.get("t")?.as_f64()?;
            let u = s.get("u")?;
            let plan = DesktopPlan { at, five_hour: percent(u.get("fh")), seven_day: percent(u.get("sd")) };
            (plan.five_hour.is_some() || plan.seven_day.is_some()).then_some(plan)
        })
        .max_by(|a, b| a.at.total_cmp(&b.at))
}

#[tauri::command]
pub fn claude_desktop_plan() -> Option<DesktopPlan> {
    candidates()
        .into_iter()
        .filter_map(|p| {
            // A file the Claude app writes, a few hundred samples: never anything large.
            let meta = std::fs::metadata(&p).ok()?;
            if meta.len() > 8 * 1024 * 1024 {
                return None;
            }
            let json: Value = serde_json::from_slice(&std::fs::read(&p).ok()?).ok()?;
            latest(&json)
        })
        .max_by(|a, b| a.at.total_cmp(&b.at))
}

/// Anthropic's answer: percent used of each window, and when it resets (RFC 3339).
#[derive(Serialize, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct LivePlan {
    pub five_hour: Option<f64>,
    pub seven_day: Option<f64>,
    pub five_hour_resets_at: Option<String>,
    pub seven_day_resets_at: Option<String>,
}

/// Claude Code's sign-in, while it is valid for another minute at least.
fn claude_code_token() -> Option<String> {
    let dir = match std::env::var_os("CLAUDE_CONFIG_DIR") {
        Some(d) => PathBuf::from(d),
        None => PathBuf::from(std::env::var_os("USERPROFILE").or_else(|| std::env::var_os("HOME"))?).join(".claude"),
    };
    let file = dir.join(".credentials.json");
    if std::fs::metadata(&file).ok()?.len() > 1024 * 1024 {
        return None;
    }
    let json: Value = serde_json::from_slice(&std::fs::read(&file).ok()?).ok()?;
    let oauth = json.get("claudeAiOauth")?;
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).ok()?.as_millis() as f64;
    if oauth.get("expiresAt").and_then(Value::as_f64).is_some_and(|at| at < now + 60_000.0) {
        return None;
    }
    oauth.get("accessToken")?.as_str().filter(|t| !t.is_empty()).map(str::to_string)
}

/// The endpoint's answer, read: a window without a number is left out.
pub fn parse_live(json: &Value) -> Option<LivePlan> {
    let window = |key: &str| json.get(key).filter(|w| w.is_object());
    let used = |key: &str| percent(window(key).and_then(|w| w.get("utilization")));
    let resets = |key: &str| window(key).and_then(|w| w.get("resets_at")).and_then(Value::as_str).map(str::to_string);
    let plan = LivePlan {
        five_hour: used("five_hour"),
        seven_day: used("seven_day"),
        five_hour_resets_at: resets("five_hour"),
        seven_day_resets_at: resets("seven_day"),
    };
    (plan.five_hour.is_some() || plan.seven_day.is_some()).then_some(plan)
}

/// The plan's use right now, or None: no Claude Code sign-in, expired, offline.
#[tauri::command]
pub async fn claude_live_plan() -> Option<LivePlan> {
    let token = claude_code_token()?;
    let client = reqwest::Client::builder().timeout(Duration::from_secs(8)).build().ok()?;
    let res = client
        .get("https://api.anthropic.com/api/oauth/usage")
        .bearer_auth(token)
        .header("anthropic-beta", "oauth-2025-04-20")
        .header("User-Agent", concat!("coucou/", env!("CARGO_PKG_VERSION")))
        .send()
        .await
        .ok()?;
    if !res.status().is_success() {
        return None;
    }
    parse_live(&res.json::<Value>().await.ok()?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn the_newest_sample_with_numbers_wins() {
        let file = json!({ "version": 2, "samples": [
            { "t": 1.0, "org": "a", "u": { "fh": 10, "sd": 20 } },
            { "t": 3.0, "org": "a", "u": {} },
            { "t": 2.0, "org": "a", "u": { "fh": 0, "sd": 68 } },
        ]});
        assert_eq!(latest(&file), Some(DesktopPlan { at: 2.0, five_hour: Some(0.0), seven_day: Some(68.0) }));
    }

    #[test]
    fn the_live_answer_is_read_window_by_window() {
        let live = parse_live(&json!({
            "five_hour": { "utilization": 78.0, "resets_at": "2026-10-21T14:00:00+00:00" },
            "seven_day": { "utilization": 82, "resets_at": "2026-10-24T09:00:00+00:00" },
            "seven_day_opus": null,
        }))
        .unwrap();
        assert_eq!(live.five_hour, Some(78.0));
        assert_eq!(live.seven_day, Some(82.0));
        assert_eq!(live.five_hour_resets_at.as_deref(), Some("2026-10-21T14:00:00+00:00"));
        assert_eq!(parse_live(&json!({ "five_hour": null, "seven_day": null })), None);
        assert_eq!(parse_live(&json!({ "error": "x" })), None);
    }

    #[test]
    fn nonsense_is_left_out() {
        assert_eq!(latest(&json!({ "samples": [{ "t": 1.0, "u": { "fh": -5, "sd": "x" } }] })), None);
        assert_eq!(latest(&json!({ "samples": [{ "t": 1.0, "u": { "fh": 150 } }] })).unwrap().five_hour, Some(100.0));
        assert_eq!(latest(&json!({})), None);
    }
}
