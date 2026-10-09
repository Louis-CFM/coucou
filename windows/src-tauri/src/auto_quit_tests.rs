use super::*;
use serde_json::json;

fn event(agent: &str, sid: &str, name: &str, stamp: u64) -> Value {
    json!({"coucou_agent":agent,"session_id":sid,"hook_event_name":name,
        "coucou_event_time_us":stamp,"reason":"other","coucou_lifecycle":"finalize"})
}
fn observe(t: &mut Tracker, agent: &str, sid: &str, name: &str, stamp: u64, now: Instant) {
    t.observe(&event(agent, sid, name, stamp), now, stamp);
}
fn finished(now: Instant) -> Tracker {
    let mut t = Tracker::default();
    t.configure(true, 10, now);
    observe(&mut t, "codex", "s", "UserPromptSubmit", 1, now);
    observe(&mut t, "codex", "s", "SessionEnd", 2, now);
    t
}

#[test]
fn defaults_off_and_manual_launch_never_starts_a_countdown() {
    let now = Instant::now();
    let mut t = Tracker::default();
    assert!(!t.enabled);
    t.configure(true, 10, now);
    assert!(t.deadline.is_none());
    assert_eq!(
        t.observe(&event("codex", "unknown", "SessionEnd", 1), now, 1),
        "orphan_end"
    );
    assert!(t.deadline.is_none());
}

#[test]
fn diagnostics_hide_session_ids_and_untrusted_frontend_text() {
    let now = Instant::now();
    let mut t = Tracker::default();
    t.configure(true, 5, now);
    observe(
        &mut t,
        "antigravity",
        "private-session-id",
        "SessionStart",
        1,
        now,
    );
    let summary = t.diagnostic(now);
    assert!(summary.contains("open_antigravity=1"));
    assert!(!summary.contains("private-session-id"));
    assert_eq!(safe_busy_reason(Some("prompt=secret\n")), "other");
    assert_eq!(safe_busy_reason(Some("chat_history")), "chat_history");
}

#[test]
fn real_end_starts_exactly_ten_minutes_with_a_fresh_ui_confirmation() {
    let now = Instant::now();
    let mut t = finished(now);
    let rev = t.revision;
    assert_eq!(t.deadline, Some(now + DELAY));
    assert!(t
        .propose(rev, now + DELAY - Duration::from_millis(1))
        .is_none());
    assert!(!t.can_quit(rev, now + DELAY, false));
    let ticket = t.propose(rev, now + DELAY).unwrap();
    assert!(t.can_quit(ticket, now + DELAY, false));
    assert!(!t.can_quit(ticket, now + DELAY, true));
    assert!(!t.can_quit(ticket, now + DELAY + Duration::from_secs(6), false));
    let next = t.propose(rev, now + DELAY + RETRY).unwrap();
    assert!(!t.can_quit(ticket, now + DELAY + RETRY, false));
    assert!(t.can_quit(next, now + DELAY + RETRY, false));
}

#[test]
fn every_allowed_delay_starts_at_the_last_real_end() {
    let now = Instant::now();
    for minutes in [5, 10, 15, 30, 60] {
        let mut t = Tracker::default();
        t.configure(true, minutes, now);
        observe(&mut t, "codex", "s", "UserPromptSubmit", 1, now);
        assert!(t.deadline.is_none());
        let ended = now + Duration::from_secs(20);
        observe(&mut t, "codex", "s", "SessionEnd", 2, ended);
        let deadline = ended + Duration::from_secs(u64::from(minutes) * 60);
        assert_eq!(t.ended_at, Some(ended));
        assert_eq!(t.deadline, Some(deadline));
        assert!(t
            .propose(t.revision, deadline - Duration::from_millis(1))
            .is_none());
        assert!(t.propose(t.revision, deadline).is_some());
    }
}

#[test]
fn virtual_clock_arms_five_and_sixty_minutes_without_waiting() {
    for minutes in [5, 60] {
        let mut control = Control::default();
        let now = control.now();
        control.tracker.configure(true, minutes, now);
        observe(
            &mut control.tracker,
            "codex",
            "private-session-id",
            "UserPromptSubmit",
            1,
            now,
        );
        observe(
            &mut control.tracker,
            "codex",
            "private-session-id",
            "SessionEnd",
            2,
            now,
        );
        assert!(control.wait().unwrap() > Duration::from_secs(u64::from(minutes) * 60 - 1));
        control.test_offset += Duration::from_secs(u64::from(minutes) * 60 + 1);
        assert_eq!(control.wait(), Some(Duration::ZERO));
        assert!(control
            .tracker
            .propose(control.tracker.revision, control.now())
            .is_some());
        let diagnostic = control.tracker.diagnostic(control.now());
        assert!(!diagnostic.contains("private-session-id"));
        assert!(diagnostic.contains("open_codex=0"));
    }
}

