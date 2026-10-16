use std::sync::{Arc, Mutex};

use coucou_phone_link::hub::{ApprovalIn, Caps, Host, Hub, Out, Outcome, SessionIn};
use serde_json::Value;
use tokio::sync::mpsc;

#[derive(Default)]
struct Recorder(Mutex<Vec<(String, bool)>>);

impl Host for Recorder {
    fn decide(&self, request_id: &str, allow: bool) {
        self.0.lock().unwrap().push((request_id.into(), allow));
    }
}

fn next_line(rx: &mut mpsc::Receiver<Out>) -> Value {
    match rx.try_recv().expect("the hub sent a line") {
        Out::Line(line) => serde_json::from_str(&line).unwrap(),
        Out::Close { .. } => panic!("the connection should stay open"),
    }
}

#[test]
fn a_host_receives_only_the_current_decision() {
    let host = Arc::new(Recorder::default());
    let hub = Hub::new(host.clone());
    let sessions = vec![SessionIn {
        pill_id: "integration_claude".into(),
        agent: "Claude Code".into(),
        state: "working".into(),
        ..Default::default()
    }];
    let request = |id: &str| ApprovalIn {
        request_id: id.into(),
        session_id: "session-1".into(),
        pill_id: "integration_claude".into(),
        tool: "Bash".into(),
        command: "cargo test".into(),
    };
    hub.publish(sessions.clone(), Some(request("request-1")), 1_000);
    let (tx, mut rx) = mpsc::channel(8);
    hub.subscribe_with(tx, 1_001, Caps::default());
    let snapshot = next_line(&mut rx);
    assert_eq!(snapshot["type"], "sessions");
    assert_eq!(snapshot["sessions"][0]["state"], "working");
    let first = next_line(&mut rx);
    assert_eq!(first["type"], "approval");
    let first_fp = first["fingerprint"].as_str().unwrap();

    hub.publish(sessions, Some(request("request-2")), 2_000);
    assert_eq!(next_line(&mut rx)["type"], "approvalResolved");
    let second = next_line(&mut rx);
    assert_eq!(second["type"], "approval");
    let second_fp = second["fingerprint"].as_str().unwrap();
    assert_ne!(first_fp, second_fp);
    assert_eq!(hub.decide(first_fp, "allow", 2_001), Outcome::NoMatch);
    assert!(host.0.lock().unwrap().is_empty());
    assert_eq!(hub.decide(second_fp, "deny", 2_002), Outcome::Applied);
    assert_eq!(hub.decide(second_fp, "allow", 2_003), Outcome::NoMatch);
    assert_eq!(
        *host.0.lock().unwrap(),
        vec![("request-2".to_string(), false)]
    );
}
