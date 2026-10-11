//! Two relays waiting on the same call, each for its own Coucou: the one that
//! gets an answer prints it, the other lets go at once with no output.
#![cfg(target_os = "linux")]

use std::io::{Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

fn private_dir(path: &Path) {
    std::fs::create_dir_all(path).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).unwrap();
}

/// A Coucou that answers `answer` after `after`, or holds the request until the relay hangs up.
/// Returns when the relay closed its side, and when that was.
fn coucou(sock: PathBuf, answer: Option<&'static str>, after: Duration) -> std::thread::JoinHandle<Instant> {
    let listener = UnixListener::bind(&sock).unwrap();
    std::thread::spawn(move || {
        let (mut conn, _) = listener.accept().unwrap();
        let mut line = Vec::new();
        let mut byte = [0u8; 1];
        while conn.read(&mut byte).unwrap_or(0) == 1 && byte[0] != b'\n' {
            line.push(byte[0]);
        }
        std::thread::sleep(after);
        if let Some(a) = answer {
            conn.write_all(format!("{a}\n").as_bytes()).unwrap();
        }
        let _ = conn.read(&mut byte);
        Instant::now()
    })
}

fn relay(program: &[&str], home: &Path, sock: &Path, event: &str, payload: &str) -> std::process::Child {
    let mut child = Command::new(program[0])
        .args(&program[1..])
        .arg(event)
        .env("HOME", home)
        .env("COUCOU_SOCKET", sock)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(payload.as_bytes()).unwrap();
    child
}

fn two_relays(second: &[&str], event: &str, payload: &str, answer: &'static str) -> (String, String, Duration) {
    let root = std::env::temp_dir().join(format!("coucou-answered-{}-{}", std::process::id(), second.len()));
    let _ = std::fs::remove_dir_all(&root);
    let (a, b) = (root.join("a"), root.join("b"));
    private_dir(&a);
    private_dir(&b);
    let (sa, sb) = (a.join("1111aaaa.sock"), b.join("2222bbbb.sock"));
    let first = coucou(sa.clone(), Some(answer), Duration::from_millis(600));
    let other = coucou(sb.clone(), None, Duration::ZERO);

    let bin = env!("CARGO_BIN_EXE_coucou-hook");
    let one = relay(&[bin], &root, &sa, event, payload);
    let two = relay(second, &root, &sb, event, payload);
    let out_one = one.wait_with_output().unwrap();
    let answered_at = Instant::now();
    let out_two = two.wait_with_output().unwrap();
    let released = other.join().unwrap();
    first.join().unwrap();
    let _ = std::fs::remove_dir_all(&root);
    (
        String::from_utf8(out_one.stdout).unwrap(),
        String::from_utf8(out_two.stdout).unwrap(),
        released.saturating_duration_since(answered_at),
    )
}

const PERMISSION: &str = r#"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash","tool_input":{"command":"ls"}}"#;
const QUESTION: &str = r#"{"hook_event_name":"PreToolUse","session_id":"s1","tool_use_id":"toolu_01Q","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which?","options":[{"label":"A"},{"label":"B"}]}]}}"#;

fn assert_released(name: &str, (one, two, after): (String, String, Duration), expected: &str) {
    assert_eq!(one.trim(), expected, "{name}: the answering relay prints the answer");
    assert_eq!(two, "", "{name}: the other relay prints nothing");
    assert!(after < Duration::from_millis(300), "{name}: the other relay let go after {after:?}");
}

#[test]
fn the_first_answer_releases_the_other_relay() {
    let bin = env!("CARGO_BIN_EXE_coucou-hook");
    let allow = r#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#;
    assert_released("permission", two_relays(&[bin], "PermissionRequest", PERMISSION, "allow"), allow);

    let picked = r#"{"answers":{"Which?":"B"}}"#;
    let (one, two, after) = two_relays(&[bin], "PreToolUse", QUESTION, picked);
    let reply: serde_json::Value = serde_json::from_str(one.trim()).unwrap();
    assert_eq!(reply["hookSpecificOutput"]["permissionDecision"], "allow");
    assert_eq!(reply["hookSpecificOutput"]["updatedInput"]["answers"]["Which?"], "B");
    assert_released("question", (String::new(), two, after), "");
}

#[test]
fn the_python_relay_lets_go_too() {
    if Command::new("python3").arg("--version").output().is_err() {
        return;
    }
    let py = concat!(env!("CARGO_MANIFEST_DIR"), "/coucou-hook.py");
    let allow = r#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#;
    assert_released("python", two_relays(&["python3", "-B", py], "PermissionRequest", PERMISSION, "allow"), allow);
}