#[test]
fn changing_delay_replaces_the_deadline_without_restarting_elapsed_time() {
    let now = Instant::now();
    let mut t = Tracker::default();
    t.configure(true, 30, now);
    observe(&mut t, "codex", "s", "UserPromptSubmit", 1, now);
    observe(&mut t, "codex", "s", "SessionEnd", 2, now);
    let old_revision = t.revision;
    t.configure(true, 10, now + Duration::from_secs(5 * 60));
    assert_eq!(t.ended_at, Some(now));
    assert_eq!(t.deadline, Some(now + Duration::from_secs(10 * 60)));
    assert!(t.propose(old_revision, now + DELAY).is_none());
    assert!(t.propose(t.revision, now + DELAY).is_some());

    let old_ticket = t.proposal.unwrap().0;
    t.configure(true, 5, now + Duration::from_secs(11 * 60));
    assert_eq!(t.deadline, Some(now + Duration::from_secs(5 * 60)));
    assert!(!t.can_quit(old_ticket, now + Duration::from_secs(11 * 60), false));
    let ticket = t
        .propose(t.revision, now + Duration::from_secs(11 * 60))
        .unwrap();
    assert!(!t.can_quit(ticket, now + Duration::from_secs(11 * 60), true));
    assert!(t.can_quit(ticket, now + Duration::from_secs(11 * 60), false));
    t.configure(false, 5, now + Duration::from_secs(11 * 60));
    assert!(t.deadline.is_none());
    assert!(!t.can_quit(ticket, now + Duration::from_secs(11 * 60), false));
}

#[test]
fn codex_hermes_claude_and_opencode_have_independent_lifetimes() {
    let now = Instant::now();
    let mut t = Tracker::default();
    t.configure(true, 10, now);
    let agents = ["codex", "hermes", "claude-code", "opencode"];
    for agent in agents {
        observe(&mut t, agent, "same-id", "UserPromptSubmit", 1, now);
    }
    for agent in &agents[..3] {
        observe(&mut t, agent, "same-id", "SessionEnd", 2, now);
        assert!(t.deadline.is_none());
    }
    observe(&mut t, "opencode", "same-id", "SessionEnd", 2, now);
    assert_eq!(t.deadline, Some(now + DELAY));
}

#[test]
fn every_conversation_counts_even_when_it_has_no_visible_pill() {
    let now = Instant::now();
    let mut t = finished(now);
    for sid in ["a", "b"] {
        observe(&mut t, "codex", sid, "SessionStart", 3, now);
    }
    observe(&mut t, "codex", "a", "SessionEnd", 4, now);
    assert!(t.deadline.is_none());
    observe(&mut t, "codex", "b", "SessionEnd", 4, now);
    assert!(t.deadline.is_some());
}

#[test]
fn stop_idle_reasoning_permissions_and_crashes_do_not_end_a_session() {
    let now = Instant::now();
    for name in [
        "SessionStart",
        "Stop",
        "StopFailure",
        "Interrupt",
        "PermissionRequest",
        "PreToolUse",
        "PostToolUse",
        "Notification",
        "SubagentStop",
    ] {
        let mut t = Tracker::default();
        t.configure(true, 10, now);
        observe(&mut t, "codex", "s", name, 1, now);
        assert!(t.propose(t.revision, now + DELAY * 100).is_none(), "{name}");
    }
}

#[test]
fn both_antigravity_apps_and_unknown_adapters_hold_the_app_open() {
    let now = Instant::now();
    let mut t = finished(now);
    for (agent, sid) in [
        ("antigravity", "conversation-a"),
        ("antigravity", "conversation-b"),
        ("future-agent", "x"),
    ] {
        observe(&mut t, agent, sid, "UserPromptSubmit", 3, now);
        observe(&mut t, agent, sid, "Stop", 4, now);
        observe(&mut t, agent, sid, "SessionEnd", 5, now);
    }
    assert!(t.deadline.is_none());
    assert_eq!(t.sessions.values().filter(|s| !s.ended).count(), 3);
}

#[test]
fn hermes_turn_end_cannot_substitute_for_finalize() {
    let now = Instant::now();
    let mut t = Tracker::default();
    t.configure(true, 10, now);
    observe(&mut t, "hermes", "h", "UserPromptSubmit", 1, now);
    let mut end = event("hermes", "h", "SessionEnd", 2);
    end.as_object_mut().unwrap().remove("coucou_lifecycle");
    t.observe(&end, now, 2);
    assert!(t.deadline.is_none());
    observe(&mut t, "hermes", "h", "SessionEnd", 3, now);
    assert!(t.deadline.is_some());
}

#[test]
fn new_work_cancels_countdown_and_invalidates_in_flight_confirmation() {
    let now = Instant::now();
    let mut t = finished(now);
    let old = t.revision;
    let ticket = t.propose(old, now + DELAY).unwrap();
    observe(
        &mut t,
        "opencode",
        "new",
        "UserPromptSubmit",
        3,
        now + DELAY,
    );
    assert!(t.deadline.is_none());
    assert!(!t.can_quit(ticket, now + DELAY, false));
}

