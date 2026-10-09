//! Native Windows: actual relay, isolated preferences, shared launch and named-pipe delivery.
#[cfg(windows)]
#[path = "../../shared/auto_launch.rs"]
#[allow(dead_code)]
mod files;
#[cfg(windows)]
#[path = "../src/win.rs"]
mod win;
#[cfg(windows)]
const CONNECT_TIMEOUT: std::time::Duration = std::time::Duration::from_millis(300);

#[cfg(windows)]
mod native {
    use serde_json::{json, Value};
    use std::fs::{self, File, OpenOptions};
    use std::io::{BufRead, BufReader, Read, Write};
    use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
    use std::os::windows::process::CommandExt;
    use std::path::PathBuf;
    use std::process::{Command, Stdio};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{mpsc, Barrier};
    use std::time::{Duration, Instant};
    use windows::core::PCWSTR;
    use windows::Win32::Foundation::{ERROR_PIPE_CONNECTED, HANDLE};
    use windows::Win32::Storage::FileSystem::{FILE_FLAG_FIRST_PIPE_INSTANCE, PIPE_ACCESS_DUPLEX};
    use windows::Win32::System::Pipes::{
        ConnectNamedPipe, CreateNamedPipeW, DisconnectNamedPipe, PIPE_TYPE_BYTE, PIPE_WAIT,
    };
    use windows::Win32::System::Threading::{
        OpenProcess, TerminateProcess, WaitForSingleObject, PROCESS_QUERY_LIMITED_INFORMATION,
        PROCESS_SYNCHRONIZE, PROCESS_TERMINATE,
    };

    const NO_WINDOW: u32 = 0x0800_0000;

    fn pipe_name() -> String {
        format!(
            r"\\.\pipe\coucou-{}",
            crate::win::current_user_sid().unwrap()
        )
    }

    fn server(name: &str) -> std::io::Result<File> {
        let name: Vec<u16> = name.encode_utf16().chain(Some(0)).collect();
        let handle = unsafe {
            CreateNamedPipeW(
                PCWSTR(name.as_ptr()),
                PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
                PIPE_TYPE_BYTE | PIPE_WAIT,
                1,
                4096,
                4096,
                0,
                None,
            )
        };
        if handle.is_invalid() {
            return Err(std::io::Error::last_os_error());
        }
        Ok(unsafe { File::from_raw_handle(handle.0) })
    }

    fn app() {
        let dir = PathBuf::from(std::env::var_os("COUCOU_RELAY_FIXTURE").unwrap());
        let error_file = dir.join("app-error");
        std::panic::set_hook(Box::new(move |info| {
            let _ = fs::write(&error_file, info.to_string());
        }));
        let Ok(_running) = crate::files::lock(
            &crate::files::local_dir()
                .unwrap()
                .join("auto-launch-running.lock"),
        ) else {
            return;
        };
        fs::write(dir.join("app-pid"), std::process::id().to_string()).unwrap();
        let mut events = OpenOptions::new()
            .create(true)
            .append(true)
            .open(dir.join("events"))
            .unwrap();
        loop {
            let file = server(&pipe_name()).unwrap();
            let handle = HANDLE(file.as_raw_handle());
            let result = unsafe { ConnectNamedPipe(handle, None) };
            if let Err(err) = result {
                assert_eq!(err.code(), ERROR_PIPE_CONNECTED.to_hresult());
            }
            let mut line = Vec::new();
            BufReader::new(&file).read_until(b'\n', &mut line).unwrap();
            if !line.is_empty() {
                let payload: Value = serde_json::from_slice(&line).unwrap();
                writeln!(events, "{payload}").unwrap();
                events.flush().unwrap();
            }
            let _ = unsafe { DisconnectNamedPipe(handle) };
        }
    }

