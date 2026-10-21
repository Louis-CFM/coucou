// Claude plan usage from the Claude desktop app. Its Code tab never runs Claude
// Code's status line, so the relay hears no `rate_limits` there; but the app
// keeps its own record of the plan's use, `plan-usage-history.json`, sampled
// while it runs: `fh` is the 5-hour window and `sd` the week, in percent.
// Only the newest sample is read; nothing is written, nothing goes anywhere.

use std::path::PathBuf;

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
    fn nonsense_is_left_out() {
        assert_eq!(latest(&json!({ "samples": [{ "t": 1.0, "u": { "fh": -5, "sd": "x" } }] })), None);
        assert_eq!(latest(&json!({ "samples": [{ "t": 1.0, "u": { "fh": 150 } }] })).unwrap().five_hour, Some(100.0));
        assert_eq!(latest(&json!({})), None);
    }
}
