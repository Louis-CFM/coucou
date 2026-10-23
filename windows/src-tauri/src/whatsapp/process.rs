// GOWA started by Coucou ("Start GOWA automatically", or after "Install WhatsApp"): a child of
// Coucou, on the address set in Settings, stopped when Coucou quits. Port of WhatsAppGOWAProcess.swift.

use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use reqwest::Url;

use super::gateway::gowa;

struct Running {
    child: Option<Child>,
    last_start: Option<Instant>,
    /// What the running GOWA was started with: changed, it is restarted; same, left alone.
    launched_with: Option<String>,
}

static STATE: Mutex<Running> = Mutex::new(Running { child: None, last_start: None, launched_with: None });

/// Where GOWA keeps its own WhatsApp session (its database, not Coucou's), and where Coucou
/// puts the binary it installs: the link survives restarts.
pub fn working_dir() -> PathBuf {
    crate::platform::local_dir().join("GOWA")
}

pub fn installed_binary() -> PathBuf {
    working_dir().join(if cfg!(windows) { "gowa.exe" } else { "gowa" })
}

/// A file Coucou may start: there, a file, and on Linux executable.
pub fn is_runnable(path: &Path) -> bool {
    let Ok(meta) = std::fs::metadata(path) else { return false };
    if !meta.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        meta.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        path.extension().is_some_and(|e| e.eq_ignore_ascii_case("exe"))
    }
}

/// Only ever on this computer: an address elsewhere is someone else's gateway.
pub fn local_port(url: &Url) -> Option<u16> {
    let host = url.host_str()?.trim_start_matches('[').trim_end_matches(']');
    matches!(host, "127.0.0.1" | "localhost" | "::1").then(|| url.port_or_known_default()).flatten()
}

fn expand(path: &str) -> PathBuf {
    match path.strip_prefix("~/").or_else(|| path.strip_prefix("~\\")) {
        Some(rest) => crate::platform::home_dir().join(rest),
        None => PathBuf::from(path),
    }
}

pub fn is_running() -> bool {
    let mut s = STATE.lock().unwrap();
    match s.child.as_mut() {
        Some(child) => matches!(child.try_wait(), Ok(None)),
        None => false,
    }
}

/// Brings GOWA in line with Settings: started when asked to (and the gateway is GOWA on this
/// computer), restarted only when its binary, address or password changed, stopped otherwise. A
/// GOWA that keeps dying is started again once a minute at most. False when it can't run.
pub fn sync(wanted: bool, binary: &str, url: &str, credential: &str) -> bool {
    if !wanted {
        stop_now();
        return false;
    }
    let path = expand(binary.trim());
    let Some(port) = Url::parse(url.trim()).ok().as_ref().and_then(local_port) else {
        stop_now();
        return false;
    };
    if binary.trim().is_empty() || !is_runnable(&path) {
        crate::log::line("whatsapp: GOWA binary missing or not runnable");
        stop_now();
        return false;
    }
    let signature = [path.to_string_lossy().as_ref(), url.trim(), credential].join("\u{1F}");
    let mut s = STATE.lock().unwrap();
    let alive = s.child.as_mut().is_some_and(|c| matches!(c.try_wait(), Ok(None)));
    if alive {
        if s.launched_with.as_deref() == Some(&signature) {
            return true;
        }
        stop_locked(&mut s); // waits for it to let go of the port and its database
    } else if s.launched_with.as_deref() == Some(&signature) && s.last_start.is_some_and(|t| t.elapsed() < Duration::from_secs(60)) {
        return true;
    }
    let dir = working_dir();
    if let Err(err) = crate::platform::ensure_private_dir(&dir) {
        crate::log::line(format!("whatsapp: GOWA folder: {err}"));
        return false;
    }
    let mut cmd = Command::new(&path);
    cmd.args(gowa::launch_arguments(port))
        .current_dir(&dir)
        // GOWA's own output may name contacts or quote messages: it goes nowhere.
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        // Its own web dashboard is not needed (Coucou is the interface).
        .env("APP_UI_ENABLED", "false");
    // The credential goes through the environment, not the command line (any user sees that).
    if credential.contains(':') {
        cmd.env("APP_BASIC_AUTH", credential);
    } else {
        cmd.env_remove("APP_BASIC_AUTH");
    }
    crate::platform::no_console(&mut cmd);
    match cmd.spawn() {
        Ok(child) => {
            crate::log::line(format!("whatsapp: GOWA started (pid {})", child.id()));
            s.child = Some(child);
            s.last_start = Some(Instant::now());
            s.launched_with = Some(signature);
            true
        }
        Err(err) => {
            crate::log::line(format!("whatsapp: GOWA could not start: {err}"));
            s.last_start = Some(Instant::now());
            false
        }
    }
}

fn stop_locked(s: &mut Running) {
    s.launched_with = None;
    let Some(mut child) = s.child.take() else { return };
    if !matches!(child.try_wait(), Ok(None)) {
        return;
    }
    // Asked politely first on Linux, so it closes its database; Windows has no such signal for a
    // console-less child, and GOWA writes its session as it goes.
    #[cfg(target_os = "linux")]
    unsafe {
        libc::kill(child.id() as libc::pid_t, libc::SIGTERM);
    }
    #[cfg(not(target_os = "linux"))]
    let _ = child.kill();
    let deadline = Instant::now() + Duration::from_secs(1);
    while Instant::now() < deadline {
        if !matches!(child.try_wait(), Ok(None)) {
            return;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    let _ = child.kill();
    let _ = child.wait();
}

/// Stops GOWA if Coucou started it, waiting a second at most (at quit, or before starting it
/// again so two never share its database).
pub fn stop_now() {
    stop_locked(&mut STATE.lock().unwrap());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_on_this_computer() {
        let port = |u: &str| local_port(&Url::parse(u).unwrap());
        assert_eq!(port("http://127.0.0.1:3000"), Some(3000));
        assert_eq!(port("http://localhost:3001/"), Some(3001));
        assert_eq!(port("http://[::1]:3002"), Some(3002));
        assert_eq!(port("http://127.0.0.1"), Some(80));
        assert_eq!(port("http://192.168.1.4:3000"), None);
        assert_eq!(port("http://gowa.example.com:3000"), None);
    }

    #[test]
    fn nothing_runs_without_a_binary() {
        assert!(!sync(true, "", "http://127.0.0.1:3000", ""));
        assert!(!sync(true, "/no/such/gowa", "http://127.0.0.1:3000", ""));
        assert!(!is_running());
        assert!(!is_runnable(&std::env::temp_dir()), "a folder is not a binary");
    }
}