    struct Fixture {
        dir: PathBuf,
    }
    impl Fixture {
        fn new(enabled: bool) -> Self {
            static COUNT: AtomicUsize = AtomicUsize::new(0);
            let dir = std::env::temp_dir().join(format!(
                "coucou-relay-test-{}-{}",
                std::process::id(),
                COUNT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(dir.join("local/Coucou")).unwrap();
            fs::create_dir_all(dir.join("roaming/Coucou")).unwrap();
            fs::create_dir_all(dir.join("Coucou with spaces Ω")).unwrap();
            let exe = dir.join("Coucou with spaces Ω/coucou.exe");
            fs::copy(std::env::current_exe().unwrap(), &exe).unwrap();
            crate::files::write_json(
                &dir.join("roaming/Coucou/settings.json"),
                &json!({"autoLaunchWithAgents":enabled, "autostart":false}),
            )
            .unwrap();
            crate::files::write_json(
                &dir.join("local/Coucou/auto-launch-executable.json"),
                &json!({"executable":exe}),
            )
            .unwrap();
            Self { dir }
        }

        fn hook(&self, agent: &str, mut payload: Value) {
            let started = Instant::now();
            if agent == "claude-code" {
                let transcript = self.dir.join("claude-transcript.jsonl");
                fs::write(&transcript, b"fixture transcript").unwrap();
                payload["transcript_path"] = json!(transcript);
            }
            let mut command = Command::new(env!("CARGO_BIN_EXE_coucou-hook"));
            if agent != "claude-code" {
                command.args(["--agent", agent]);
            }
            if agent == "antigravity" {
                command.arg("PreInvocation");
            }
            let mut relay = command
                .env("APPDATA", self.dir.join("roaming"))
                .env("LOCALAPPDATA", self.dir.join("local"))
                .env("COUCOU_RELAY_FIXTURE", &self.dir)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .creation_flags(NO_WINDOW)
                .spawn()
                .unwrap();
            writeln!(relay.stdin.take().unwrap(), "{payload}").unwrap();
            let out = reader(relay.stdout.take().unwrap());
            let err = reader(relay.stderr.take().unwrap());
            let status = loop {
                if let Some(status) = relay.try_wait().unwrap() {
                    break status;
                }
                if started.elapsed() >= Duration::from_secs(3) {
                    let _ = relay.kill();
                    panic!("relay exceeded its deadline");
                }
                std::thread::sleep(Duration::from_millis(10));
            };
            assert!(status.success());
            let output = out.recv_timeout(Duration::from_secs(1)).unwrap();
            if agent == "antigravity" {
                assert_eq!(String::from_utf8(output).unwrap().trim(), "{}");
            } else {
                assert!(output.is_empty(), "unexpected protocol output");
            }
            assert!(
                err.recv_timeout(Duration::from_secs(1)).unwrap().is_empty(),
                "unexpected stderr"
            );
            assert!(started.elapsed() < Duration::from_secs(3));
        }

        fn events(&self, expected: usize) -> Vec<Value> {
            let deadline = Instant::now() + Duration::from_secs(3);
            loop {
                let events: Vec<Value> = fs::read_to_string(self.dir.join("events"))
                    .unwrap_or_default()
                    .lines()
                    .map(|line| serde_json::from_str(line).unwrap())
                    .collect();
                if events.len() >= expected {
                    return events;
                }
                assert!(
                    Instant::now() < deadline,
                    "named-pipe events did not arrive: {}",
                    fs::read_to_string(self.dir.join("app-error")).unwrap_or_default()
                );
                std::thread::sleep(Duration::from_millis(10));
            }
        }

        fn process(&self) -> windows::core::Result<OwnedHandle> {
            let pid: u32 = fs::read_to_string(self.dir.join("app-pid"))
                .unwrap()
                .parse()
                .unwrap();
            let handle = unsafe {
                OpenProcess(
                    PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SYNCHRONIZE | PROCESS_TERMINATE,
                    false,
                    pid,
                )?
            };
            Ok(unsafe { OwnedHandle::from_raw_handle(handle.0) })
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            if self.dir.join("app-pid").exists() {
                if let Ok(process) = self.process() {
                    unsafe {
                        let handle = HANDLE(process.as_raw_handle());
                        let _ = TerminateProcess(handle, 0);
                        let _ = WaitForSingleObject(handle, 2000);
                    }
                }
            }
            let deadline = Instant::now() + Duration::from_secs(2);
            while let Err(err) = fs::remove_dir_all(&self.dir) {
                assert!(Instant::now() < deadline, "fixture cleanup failed: {err}");
                std::thread::sleep(Duration::from_millis(25));
            }
        }
    }

    fn reader(mut stream: impl Read + Send + 'static) -> mpsc::Receiver<Vec<u8>> {
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let mut bytes = Vec::new();
            stream.read_to_end(&mut bytes).unwrap();
            let _ = tx.send(bytes);
        });
        rx
    }

