#[cfg(windows)]
#[test]
fn observers_exit_quickly_without_stdout_when_coucou_is_closed() {
    use std::io::Write;
    use std::process::{Command, Stdio};
    use std::time::{Duration, Instant};

    let root = std::env::temp_dir().join(format!("coucou hook path {}", std::process::id()));
    let cwd = root.join("working directory");
    std::fs::create_dir_all(&cwd).unwrap();
    let executable = root.join("coucou relay.exe");
    std::fs::copy(env!("CARGO_BIN_EXE_coucou-hook"), &executable).unwrap();
    assert!(executable.to_string_lossy().contains(' '));
    assert!(cwd.to_string_lossy().contains(' '));
    for (agent, payload) in [
        ("kimi-code", &include_bytes!("fixtures/kimi.json")[..]),
        ("codex", &include_bytes!("fixtures/codex.json")[..]),
        ("hermes", &include_bytes!("fixtures/hermes.json")[..]),
    ] {
        let started = Instant::now();
        let mut child = Command::new(&executable)
            .args(["--agent", agent])
            .current_dir(&cwd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(payload).unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success(), "{agent}");
        assert!(output.stdout.is_empty(), "{agent}");
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "{agent} took too long"
        );
    }
    std::fs::remove_file(&executable).unwrap();
    std::fs::remove_dir(&cwd).unwrap();
    std::fs::remove_dir(&root).unwrap();
}

#[cfg(windows)]
#[test]
fn observer_exits_with_an_unclosed_stdin_pipe() {
    use std::io::Write;
    use std::process::{Command, Stdio};
    use std::time::{Duration, Instant};

    let mut child = Command::new(env!("CARGO_BIN_EXE_coucou-hook"))
        .args(["--agent", "codex"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    stdin.write_all(include_bytes!("fixtures/codex.json")).unwrap();
    let deadline = Instant::now() + Duration::from_secs(4);
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() { break Some(status); }
        if Instant::now() >= deadline { break None; }
        std::thread::sleep(Duration::from_millis(20));
    };
    if status.is_none() {
        child.kill().unwrap();
        child.wait().unwrap();
    }
    drop(stdin);
    assert!(status.is_some_and(|status| status.success()), "observer exceeded its stdin deadline");
    let mut output = Vec::new();
    use std::io::Read;
    child.stdout.take().unwrap().read_to_end(&mut output).unwrap();
    assert!(output.is_empty());
}
