//! keeps Coucou running and records why it stopped. At start-up Coucou
//! launches a second copy of itself, `coucou.exe --watchdog <pid> <quick>`,
//! which opens no window and starts no Tauri: it only waits for Coucou to end.
//! A clean quit (exit code 0) ends the watch. Anything else, a crash or a
//! forced kill, goes into coucou.log with its exit code, and Coucou is started
//! again. One that keeps dying within a minute of starting is given up on
//! after MAX_QUICK tries, so a crash at start-up can't loop forever.
//! Killing every coucou.exe by name (kill.ps1, install) stops both: deliberate.

#![cfg_attr(not(windows), allow(dead_code))]

const FLAG: &str = "--watchdog";
const MAX_QUICK: u32 = 5;
/// Carries the count of quick deaths to the restarted Coucou's own watchdog.
const QUICK_ENV: &str = "COUCOU_QUICK_RESTARTS";

/// Call first in run(): when this process is a watchdog, watches and returns true.
pub fn run_if_asked() -> bool {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(String::as_str) != Some(FLAG) {
        return false;
    }
    let pid = args.get(2).and_then(|a| a.parse().ok()).unwrap_or(0);
    let quick = args.get(3).and_then(|a| a.parse().ok()).unwrap_or(0);
    #[cfg(windows)]
    watch(pid, quick);
    #[cfg(not(windows))]
    let _ = (pid, quick);
    true
}

/// Starts this Coucou's watchdog (Windows; elsewhere nothing).
pub fn spawn() {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let quick = std::env::var(QUICK_ENV).ok().and_then(|v| v.parse::<u32>().ok()).unwrap_or(0);
        let Ok(exe) = std::env::current_exe() else { return };
        let spawned = std::process::Command::new(exe)
            .args([FLAG, &std::process::id().to_string(), &quick.to_string()])
            .creation_flags(0x0800_0000) // CREATE_NO_WINDOW
            .spawn();
        if let Err(err) = spawned {
            crate::log::line(format!("watchdog: could not start ({err})"));
        }
    }
}

/// What an exit code most likely means.
fn meaning(code: u32) -> &'static str {
    match code {
        0 => "quit normally",
        1 => "ended from outside (Task Manager, taskkill /f) or exit(1)",
        101 => "a Rust panic (see the panic line above)",
        0xC000_0005 => "crash: access violation",
        0xC000_00FD => "crash: stack overflow",
        0xC000_0409 => "crash: fail-fast (abort or buffer overrun)",
        0xC000_0017 | 0xC000_009A => "out of memory",
        0x4001_0004 => "ended by Windows (logoff, shutdown) or a debugger",
        0xCFFF_FFFF => "killed by the system",
        _ => "unknown",
    }
}

#[cfg(windows)]
fn watch(pid: u32, quick: u32) {
    use crate::log;
    use windows::Win32::Foundation::CloseHandle;
    use windows::Win32::System::Threading::{
        GetExitCodeProcess, OpenProcess, WaitForSingleObject, INFINITE,
        PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE,
    };

    let started = std::time::Instant::now();
    let code = unsafe {
        let Ok(process) = OpenProcess(PROCESS_SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else {
            return;
        };
        let _ = WaitForSingleObject(process, INFINITE);
        let mut code = 0u32;
        let _ = GetExitCodeProcess(process, &mut code);
        let _ = CloseHandle(process);
        code
    };
    let lived = started.elapsed();
    log::line(format!(
        "watchdog: Coucou ended after {} min, exit code {code:#010X}: {}",
        lived.as_secs() / 60,
        meaning(code)
    ));
    if code == 0 {
        return;
    }
    let quick = if lived.as_secs() < 60 { quick + 1 } else { 0 };
    if quick > MAX_QUICK {
        log::line(format!("watchdog: it died {MAX_QUICK} times within a minute of starting; not restarting"));
        return;
    }
    std::thread::sleep(std::time::Duration::from_secs(3));
    let Ok(exe) = std::env::current_exe() else { return };
    match std::process::Command::new(exe).env(QUICK_ENV, quick.to_string()).spawn() {
        Ok(_) => log::line("watchdog: restarted Coucou"),
        Err(err) => log::line(format!("watchdog: could not restart Coucou ({err})")),
    }
}

#[cfg(test)]
mod tests {
    use super::meaning;

    #[test]
    fn exit_codes_say_what_happened() {
        assert_eq!(meaning(0), "quit normally");
        assert!(meaning(1).contains("outside"));
        assert!(meaning(0xC000_0005).starts_with("crash"));
        assert_eq!(meaning(42), "unknown");
    }
}