    fn payload(agent: &str) -> Value {
        if agent == "hermes" {
            json!({"hook_event_name":"SessionStart", "session_id":"same-session", "platform":"cli"})
        } else if agent == "antigravity" {
            json!({"conversationId":"ec33ebf9-0cba-4100-8142-c61503f6c587", "invocationNum":0, "initialNumSteps":0})
        } else if agent == "claude-code" {
            json!({"hook_event_name":"UserPromptSubmit", "session_id":"same-session", "prompt":"private input"})
        } else {
            json!({"hook_event_name":"UserPromptSubmit", "session_id":"same-session", "turn_id":"t", "prompt":"private input"})
        }
    }

    pub fn main() {
        if std::env::args().any(|arg| arg == crate::files::LAUNCH_ARG) {
            app();
            return;
        }
        // Never take the real user's pipe or interfere with a Coucou already running.
        if crate::win::connect().is_some() {
            println!("SKIP auto_launch_relay: Coucou's real pipe is in use; quit it before rerunning this fixture");
            return;
        }
        {
            let f = Fixture::new(false);
            for agent in ["hermes", "codex", "opencode", "claude-code", "antigravity"] {
                f.hook(agent, payload(agent));
            }
            assert!(!f.dir.join("app-pid").exists());
            assert!(!f.dir.join("local/Coucou/auto-launch-state.json").exists());
            println!("PASS OFF: no supported agent launches or writes the ledger");
        }
        // Also detect an existing server that this runner is not permitted to connect to.
        match server(&pipe_name()) {
            Ok(pipe) => drop(pipe),
            Err(err) if err.raw_os_error() == Some(5) => {
                println!("SKIP named-pipe/ON scenarios: Coucou's pipe is in use or inaccessible ({err}); quit Coucou and rerun in a Windows terminal");
                return;
            }
            Err(err) => panic!("cannot create the test pipe: {err}"),
        }
        {
            let f = Fixture::new(true);
            for invalid in [
                json!({"hook_event_name":"SessionStart"}),
                json!({"hook_event_name":"startup", "session_id":"h"}),
                json!({"hook_event_name":"SessionStart", "session_id":42}),
                json!({"hook_event_name":"SessionStart", "sessionId":"h"}),
                json!({"hook_event_name":"UserPromptSubmit", "session_id":"h"}),
                json!({"hook_event_name":"UserPromptSubmit", "session_id":"h", "turn_id":""}),
                json!({"hook_event_name":"Stop", "session_id":"h"}),
            ] {
                f.hook("hermes", invalid);
                assert!(!f.dir.join("app-pid").exists());
            }
            f.hook("codex", payload("codex"));
            assert_eq!(f.events(1)[0]["coucou_agent"], "codex");
            println!("PASS invalid Hermes events cannot launch or prevent Codex launching");
        }
        for agents in [["hermes", "codex"], ["codex", "hermes"]] {
            let f = Fixture::new(true);
            f.hook(agents[0], payload(agents[0]));
            let pid = fs::read_to_string(f.dir.join("app-pid")).unwrap();
            f.hook(agents[1], payload(agents[1]));
            let events = f.events(2);
            assert_eq!(events[0]["coucou_agent"], agents[0]);
            assert_eq!(events[1]["coucou_agent"], agents[1]);
            assert_eq!(fs::read_to_string(f.dir.join("app-pid")).unwrap(), pid);
            for agent in agents {
                f.hook(
                    agent,
                    json!({"hook_event_name":"SessionEnd", "session_id":"same-session"}),
                );
            }
            assert_eq!(f.events(4).len(), 4);
            let process = f.process().unwrap();
            assert_eq!(
                unsafe { WaitForSingleObject(HANDLE(process.as_raw_handle()), 250) }.0,
                258,
                "app died after hook/session completion"
            );
            println!(
                "PASS {} then {}: same surviving app, both events forwarded",
                agents[0], agents[1]
            );
        }
        {
            let f = Fixture::new(true);
            f.hook("antigravity", payload("antigravity"));
            let pid = fs::read_to_string(f.dir.join("app-pid")).unwrap();
            f.hook(
                "antigravity",
                json!({
                    "conversationId":"7c619818-5c45-4e67-910e-f1dd3cffcb83",
                    "invocationNum":0, "initialNumSteps":0
                }),
            );
            let events = f.events(2);
            assert_eq!(
                events[0]["session_id"],
                "ec33ebf9-0cba-4100-8142-c61503f6c587"
            );
            assert_eq!(
                events[1]["session_id"],
                "7c619818-5c45-4e67-910e-f1dd3cffcb83"
            );
            assert_eq!(fs::read_to_string(f.dir.join("app-pid")).unwrap(), pid);
            let log = fs::read_to_string(f.dir.join("local/Coucou/auto-launch.log")).unwrap();
            assert_eq!(log.matches("spawned app_pid=").count(), 1);
            println!("PASS Antigravity and IDE payloads: one app, separate conversations");
        }
        {
            let f = Fixture::new(true);
            for agent in ["opencode", "claude-code", "hermes", "codex"] {
                f.hook(agent, payload(agent));
            }
            let events = f.events(4);
            assert_eq!(events[0]["coucou_agent"], "opencode");
            assert!(events[1].get("coucou_agent").is_none());
            assert_eq!(events[2]["coucou_agent"], "hermes");
            assert_eq!(events[3]["coucou_agent"], "codex");
            let log = fs::read_to_string(f.dir.join("local/Coucou/auto-launch.log")).unwrap();
            assert_eq!(log.matches("spawned app_pid=").count(), 1);
            assert!(!log.contains("private input"));
            println!("PASS four agents: one surviving app and no prompt in launch log");
        }
        for agent in ["opencode", "claude-code"] {
            let f = Fixture::new(true);
            f.hook(agent, payload(agent));
            f.hook(agent, payload(agent));
            assert_eq!(f.events(2).len(), 2);
            let log = fs::read_to_string(f.dir.join("local/Coucou/auto-launch.log")).unwrap();
            assert_eq!(log.matches("spawned app_pid=").count(), 1);
            println!("PASS {agent} resumed/duplicate events reuse one app");
        }
        {
            let f = Fixture::new(true);
            f.hook("hermes", json!({"hook_event_name":"UserPromptSubmit", "session_id":"resumed-session", "turn_id":"resumed-turn"}));
            assert_eq!(f.events(1)[0]["coucou_agent"], "hermes");
            let process = f.process().unwrap();
            assert_eq!(
                unsafe { WaitForSingleObject(HANDLE(process.as_raw_handle()), 250) }.0,
                258
            );
            println!("PASS resumed Hermes turn: one surviving app without SessionStart");
        }
        {
            let f = Fixture::new(true);
            let barrier = Barrier::new(4);
            std::thread::scope(|scope| {
                for agent in ["hermes", "codex", "opencode", "claude-code"] {
                    let f = &f;
                    let barrier = &barrier;
                    scope.spawn(move || {
                        barrier.wait();
                        f.hook(agent, payload(agent));
                    });
                }
            });
            let events = f.events(4);
            for agent in ["hermes", "codex", "opencode"] {
                assert!(events.iter().any(|event| event["coucou_agent"] == agent));
            }
            assert!(events
                .iter()
                .any(|event| event.get("coucou_agent").is_none()));
            let log = fs::read_to_string(f.dir.join("local/Coucou/auto-launch.log")).unwrap();
            assert_eq!(log.matches("spawned app_pid=").count(), 1);
            assert!(!log.contains("worker_deadline=true"));
            assert!(!log.contains("private input"));
            println!(
                "PASS simultaneous four agents: exactly one spawn, all events, no worker timeout"
            );
        }
    }
}

fn main() {
    #[cfg(windows)]
    native::main();
}
