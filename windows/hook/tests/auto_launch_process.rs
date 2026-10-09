//! Native regression: hook exit, captured-pipe EOF, and the Codex Windows job.
#[cfg(windows)]
#[path = "../src/auto_launch_spawn.rs"]
mod auto_launch_spawn;
#[cfg(windows)]
#[path = "../../shared/auto_launch.rs"]
#[allow(dead_code)]
mod files;

#[cfg(windows)]
mod windows_test {
    use std::fs;
    use std::io::Read;
    use std::mem::size_of;
    use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
    use std::os::windows::process::CommandExt;
    use std::path::Path;
    use std::process::{Command, Stdio};
    use std::sync::mpsc;
    use std::time::{Duration, Instant};
    use windows::core::{BOOL, PCWSTR};
    use windows::Win32::Foundation::{HANDLE, WAIT_OBJECT_0};
    use windows::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, IsProcessInJob,
        JobObjectExtendedLimitInformation, SetInformationJobObject, TerminateJobObject,
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JOB_OBJECT_LIMIT_BREAKAWAY_OK,
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    };
    use windows::Win32::System::Threading::{
        GetExitCodeProcess, OpenProcess, TerminateProcess, WaitForSingleObject,
        PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE, PROCESS_TERMINATE,
    };

    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    use crate::files::LAUNCH_ARG;

    fn handle(value: &impl AsRawHandle) -> HANDLE {
        HANDLE(value.as_raw_handle())
    }

    struct ChildCleanup(OwnedHandle);
    impl Drop for ChildCleanup {
        fn drop(&mut self) {
            unsafe {
                let _ = TerminateProcess(handle(&self.0), 0);
                let _ = WaitForSingleObject(handle(&self.0), 2000);
            }
        }
    }

    fn deadline_file(path: &Path) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while !path.exists() {
            assert!(Instant::now() < deadline, "fixture handshake timed out");
            std::thread::sleep(Duration::from_millis(10));
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

    fn alive(process: &OwnedHandle) -> bool {
        let mut code = 0;
        unsafe {
            GetExitCodeProcess(handle(process), &mut code).unwrap();
        }
        code == 259
    }

    pub fn main() {
        if std::env::args().any(|arg| arg == LAUNCH_ARG) {
            // The simulated app stays alive without writing to hook stdout/stderr.
            std::thread::sleep(Duration::from_secs(30));
            return;
        }
        if let Some(dir) = std::env::var_os("COUCOU_PROCESS_FIXTURE") {
            let dir = std::path::PathBuf::from(dir);
            deadline_file(&dir.join("gate"));
            let exe = dir
                .join("Coucou with spaces Ω/coucou.exe")
                .canonicalize()
                .unwrap();
            let pid = if std::env::var_os("COUCOU_PROCESS_FIXED").is_some() {
                crate::auto_launch_spawn::spawn(&exe).unwrap()
            } else {
                Command::new(&exe)
                    .arg(LAUNCH_ARG)
                    .current_dir(exe.parent().unwrap())
                    .stdin(Stdio::null())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .creation_flags(CREATE_NO_WINDOW)
                    .spawn()
                    .unwrap()
                    .id()
            };
            fs::write(dir.join("pid"), pid.to_string()).unwrap();
            return;
        }
        run(false);
        run(true);
    }

    fn run(fixed: bool) {
        let dir = std::env::temp_dir().join(format!(
            "coucou-process-test-{}-{fixed}",
            std::process::id()
        ));
        fs::create_dir_all(dir.join("Coucou with spaces Ω")).unwrap();
        assert!(crate::auto_launch_spawn::spawn(&dir.join("missing/coucou.exe")).is_err());
        fs::copy(
            std::env::current_exe().unwrap(),
            dir.join("Coucou with spaces Ω/coucou.exe"),
        )
        .unwrap();
        let job = unsafe { CreateJobObjectW(None, PCWSTR::null()).unwrap() };
        let job = unsafe { OwnedHandle::from_raw_handle(job.0) };
        // Same limits as Codex CLI 0.160.1's hook job.
        let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        limits.BasicLimitInformation.LimitFlags =
            JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_BREAKAWAY_OK;
        unsafe {
            SetInformationJobObject(
                handle(&job),
                JobObjectExtendedLimitInformation,
                &limits as *const _ as *const _,
                size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            )
            .unwrap();
        }
        let mut command = Command::new(std::env::current_exe().unwrap());
        command
            .env("COUCOU_PROCESS_FIXTURE", &dir)
            .env_remove("COUCOU_PROCESS_FIXED");
        if fixed {
            command.env("COUCOU_PROCESS_FIXED", "1");
        }
        let mut relay = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .creation_flags(CREATE_NO_WINDOW)
            .spawn()
            .unwrap();
        unsafe {
            AssignProcessToJobObject(handle(&job), handle(&relay)).unwrap();
        }
        drop(relay.stdin.take());
        let out = reader(relay.stdout.take().unwrap());
        let err = reader(relay.stderr.take().unwrap());
        fs::write(dir.join("gate"), "ready").unwrap();
        deadline_file(&dir.join("pid"));
        let pid: u32 = fs::read_to_string(dir.join("pid"))
            .unwrap()
            .parse()
            .unwrap();
        let process = unsafe {
            OpenProcess(
                PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_TERMINATE | PROCESS_SYNCHRONIZE,
                false,
                pid,
            )
            .unwrap()
        };
        let process = ChildCleanup(unsafe { OwnedHandle::from_raw_handle(process.0) });
        let deadline = Instant::now() + Duration::from_secs(2);
        let status = loop {
            if let Some(status) = relay.try_wait().unwrap() {
                break status;
            }
            assert!(Instant::now() < deadline, "relay itself did not exit");
            std::thread::sleep(Duration::from_millis(10));
        };
        assert!(status.success(), "relay exited with {status}");
        assert!(alive(&process.0));
        let mut in_job = BOOL::default();
        unsafe {
            IsProcessInJob(handle(&process.0), Some(handle(&job)), &mut in_job).unwrap();
        }
        assert!(in_job.as_bool());
        if fixed {
            assert!(out.recv_timeout(Duration::from_secs(2)).unwrap().is_empty());
            assert!(err.recv_timeout(Duration::from_secs(2)).unwrap().is_empty());
            // Successful Codex hooks preserve descendants before releasing their job handle.
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_BREAKAWAY_OK;
            unsafe {
                SetInformationJobObject(
                    handle(&job),
                    JobObjectExtendedLimitInformation,
                    &limits as *const _ as *const _,
                    size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
                )
                .unwrap();
            }
            drop(job);
            std::thread::sleep(Duration::from_secs(11));
            assert!(
                alive(&process.0),
                "app died after successful hook completion"
            );
            println!("PASS fixed: relay exits, BOTH pipes reach EOF, child survives hook/job closure for more than 10s");
        } else {
            assert!(
                out.recv_timeout(Duration::from_millis(250)).is_err(),
                "baseline stdout unexpectedly reached EOF"
            );
            assert!(
                err.recv_timeout(Duration::from_millis(250)).is_err(),
                "baseline stderr unexpectedly reached EOF"
            );
            println!("PROVED baseline: relay exited 0 within 2s; live child retains BOTH capture pipes and belongs to the hook job");
            unsafe {
                TerminateJobObject(handle(&job), 1).unwrap();
            }
            assert!(out.recv_timeout(Duration::from_secs(2)).unwrap().is_empty());
            assert!(err.recv_timeout(Duration::from_secs(2)).unwrap().is_empty());
            assert_eq!(
                unsafe { WaitForSingleObject(handle(&process.0), 2000) },
                WAIT_OBJECT_0
            );
            assert!(!alive(&process.0));
            println!("PROVED baseline: timeout-style TerminateJobObject kills the child and releases pipe EOF");
            drop(job);
        }
        drop(process);
        drop(relay);
        let deadline = Instant::now() + Duration::from_secs(2);
        while let Err(err) = fs::remove_dir_all(&dir) {
            assert!(Instant::now() < deadline, "fixture cleanup failed: {err}");
            std::thread::sleep(Duration::from_millis(25));
        }
    }
}

fn main() {
    #[cfg(windows)]
    windows_test::main();
}
