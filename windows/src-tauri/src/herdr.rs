// "Open terminal" for a session inside herdr: the window comes forward as for
// any terminal (session_window.rs), then herdr selects the session's pane.
//
// The relay forwards HERDR_PANE_ID, HERDR_BIN_PATH and, in WSL, WSL_DISTRO_NAME.
// The binary's full path is needed because `wsl.exe -e` starts no login shell,
// so herdr may not be on PATH there.

use serde_json::Value;
use std::process::Command;
use std::sync::Mutex;

#[derive(Debug, Clone, PartialEq)]
pub struct Pane {
    id: String,
    bin: String,
    distro: Option<String>,
}

/// Sessions seen in herdr, by session ID. In memory only, like session_window.rs.
static PANES: Mutex<Vec<(String, Pane)>> = Mutex::new(Vec::new());

/// These values come from another process and end up as arguments: only
/// plain names, never one an argument parser would read as an option.
fn valid_name(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && !value.starts_with('-')
        && value.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, ':' | '.' | '_' | '-'))
}

fn valid_bin(value: &str) -> bool {
    value.starts_with('/') && value.len() <= 512 && !value.chars().any(char::is_control)
}

pub fn from_payload(payload: &Value) -> Option<Pane> {
    let field = |key: &str| payload.get(key).and_then(Value::as_str).unwrap_or_default();
    let (id, bin, distro) = (field("herdr_pane"), field("herdr_bin"), field("wsl_distro"));
    if !valid_name(id) || !valid_bin(bin) || !(distro.is_empty() || valid_name(distro)) {
        return None;
    }
    Some(Pane {
        id: id.to_string(),
        bin: bin.to_string(),
        distro: (!distro.is_empty()).then(|| distro.to_string()),
    })
}

/// Keeps or drops a session's pane from its hook events.
pub fn observe(payload: &Value, event: &str) {
    let Some(session) = payload.get("session_id").and_then(Value::as_str) else { return };
    if event == "SessionEnd" {
        forget(session);
    } else if let Some(pane) = from_payload(payload) {
        remember(session, pane);
    }
}

fn remember(session: &str, pane: Pane) {
    if !crate::session_window::valid_session(session) {
        return;
    }
    let mut list = PANES.lock().unwrap_or_else(|e| e.into_inner());
    list.retain(|(s, _)| s != session);
    list.push((session.to_string(), pane));
}

fn forget(session: &str) {
    PANES.lock().unwrap_or_else(|e| e.into_inner()).retain(|(s, _)| s != session);
}

fn lookup(session: &str) -> Option<Pane> {
    let list = PANES.lock().unwrap_or_else(|e| e.into_inner());
    list.iter().find(|(s, _)| s == session).map(|(_, pane)| pane.clone())
}

/// The program and its arguments. `wsl.exe -e` runs the binary without a shell.
fn command_args(pane: &Pane) -> (String, Vec<String>) {
    let focus = ["agent".to_string(), "focus".to_string(), pane.id.clone()];
    match &pane.distro {
        Some(distro) => {
            let mut args = vec!["-d".to_string(), distro.clone(), "-e".to_string(), pane.bin.clone()];
            args.extend(focus);
            ("wsl.exe".to_string(), args)
        }
        None => (pane.bin.clone(), focus.to_vec()),
    }
}

/// Asks herdr to select the session's pane. False for a session that does not
/// run in herdr, or when herdr could not be started.
pub fn focus(session: &str) -> bool {
    let Some(pane) = lookup(session) else { return false };
    let (program, args) = command_args(&pane);
    let mut cmd = Command::new(program);
    cmd.args(args);
    match crate::platform::no_console(&mut cmd).spawn() {
        Ok(_) => true,
        Err(e) => {
            crate::log::line(format!("herdr focus failed: {e}"));
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn payload(pane: &str, bin: &str, distro: &str) -> Value {
        json!({ "session_id": "s1", "herdr_pane": pane, "herdr_bin": bin, "wsl_distro": distro })
    }

    #[test]
    fn a_wsl_session_focuses_its_pane_through_wsl_exe() {
        let pane = from_payload(&payload("w1:pA", "/usr/bin/herdr", "Ubuntu")).unwrap();
        let (program, args) = command_args(&pane);
        assert_eq!(program, "wsl.exe");
        assert_eq!(args, ["-d", "Ubuntu", "-e", "/usr/bin/herdr", "agent", "focus", "w1:pA"]);
    }

    #[test]
    fn a_linux_session_runs_herdr_itself() {
        let pane = from_payload(&payload("w1:pA", "/usr/bin/herdr", "")).unwrap();
        let (program, args) = command_args(&pane);
        assert_eq!(program, "/usr/bin/herdr");
        assert_eq!(args, ["agent", "focus", "w1:pA"]);
    }

    #[test]
    fn hostile_or_missing_values_are_refused() {
        assert!(from_payload(&payload("", "/usr/bin/herdr", "")).is_none());
        assert!(from_payload(&payload("-x", "/usr/bin/herdr", "")).is_none());
        assert!(from_payload(&payload("w1;rm", "/usr/bin/herdr", "")).is_none());
        assert!(from_payload(&payload("w1 pA", "/usr/bin/herdr", "")).is_none());
        assert!(from_payload(&payload("w1:pA", "herdr", "")).is_none());
        assert!(from_payload(&payload("w1:pA", "", "")).is_none());
        assert!(from_payload(&payload("w1:pA", "/usr/bin/herdr\n", "")).is_none());
        assert!(from_payload(&payload("w1:pA", "/usr/bin/herdr", "--exec")).is_none());
        assert!(from_payload(&json!({ "session_id": "s1" })).is_none());
    }

    #[test]
    fn a_session_end_forgets_the_pane() {
        let start = json!({ "session_id": "herdr-test-1", "herdr_pane": "w1:pB", "herdr_bin": "/b/herdr" });
        observe(&start, "SessionStart");
        assert_eq!(lookup("herdr-test-1").map(|p| p.id), Some("w1:pB".to_string()));
        observe(&json!({ "session_id": "herdr-test-1" }), "SessionEnd");
        assert!(lookup("herdr-test-1").is_none());
    }
}
