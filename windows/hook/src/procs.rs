//! What only the relay can tell about the terminal a session runs in, because
//! it is alive when it starts and gone a few milliseconds later.
//!
//! Coucou used to look at the relay's parents itself when the event reached it,
//! and for every event that does not wait for an answer the relay had already
//! exited: no parents to walk, so "Open terminal" never found a session's
//! window. Here the relay takes its own chain (`coucou_procs`: `[pid, parent,
//! exe]`, itself first) and the window in front (`coucou_foreground`: `[pid,
//! hwnd]`) and sends them with the event. The window in front, when a prompt is
//! submitted, is the session's terminal, and with it the tab the session is in.
//!
//! Only for the events that start or resume a session's use of its terminal: the
//! snapshot costs a few milliseconds, which the other events do not need to pay.

use serde_json::Value;

/// Events that carry the context.
pub fn wanted(event: &str) -> bool {
    matches!(event, "SessionStart" | "UserPromptSubmit" | "PermissionRequest")
}

/// The fields to add to the payload of `event`.
pub fn context(event: &str) -> Vec<(&'static str, Value)> {
    if !wanted(event) {
        return Vec::new();
    }
    platform::context()
}

#[cfg(windows)]
mod platform {
    use std::collections::HashMap;

    use serde_json::{json, Value};
    use windows::Win32::Foundation::CloseHandle;
    use windows::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W, TH32CS_SNAPPROCESS,
    };
    use windows::Win32::UI::WindowsAndMessaging::{GetForegroundWindow, GetWindowThreadProcessId};

    /// How many parents are sent: a session sits a handful of levels below its window.
    const MAX_CHAIN: usize = 24;

    /// pid → (parent, exe) for every process.
    fn table() -> HashMap<u32, (u32, String)> {
        let mut out = HashMap::new();
        unsafe {
            let Ok(snapshot) = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) else { return out };
            let mut entry = PROCESSENTRY32W { dwSize: std::mem::size_of::<PROCESSENTRY32W>() as u32, ..Default::default() };
            let mut more = Process32FirstW(snapshot, &mut entry).is_ok();
            while more {
                let len = entry.szExeFile.iter().position(|c| *c == 0).unwrap_or(entry.szExeFile.len());
                out.insert(
                    entry.th32ProcessID,
                    (entry.th32ParentProcessID, String::from_utf16_lossy(&entry.szExeFile[..len])),
                );
                more = Process32NextW(snapshot, &mut entry).is_ok();
            }
            let _ = CloseHandle(snapshot);
        }
        out
    }

    /// This process and its parents, nearest first. A parent ID that comes back
    /// (reused by a newer process) ends the walk.
    pub fn chain(table: &HashMap<u32, (u32, String)>, start: u32) -> Vec<(u32, u32, String)> {
        let mut out = Vec::new();
        let mut seen = Vec::new();
        let mut current = start;
        while out.len() < MAX_CHAIN && !seen.contains(&current) {
            let Some((parent, exe)) = table.get(&current) else { break };
            out.push((current, *parent, exe.clone()));
            seen.push(current);
            if *parent == 0 {
                break;
            }
            current = *parent;
        }
        out
    }

    pub fn context() -> Vec<(&'static str, Value)> {
        let mut fields = Vec::new();
        let procs: Vec<Value> = chain(&table(), std::process::id())
            .into_iter()
            .map(|(pid, parent, exe)| json!([pid, parent, exe]))
            .collect();
        if procs.len() > 1 {
            fields.push(("coucou_procs", Value::Array(procs)));
        }
        unsafe {
            let hwnd = GetForegroundWindow();
            if !hwnd.0.is_null() {
                let mut pid = 0u32;
                GetWindowThreadProcessId(hwnd, Some(&mut pid));
                if pid != 0 {
                    fields.push(("coucou_foreground", json!([pid, hwnd.0 as isize as i64])));
                }
            }
        }
        fields
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        fn table_of(rows: &[(u32, u32, &str)]) -> HashMap<u32, (u32, String)> {
            rows.iter().map(|(pid, parent, exe)| (*pid, (*parent, exe.to_string()))).collect()
        }

        #[test]
        fn the_chain_goes_up_from_the_start_and_stops_at_the_top() {
            let t = table_of(&[(1, 0, "System"), (2, 1, "wt.exe"), (3, 2, "wsl.exe"), (4, 3, "coucou-hook.exe")]);
            let c = chain(&t, 4);
            assert_eq!(c.iter().map(|(p, _, _)| *p).collect::<Vec<_>>(), [4, 3, 2, 1]);
            assert_eq!(c[0], (4, 3, "coucou-hook.exe".to_string()));
        }

        #[test]
        fn a_parent_that_loops_or_is_gone_ends_the_walk() {
            let looped = table_of(&[(1, 2, "a.exe"), (2, 1, "b.exe")]);
            assert_eq!(chain(&looped, 1).len(), 2);
            let orphan = table_of(&[(5, 99, "x.exe")]);
            assert_eq!(chain(&orphan, 5).len(), 1);
            assert!(chain(&orphan, 7).is_empty());
            let deep: Vec<(u32, u32, &str)> = (1..100).map(|i| (i, i + 1, "x.exe")).collect();
            assert_eq!(chain(&table_of(&deep), 1).len(), MAX_CHAIN);
        }

        #[test]
        fn the_real_relay_sees_itself_and_a_parent() {
            let fields = context();
            let procs = fields.iter().find(|(k, _)| *k == "coucou_procs").map(|(_, v)| v.clone());
            let first = procs.as_ref().and_then(|v| v[0][0].as_u64());
            assert_eq!(first, Some(std::process::id() as u64));
        }
    }
}

#[cfg(not(windows))]
mod platform {
    use serde_json::Value;

    pub fn context() -> Vec<(&'static str, Value)> {
        Vec::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_events_that_start_a_sessions_use_of_its_terminal_carry_it() {
        for event in ["SessionStart", "UserPromptSubmit", "PermissionRequest"] {
            assert!(wanted(event), "{event}");
        }
        for event in ["PreToolUse", "PostToolUse", "Stop", "SessionEnd", "Notification", ""] {
            assert!(!wanted(event), "{event}");
            assert!(context(event).is_empty(), "{event}");
        }
    }
}
