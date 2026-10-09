use std::fs::File;
use std::io;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};

#[path = "../../shared/auto_launch.rs"]
#[allow(dead_code)] // Coucou also compiles this file, using the registration side.
mod files;

#[path = "auto_launch_spawn.rs"]
mod process;

const START_BUDGET: Duration = Duration::from_millis(1500);
const FAILED_START_COOLDOWN_MS: u64 = 10_000;
use crate::auto_launch_trigger::valid_key;

/// Atomically remember the trigger before spawning. False means no startup to wait for.
fn launch(
    dir: &Path,
    settings: &Path,
    key: Value,
    connected: bool,
    now: u64,
    spawn: impl FnOnce(&Path) -> io::Result<()>,
) -> io::Result<bool> {
    // A concurrent CreateProcessW can hold this lock longer than 100 ms under load.
    let deadline = Instant::now()
        + if connected {
            Duration::from_millis(100)
        } else {
            Duration::from_millis(800)
        };
    let _guard = loop {
        match files::lock(&dir.join("auto-launch.lock")) {
            Ok(file) => break file,
            Err(err)
                if err.raw_os_error() == Some(files::SHARING_VIOLATION)
                    && Instant::now() < deadline =>
            {
                std::thread::sleep(Duration::from_millis(10));
            }
            Err(err) => return Err(err),
        }
    };
    if !files::enabled(settings) {
        return Ok(false);
    }
    let path = dir.join("auto-launch-state.json");
    let mut state = match files::read_json(&path) {
        Ok(state) => state,
        Err(err) if err.kind() == io::ErrorKind::NotFound => {
            json!({ "prompts": [], "retryAfter": 0 })
        }
        Err(err) => return Err(err),
    };
    let retry_after = state
        .get("retryAfter")
        .and_then(Value::as_u64)
        .ok_or_else(|| io::Error::other("invalid auto-launch state"))?;
    let prompts = state
        .get_mut("prompts")
        .and_then(Value::as_array_mut)
        .ok_or_else(|| io::Error::other("invalid auto-launch prompts"))?;
    if prompts.len() > 256 || prompts.iter().any(|v| !valid_key(v)) {
        return Err(io::Error::other("invalid auto-launch prompt ledger"));
    }
    let duplicate = prompts.contains(&key);
    if !duplicate {
        // ponytail: retain 256 recent prompts; use a longer ledger if old hook replays become possible.
        if prompts.len() >= 256 {
            prompts.remove(0);
        }
        prompts.push(key);
    }
    if connected {
        state["retryAfter"] = json!(0);
        files::write_json(&path, &state)?;
        return Ok(false);
    }
    // A running app may still be starting its pipe or shutting down after Quit.
    let running = match files::lock(&dir.join("auto-launch-running.lock")) {
        Ok(guard) => {
            drop(guard);
            false
        }
        Err(err) if err.raw_os_error() == Some(files::SHARING_VIOLATION) => true,
        Err(err) => return Err(err),
    };
    if running || retry_after > now {
        #[cfg(not(test))]
        files::diagnostic(if running {
            "launch_skipped reason=running_lock"
        } else {
            "launch_skipped reason=cooldown"
        });
        files::write_json(&path, &state)?;
        return Ok(true);
    }
    if duplicate {
        #[cfg(not(test))]
        files::diagnostic("launch_skipped reason=duplicate");
        return Ok(false);
    }
    state["retryAfter"] = json!(now.saturating_add(FAILED_START_COOLDOWN_MS));
    files::write_json(&path, &state)?;
    let registration = files::read_json(&dir.join("auto-launch-executable.json"))?;
    let exe = registration
        .get("executable")
        .and_then(Value::as_str)
        .map(PathBuf::from)
        .and_then(|p| files::executable(&p))
        .ok_or_else(|| io::Error::other("Coucou executable is unavailable"))?;
    spawn(&exe)?;
    Ok(true)
}