#[test]
fn off_cancels_and_on_waits_for_live_sessions() {
    let now = Instant::now();
    let mut t = finished(now);
    let rev = t.revision;
    let ticket = t.propose(rev, now + DELAY).unwrap();
    t.configure(false, 10, now);
    assert!(t.deadline.is_none());
    assert!(!t.can_quit(ticket, now + DELAY, false));
    observe(&mut t, "hermes", "h", "SessionStart", 3, now);
    t.configure(true, 10, now);
    assert!(t.deadline.is_none());
    observe(&mut t, "hermes", "h", "SessionEnd", 4, now);
    assert_eq!(t.deadline, Some(now + DELAY));
}

#[test]
fn duplicate_ends_do_not_reset_timer_and_unrelated_end_cannot_release_a_session() {
    let now = Instant::now();
    let mut t = finished(now);
    let rev = t.revision;
    observe(
        &mut t,
        "codex",
        "s",
        "SessionEnd",
        2,
        now + Duration::from_secs(10),
    );
    observe(&mut t, "codex", "old", "SessionEnd", 3, now);
    assert_eq!(t.revision, rev);
    assert_eq!(t.deadline, Some(now + DELAY));
}

#[test]
fn out_of_order_or_old_end_cannot_close_newer_work() {
    let now = Instant::now();
    let mut t = Tracker::default();
    t.configure(true, 10, now);
    observe(&mut t, "codex", "s", "UserPromptSubmit", 10, now);
    t.observe(&event("codex", "s", "SessionEnd", 9), now, 11);
    assert!(t.deadline.is_none());
    t.observe(&event("codex", "s", "SessionEnd", 11), now, 70_000_012);
    assert!(t.deadline.is_none());
}

#[test]
fn resumed_or_reused_identity_is_conservative_when_generation_is_ambiguous() {
    let now = Instant::now();
    let mut t = finished(now);
    observe(&mut t, "codex", "s", "UserPromptSubmit", 3, now);
    observe(&mut t, "codex", "s", "SessionEnd", 4, now);
    assert!(t.deadline.is_none());
    for stamp in [1, 2] {
        observe(&mut t, "claude-code", "c", "SessionStart", stamp, now);
    }
    observe(&mut t, "claude-code", "c", "SessionEnd", 3, now);
    assert!(!t.sessions[&("claude-code".into(), "c".into())].ended);
}

#[test]
fn malformed_ids_old_relays_and_overflow_fail_closed() {
    let now = Instant::now();
    for bad in ["", "bad\nID"] {
        let mut t = finished(now);
        observe(&mut t, "codex", bad, "UserPromptSubmit", 3, now);
        assert!(t.deadline.is_none());
    }
    let mut t = finished(now);
    let mut old = event("codex", "old-relay", "UserPromptSubmit", 3);
    old.as_object_mut().unwrap().remove("coucou_event_time_us");
    t.observe(&old, now, 3);
    observe(&mut t, "codex", "old-relay", "SessionEnd", 4, now);
    assert!(t.deadline.is_none());
    for n in 0..MAX_SESSIONS {
        observe(&mut t, "codex", &n.to_string(), "SessionStart", 5, now);
    }
    assert!(t.uncertain);
    assert_eq!(t.sessions.len(), MAX_SESSIONS);
}

#[test]
fn automatic_launch_next_run_starts_without_old_countdown_or_sessions() {
    let now = Instant::now();
    let mut old = finished(now);
    let ticket = old.propose(old.revision, now + DELAY).unwrap();
    assert!(old.can_quit(ticket, now + DELAY, false));
    let mut fresh = Tracker::default();
    fresh.configure(true, 10, now);
    observe(&mut fresh, "codex", "s", "UserPromptSubmit", 100, now);
    assert!(fresh.deadline.is_none());
}

#[test]
fn two_simultaneous_closes_produce_one_deadline() {
    use std::sync::{Arc, Barrier};
    let now = Instant::now();
    let mut tracker = Tracker::default();
    tracker.configure(true, 10, now);
    for agent in ["codex", "hermes"] {
        observe(&mut tracker, agent, "s", "UserPromptSubmit", 1, now);
    }
    let shared = Arc::new(Mutex::new(tracker));
    let barrier = Arc::new(Barrier::new(2));
    let threads: Vec<_> = ["codex", "hermes"]
        .into_iter()
        .map(|agent| {
            let shared = shared.clone();
            let barrier = barrier.clone();
            std::thread::spawn(move || {
                barrier.wait();
                let mut t = shared.lock().unwrap();
                let before = t.deadline;
                observe(&mut t, agent, "s", "SessionEnd", 2, now);
                usize::from(before.is_none() && t.deadline.is_some())
            })
        })
        .collect();
    assert_eq!(
        threads
            .into_iter()
            .map(|t| t.join().unwrap())
            .sum::<usize>(),
        1
    );
    assert_eq!(shared.lock().unwrap().deadline, Some(now + DELAY));
}
