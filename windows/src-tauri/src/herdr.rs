// "Open terminal" for a session inside herdr: herdr selects the session's pane,
// and the window comes forward as for any terminal (session_window.rs).
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

/// An absolute path to a program named herdr: Coucou runs it, so nothing else.
fn valid_bin(value: &str) -> bool {
    value.starts_with('/')
        && value.len() <= 512
        && !value.chars().any(char::is_control)
        && value.rsplit('/').next() == Some("herdr")
}

pub fn from_payload(payload: &Value) -> Option<Pane> {
    let field = |key: &str| payload.get(key).and_then(Value::as_str).unwrap_or_default();
    let (id, bin, distro) = (field("herdr_pane"), field("herdr_bin"), field("wsl_distro"));
    if !valid_name(id) || !valid_bin(bin) || !(distro.is_empty() || valid_name(distro)) {
        return None;
    }
    // Without a distro, Windows would read `/usr/bin/herdr` as `C:\usr\bin\herdr`,
    // a folder any user can create.
    if cfg!(windows) && distro.is_empty() {
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
    let excess = list.len().saturating_sub(crate::session_window::MAX_SESSIONS);
    list.drain(..excess);
}

fn forget(session: &str) {
    PANES.lock().unwrap_or_else(|e| e.into_inner()).retain(|(s, _)| s != session);
}

fn lookup(session: &str) -> Option<Pane> {
    let list = PANES.lock().unwrap_or_else(|e| e.into_inner());
    list.iter().find(|(s, _)| s == session).map(|(_, pane)| pane.clone())
}

/// `wsl.exe -e` runs the binary without a shell, so no shell parses the arguments.
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
// shortcut: true once herdr starts, not once it succeeds, so a stale pane gets
// no VS Code fallback; wait for herdr's exit status if that proves confusing.
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
    fn without_a_distro_herdr_runs_itself_on_linux_only() {
        let pane = from_payload(&payload("w1:pA", "/usr/bin/herdr", ""));
        if cfg!(windows) {
            assert!(pane.is_none());
            return;
        }
        let (program, args) = command_args(&pane.unwrap());
        assert_eq!(program, "/usr/bin/herdr");
        assert_eq!(args, ["agent", "focus", "w1:pA"]);
    }

    #[test]
    fn only_a_program_named_herdr_is_run() {
        for bin in ["/tmp/evil", "/usr/bin/herdr-x", "/usr/bin/sh", "herdr", "/usr/bin/herdr/"] {
            assert!(from_payload(&payload("w1:pA", bin, "Ubuntu")).is_none(), "{bin}");
        }
        assert!(from_payload(&payload("w1:pA", "/home/me/.cargo/bin/herdr", "Ubuntu")).is_some());
    }

    #[test]
    fn the_pane_list_is_capped() {
        let extra = crate::session_window::MAX_SESSIONS + 3;
        for i in 0..extra {
            observe(&json!({ "session_id": format!("herdr-cap-{i}"), "herdr_pane": "w1:pC",
                "herdr_bin": "/b/herdr", "wsl_distro": "Ubuntu" }), "UserPromptSubmit");
        }
        assert!(lookup("herdr-cap-0").is_none());
        assert!(lookup(&format!("herdr-cap-{}", extra - 1)).is_some());
        for i in 0..extra {
            forget(&format!("herdr-cap-{i}"));
        }
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
        let start = json!({ "session_id": "herdr-test-1", "herdr_pane": "w1:pB", "herdr_bin": "/b/herdr",
            "wsl_distro": "Ubuntu" });
        observe(&start, "SessionStart");
        assert_eq!(lookup("herdr-test-1").map(|p| p.id), Some("w1:pB".to_string()));
        observe(&json!({ "session_id": "herdr-test-1" }), "SessionEnd");
        assert!(lookup("herdr-test-1").is_none());
    }
}