pub fn connect(key: Option<Value>) -> Option<File> {
    let started = Instant::now();
    let mut pipe = crate::win::connect();
    let Some(key) = key else {
        return pipe;
    };
    let agent = match key.as_array() {
        Some(parts) if parts.len() >= 3 => parts[0].as_str().unwrap_or("codex"),
        _ => "codex",
    };
    let event = if agent == "codex" {
        "UserPromptSubmit"
    } else {
        key[1].as_str().unwrap_or("unknown")
    };
    let (Some(dir), Some(settings)) = (files::local_dir(), files::settings_path()) else {
        return pipe;
    };
    // Missing, invalid, unreadable or OFF means no launch and no ledger writes.
    if !files::enabled(&settings) {
        if pipe.is_none() {
            files::diagnostic(format!(
                "launch_skipped agent={agent} event={event} reason=disabled"
            ));
        }
        return pipe;
    }
    if pipe.is_none() {
        files::diagnostic(format!(
            "hook_connect agent={agent} event={event} pipe_present=false"
        ));
    }
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()?
        .as_millis()
        .try_into()
        .ok()?;
    let wait = launch(&dir, &settings, key.clone(), pipe.is_some(), now, |exe| {
        let pid = process::spawn(exe)?;
        files::diagnostic(format!("spawned app_pid={pid} inherit_handles=false"));
        Ok(())
    });
    let wait = match wait {
        Ok(wait) => wait,
        Err(err) => {
            files::diagnostic(format!("launch_failed error={err}"));
            false
        }
    };
    if pipe.is_some() || !wait {
        return pipe;
    }
    while started.elapsed() < START_BUDGET {
        pipe = crate::win::connect();
        if pipe.is_some() {
            files::diagnostic(format!(
                "pipe_ready elapsed_ms={}",
                started.elapsed().as_millis()
            ));
            // Clear the failed-start cooldown once the app answers.
            let _ = launch(&dir, &settings, key, true, now, |_| Ok(()));
            return pipe;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    files::diagnostic(format!(
        "pipe_not_ready elapsed_ms={}",
        started.elapsed().as_millis()
    ));
    None
}

pub fn rejected(agent: &str, event: &str, reason: &str) {
    if files::settings_path().is_some_and(|path| files::enabled(&path)) {
        files::diagnostic(format!(
            "trigger_rejected agent={agent} event={event} reason={reason}"
        ));
    }
}

pub fn hook_finished(elapsed: Duration, timed_out: bool) {
    if files::settings_path().is_some_and(|path| files::enabled(&path)) {
        files::diagnostic(format!(
            "hook_exit worker_deadline={timed_out} elapsed_ms={}",
            elapsed.as_millis()
        ));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auto_launch_trigger::key as trigger;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Barrier};

    struct Fixture {
        dir: PathBuf,
        settings: PathBuf,
        exe: PathBuf,
    }
    impl Fixture {
        fn new() -> Self {
            static COUNT: AtomicUsize = AtomicUsize::new(0);
            let dir = std::env::temp_dir().join(format!(
                "coucou-auto-launch-{}-{}",
                std::process::id(),
                COUNT.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::create_dir_all(&dir).unwrap();
            let settings = dir.join("settings.json");
            let install = dir.join("Coucou installed with spaces");
            std::fs::create_dir(&install).unwrap();
            let exe = install.join("coucou.exe");
            std::fs::write(&exe, "fixture, never executed").unwrap();
            files::write_json(
                &settings,
                &json!({ "autoLaunchWithAgents": true, "autostart": false }),
            )
            .unwrap();
            files::write_json(
                &dir.join("auto-launch-executable.json"),
                &json!({ "executable": exe }),
            )
            .unwrap();
            Self { dir, settings, exe }
        }
        fn run(
            &self,
            turn: &str,
            connected: bool,
            now: u64,
            count: &AtomicUsize,
        ) -> io::Result<bool> {
            launch(
                &self.dir,
                &self.settings,
                json!(["session", turn]),
                connected,
                now,
                |exe| {
                    assert_eq!(exe, files::executable(&self.exe).unwrap());
                    count.fetch_add(1, Ordering::Relaxed);
                    Ok(())
                },
            )
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.dir);
        }
    }

    #[test]
    fn only_supported_agents_with_valid_turn_ids_can_launch() {
        let payload =
            json!({ "hook_event_name": "UserPromptSubmit", "session_id": "s", "turn_id": "t" });
        assert_eq!(trigger(&payload, "codex"), Some(json!(["s", "t"])));
        for agent in ["", "claude", "copilot", "gemini", "amp", "cursor", "muse"] {
            assert!(trigger(&payload, agent).is_none());
        }
        assert_eq!(
            trigger(&payload, "hermes"),
            Some(json!(["hermes", "UserPromptSubmit", "s", "t"]))
        );
        assert_eq!(
            trigger(&payload, "opencode"),
            Some(json!(["opencode", "UserPromptSubmit", "s", "t"]))
        );
        assert_eq!(
            trigger(&payload, "claude-code"),
            Some(json!(["claude-code", "UserPromptSubmit", "s", "t"]))
        );
        for event in [
            "SessionStart",
            "PreToolUse",
            "PermissionRequest",
            "PostToolUse",
            "Stop",
            "SessionEnd",
            "Interrupt",
            "SubagentStart",
            "SubagentStop",
        ] {
            let mut p = payload.clone();
            p["hook_event_name"] = json!(event);
            assert!(trigger(&p, "codex").is_none());
        }
        for field in ["session_id", "turn_id"] {
            for value in [Value::Null, json!(""), json!(42), json!("x".repeat(257))] {
                let mut p = payload.clone();
                p[field] = value;
                assert!(trigger(&p, "codex").is_none());
            }
        }
    }

    #[test]
    fn supported_agents_launch_and_reuse_the_same_app_in_either_order() {
        let codex = trigger(
            &json!({"hook_event_name":"UserPromptSubmit", "session_id":"same", "turn_id":"t"}),
            "codex",
        )
        .unwrap();
        let hermes = trigger(
            &json!({"hook_event_name":"SessionStart", "session_id":"same"}),
            "hermes",
        )
        .unwrap();
        let opencode = trigger(
            &json!({"hook_event_name":"UserPromptSubmit", "session_id":"same", "turn_id":"t"}),
            "opencode",
        )
        .unwrap();
        let claude = trigger(&json!({"hook_event_name":"SessionStart", "session_id":"same", "source":"startup", "turn_id":"transcript:0"}), "claude-code").unwrap();
        let antigravity = trigger(&json!({"hook_event_name":"PreInvocation", "conversationId":"ec33ebf9-0cba-4100-8142-c61503f6c587", "invocationNum":0, "initialNumSteps":0}), "antigravity").unwrap();
        for keys in [
            vec![
                codex.clone(),
                hermes.clone(),
                opencode.clone(),
                claude.clone(),
                antigravity.clone(),
            ],
            vec![antigravity, claude, opencode, hermes, codex],
        ] {
            let f = Fixture::new();
            let count = AtomicUsize::new(0);
            for (index, key) in keys.into_iter().enumerate() {
                let launched = launch(&f.dir, &f.settings, key.clone(), index != 0, 1, |_| {
                    count.fetch_add(1, Ordering::Relaxed);
                    Ok(())
                })
                .unwrap();
                assert_eq!(launched, index == 0);
                // A replay after Quit never reopens the app.
                assert!(!launch(&f.dir, &f.settings, key, false, 20_000, |_| panic!(
                    "duplicate launched"
                ))
                .unwrap());
            }
            assert_eq!(count.load(Ordering::Relaxed), 1);
            assert_eq!(
                files::read_json(&f.dir.join("auto-launch-state.json")).unwrap()["prompts"]
                    .as_array()
                    .unwrap()
                    .len(),
                5
            );
        }
    }

    #[test]
    fn off_prevents_all_agents_and_one_failure_does_not_disable_the_others() {
        let f = Fixture::new();
        let codex = trigger(
            &json!({"hook_event_name":"UserPromptSubmit", "session_id":"s", "turn_id":"t"}),
            "codex",
        )
        .unwrap();
        let hermes = trigger(
            &json!({"hook_event_name":"SessionStart", "session_id":"s"}),
            "hermes",
        )
        .unwrap();
        let hermes_turn = trigger(
            &json!({"hook_event_name":"UserPromptSubmit", "session_id":"s", "turn_id":"t"}),
            "hermes",
        )
        .unwrap();
        let opencode = trigger(
            &json!({"hook_event_name":"UserPromptSubmit", "session_id":"s", "turn_id":"m"}),
            "opencode",
        )
        .unwrap();
        let claude = trigger(&json!({"hook_event_name":"SessionStart", "session_id":"s", "source":"startup", "turn_id":"transcript:0"}), "claude-code").unwrap();
        let antigravity = trigger(&json!({"hook_event_name":"PreInvocation", "conversationId":"ec33ebf9-0cba-4100-8142-c61503f6c587", "invocationNum":0, "initialNumSteps":0}), "antigravity").unwrap();
        files::write_json(&f.settings, &json!({"autoLaunchWithAgents":false})).unwrap();
        for key in [
            codex.clone(),
            hermes.clone(),
            hermes_turn.clone(),
            opencode.clone(),
            claude.clone(),
            antigravity.clone(),
        ] {
            assert!(!launch(&f.dir, &f.settings, key, false, 1, |_| panic!(
                "OFF launched"
            ))
            .unwrap());
        }
        assert!(!f.dir.join("auto-launch-state.json").exists());
        files::write_json(&f.settings, &json!({"autoLaunchWithAgents":true})).unwrap();
        assert!(launch(&f.dir, &f.settings, opencode, false, 1, |_| Err(
            io::Error::other("OpenCode launch failed")
        ))
        .is_err());
        let count = AtomicUsize::new(0);
        assert!(launch(&f.dir, &f.settings, claude, false, 20_000, |_| {
            count.fetch_add(1, Ordering::Relaxed);
            Ok(())
        })
        .unwrap());
        assert_eq!(count.load(Ordering::Relaxed), 1);
        assert!(!launch(
            &f.dir,
            &f.settings,
            codex.clone(),
            true,
            20_001,
            |_| panic!("second app")
        )
        .unwrap());
        assert!(
            !launch(&f.dir, &f.settings, hermes, true, 20_002, |_| panic!(
                "second app"
            ))
            .unwrap()
        );
        assert!(
            !launch(&f.dir, &f.settings, hermes_turn, true, 20_003, |_| panic!(
                "second app"
            ))
            .unwrap()
        );
        assert!(
            !launch(&f.dir, &f.settings, antigravity, true, 20_004, |_| panic!(
                "second app"
            ))
            .unwrap()
        );
    }

    #[test]
    fn a_stage_one_ledger_keeps_codex_dedup_and_accepts_hermes() {
        let f = Fixture::new();
        files::write_json(
            &f.dir.join("auto-launch-state.json"),
            &json!({"prompts":[["s", "t"]], "retryAfter":0}),
        )
        .unwrap();
        assert!(!launch(
            &f.dir,
            &f.settings,
            json!(["s", "t"]),
            false,
            1,
            |_| panic!("legacy replay launched")
        )
        .unwrap());
        assert!(launch(
            &f.dir,
            &f.settings,
            json!(["hermes", "SessionStart", "s"]),
            false,
            1,
            |_| Ok(())
        )
        .unwrap());
        assert!(launch(
            &f.dir,
            &f.settings,
            json!(["hermes", "UserPromptSubmit", "s", "next"]),
            false,
            20_000,
            |_| Ok(())
        )
        .unwrap());
    }

    #[test]
    fn off_missing_invalid_or_unreadable_settings_never_launch() {
        let f = Fixture::new();
        let count = AtomicUsize::new(0);
        for content in [
            "{}",
            "null",
            "broken",
            r#"{"autoLaunchWithAgents":false}"#,
            r#"{"autoLaunchWithAgents":"true"}"#,
            r#"{"autostart":true}"#,
        ] {
            std::fs::write(&f.settings, content).unwrap();
            assert!(!f.run("t", false, 1, &count).unwrap());
        }
        std::fs::remove_file(&f.settings).unwrap();
        assert!(!f.run("t", false, 1, &count).unwrap());
        std::fs::create_dir(&f.settings).unwrap();
        assert!(!f.run("t", false, 1, &count).unwrap());
        assert_eq!(count.load(Ordering::Relaxed), 0);
        assert!(!f.dir.join("auto-launch-state.json").exists());
    }

    #[test]
    fn on_launches_once_and_a_running_instance_is_reused() {
        let f = Fixture::new();
        let count = AtomicUsize::new(0);
        assert!(f.run("t1", false, 1, &count).unwrap());
        assert!(!f.run("t1", true, 2, &count).unwrap());
        assert!(!f.run("t2", true, 3, &count).unwrap());
        assert_eq!(count.load(Ordering::Relaxed), 1);
        // Quit: old prompts cannot reopen; a newly submitted prompt can.
        assert!(!f.run("t1", false, 4, &count).unwrap());
        assert!(!f.run("t2", false, 5, &count).unwrap());
        assert!(f.run("t3", false, 6, &count).unwrap());
        assert_eq!(count.load(Ordering::Relaxed), 2);
    }

    #[test]
    fn simultaneous_sessions_share_one_launch_even_before_the_pipe_exists() {
        for hermes in [
            json!(["hermes", "SessionStart", "s"]),
            json!(["hermes", "UserPromptSubmit", "s", "h-turn"]),
        ] {
            let f = Fixture::new();
            let count = Arc::new(AtomicUsize::new(0));
            let barrier = Arc::new(Barrier::new(2));
            std::thread::scope(|scope| {
                let mut threads = Vec::new();
                for key in [json!(["s", "t"]), hermes] {
                    let count = count.clone();
                    let barrier = barrier.clone();
                    let f = &f;
                    threads.push(scope.spawn(move || {
                        barrier.wait();
                        launch(&f.dir, &f.settings, key, false, 1, |_| {
                            count.fetch_add(1, Ordering::Relaxed);
                            Ok(())
                        })
                        .unwrap()
                    }));
                }
                for thread in threads {
                    assert!(thread.join().unwrap());
                }
            });
            assert_eq!(count.load(Ordering::Relaxed), 1);
            assert_eq!(
                files::read_json(&f.dir.join("auto-launch-state.json")).unwrap()["prompts"]
                    .as_array()
                    .unwrap()
                    .len(),
                2
            );
        }
    }

    #[test]
    fn five_simultaneous_agents_share_the_startup_lock() {
        let f = Fixture::new();
        let count = Arc::new(AtomicUsize::new(0));
        let barrier = Arc::new(Barrier::new(5));
        let keys = [
            json!(["s", "t"]),
            json!(["hermes", "SessionStart", "s"]),
            json!(["opencode", "UserPromptSubmit", "s", "m"]),
            json!([
                "claude-code",
                "SessionStart",
                "s",
                "startup",
                "transcript:0"
            ]),
            json!([
                "antigravity",
                "PreInvocation",
                "ec33ebf9-0cba-4100-8142-c61503f6c587",
                0,
                0
            ]),
        ];
        std::thread::scope(|scope| {
            let mut threads = Vec::new();
            for key in keys {
                let count = count.clone();
                let barrier = barrier.clone();
                let f = &f;
                threads.push(scope.spawn(move || {
                    barrier.wait();
                    launch(&f.dir, &f.settings, key, false, 1, |_| {
                        count.fetch_add(1, Ordering::Relaxed);
                        std::thread::sleep(Duration::from_millis(250));
                        Ok(())
                    })
                    .unwrap()
                }));
            }
            for thread in threads {
                assert!(thread.join().unwrap());
            }
        });
        assert_eq!(count.load(Ordering::Relaxed), 1);
        assert_eq!(
            files::read_json(&f.dir.join("auto-launch-state.json")).unwrap()["prompts"]
                .as_array()
                .unwrap()
                .len(),
            5
        );
    }

    #[test]
    fn both_antigravity_apps_share_one_launcher_and_keep_separate_conversations() {
        let f = Fixture::new();
        let count = Arc::new(AtomicUsize::new(0));
        let barrier = Arc::new(Barrier::new(2));
        let ids = [
            "ec33ebf9-0cba-4100-8142-c61503f6c587",
            "7c619818-5c45-4e67-910e-f1dd3cffcb83",
        ];
        std::thread::scope(|scope| {
            let mut threads = Vec::new();
            for id in ids {
                let count = count.clone();
                let barrier = barrier.clone();
                let f = &f;
                threads.push(scope.spawn(move || {
                    let key = trigger(&json!({"hook_event_name":"PreInvocation", "conversationId":id, "invocationNum":0, "initialNumSteps":0}), "antigravity").unwrap();
                    barrier.wait();
                    launch(&f.dir, &f.settings, key, false, 1, |_| {
                        count.fetch_add(1, Ordering::Relaxed);
                        Ok(())
                    }).unwrap()
                }));
            }
            for thread in threads {
                assert!(thread.join().unwrap());
            }
        });
        assert_eq!(count.load(Ordering::Relaxed), 1);
        let state = files::read_json(&f.dir.join("auto-launch-state.json")).unwrap();
        assert_eq!(state["prompts"].as_array().unwrap().len(), 2);
        let resumed = trigger(&json!({"hook_event_name":"PreInvocation", "conversationId":ids[0], "invocationNum":1, "initialNumSteps":4}), "antigravity").unwrap();
        assert!(launch(&f.dir, &f.settings, resumed, false, 20_000, |_| {
            count.fetch_add(1, Ordering::Relaxed);
            Ok(())
        })
        .unwrap());
        assert_eq!(count.load(Ordering::Relaxed), 2);
    }

    #[test]
    fn a_failed_antigravity_launch_does_not_disable_other_agents() {
        let f = Fixture::new();
        let antigravity = json!([
            "antigravity",
            "PreInvocation",
            "ec33ebf9-0cba-4100-8142-c61503f6c587",
            0,
            0
        ]);
        assert!(launch(&f.dir, &f.settings, antigravity, false, 1, |_| {
            Err(io::Error::other("Antigravity fixture failed"))
        })
        .is_err());
        let codex = json!(["codex-session", "codex-turn"]);
        let count = AtomicUsize::new(0);
        assert!(launch(&f.dir, &f.settings, codex, false, 20_000, |_| {
            count.fetch_add(1, Ordering::Relaxed);
            Ok(())
        })
        .unwrap());
        assert_eq!(count.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn running_lock_prevents_a_second_app_and_releases_after_exit() {
        let f = Fixture::new();
        let count = AtomicUsize::new(0);
        let guard = files::lock(&f.dir.join("auto-launch-running.lock")).unwrap();
        assert!(f.run("during-startup", false, 1, &count).unwrap());
        assert_eq!(count.load(Ordering::Relaxed), 0);
        drop(guard);
        assert!(!f.run("during-startup", false, 2, &count).unwrap());
        assert!(f.run("new-prompt", false, 3, &count).unwrap());
        assert_eq!(count.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn failed_launch_is_bounded_and_never_retried_by_the_same_prompt() {
        let f = Fixture::new();
        let count = AtomicUsize::new(0);
        let start = Instant::now();
        assert!(launch(
            &f.dir,
            &f.settings,
            json!(["session", "failed"]),
            false,
            1,
            |_| {
                Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "launch denied",
                ))
            }
        )
        .is_err());
        assert!(start.elapsed() < Duration::from_secs(1));
        assert!(f.run("next", false, 2, &count).unwrap());
        assert_eq!(
            count.load(Ordering::Relaxed),
            0,
            "failure cooldown prevents a launch storm"
        );
        assert!(!f.run("failed", false, 20_000, &count).unwrap());
        assert!(!f.run("next", false, 20_000, &count).unwrap());
        assert!(f.run("fresh", false, 20_001, &count).unwrap());
        assert_eq!(count.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn unavailable_or_untrusted_executables_and_corrupt_state_fail_closed() {
        let f = Fixture::new();
        let count = AtomicUsize::new(0);
        for exe in [
            "coucou.exe",
            "cmd.exe",
            "C:\\missing\\coucou.exe",
            r"\\server\share\coucou.exe",
        ] {
            files::write_json(
                &f.dir.join("auto-launch-executable.json"),
                &json!({ "executable": exe }),
            )
            .unwrap();
            let _ = std::fs::remove_file(f.dir.join("auto-launch-state.json"));
            assert!(f.run(exe, false, 1, &count).is_err());
        }
        for state in [
            json!({}),
            json!({"prompts": "wrong", "retryAfter": 0}),
            json!({"prompts": ["wrong"], "retryAfter": 0}),
        ] {
            files::write_json(&f.dir.join("auto-launch-state.json"), &state).unwrap();
            assert!(f.run("t", false, 1, &count).is_err());
        }
        assert_eq!(count.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn a_stuck_launcher_cannot_block_another_hook() {
        let f = Fixture::new();
        let count = AtomicUsize::new(0);
        let _guard = files::lock(&f.dir.join("auto-launch.lock")).unwrap();
        let start = Instant::now();
        assert!(f.run("t", false, 1, &count).is_err());
        assert!(start.elapsed() < Duration::from_secs(1));
        assert_eq!(count.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn settings_reader_accepts_bom_without_rewriting_preferences() {
        let f = Fixture::new();
        let bytes = b"\xef\xbb\xbf{\"autoLaunchWithAgents\":true,\"autostart\":false,\"model\":\"unchanged\"}";
        std::fs::write(&f.settings, bytes).unwrap();
        assert!(files::enabled(&f.settings));
        assert!(f.run("t", false, 1, &AtomicUsize::new(0)).unwrap());
        assert_eq!(std::fs::read(&f.settings).unwrap(), bytes);
    }
}
