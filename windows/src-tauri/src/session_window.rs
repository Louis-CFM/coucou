// "Open terminal" brings the window a Claude Code session runs in to the front,
// instead of opening its folder in VS Code (Mac 0.1.0: jump to the terminal).
//
// The relay is a grandchild of Claude Code, which runs in a shell, which runs
// in the terminal or editor whose window we want. When the relay connects, its
// process is still alive, so walking up from it finds that window's process.
// What is found is kept per session ID, here in memory only, and looked up when
// the button is clicked. Where nothing is found — a classic console, whose
// window belongs to a conhost that is no ancestor, or Linux — the island falls
// back to VS Code as before.
//
// On Linux the same walk reads /proc. Which ancestor owns the window is only
// asked when the button is clicked (the display server answers then, not from
// the relay's thread), so every ancestor is kept, nearest first; on Windows
// only the one that owns a window.
//
// The OS calls live in platform/; this file is the logic, tested on fixtures.

use std::collections::HashMap;
use std::sync::Mutex;

/// One process as a snapshot lists it.
#[derive(Debug, Clone)]
pub struct Proc {
    pub parent: u32,
    /// The executable's file name, as the snapshot gives it (`Code.exe`); on
    /// Linux the process name from /proc (`gnome-terminal-`, at most 15 bytes).
    pub exe: String,
}

/// Never the window of a session: the desktop shell and the services that sit
/// at the top of every process tree. Reaching one of them means the terminal
/// window was not an ancestor (a classic console window belongs to conhost).
#[cfg_attr(not(windows), allow(dead_code))]
const WINDOWS_TREE_TOPS: &[&str] = &[
    "explorer.exe", "services.exe", "wininit.exe", "winlogon.exe", "svchost.exe",
    "smss.exe", "csrss.exe", "system", "sihost.exe", "userinit.exe",
];

/// The same on Linux, lower-cased and cut to the 15 bytes /proc keeps of a
/// name: init and the user's service manager, logins (local, display manager,
/// ssh), session managers, and the compositors, window managers and panels
/// that own windows of their own — reaching one means the session's terminal
/// was not an ancestor (tmux, screen, ssh), and raising the panel would be
/// wrong. PID 1 and processes of other users end the walk anyway
/// (platform/linux.rs leaves them out of the table).
#[cfg_attr(windows, allow(dead_code))]
const LINUX_TREE_TOPS: &[&str] = &[
    "systemd", "init", "sshd", "sshd-session", "login", "su", "sudo", "doas",
    "gdm-session-wor", "gdm-x-session", "gdm-wayland-ses", "sddm", "sddm-helper",
    "lightdm", "lxdm-session", "greetd", "xinit", "xorg", "xwayland",
    "dbus-daemon", "dbus-broker", "dbus-broker-lau",
    "gnome-session-b", "gnome-session", "gnome-shell",
    "startplasma-x11", "startplasma-way", "plasma_session", "ksmserver",
    "plasmashell", "kwin_x11", "kwin_wayland",
    "xfce4-session", "xfce4-panel", "xfdesktop", "xfwm4",
    "cinnamon-sessio", "cinnamon", "cinnamon-launch", "mate-session", "mate-panel",
    "marco", "lxsession", "lxqt-session", "lxqt-panel", "lxpanel", "openbox",
    "budgie-wm", "budgie-panel", "cosmic-session", "cosmic-comp", "cosmic-panel",
    "sway", "hyprland", "niri", "labwc", "wayfire", "river", "i3", "awesome",
    "bspwm", "waybar",
];

#[cfg(windows)]
const TREE_TOPS: &[&str] = WINDOWS_TREE_TOPS;
#[cfg(not(windows))]
const TREE_TOPS: &[&str] = LINUX_TREE_TOPS;

/// How far up we look. A session sits a handful of levels below its window.
pub const MAX_DEPTH: usize = 16;

/// The ancestors of `start`, nearest first, stopping before the top of the
/// tree. `start` itself — the relay — is not included. A loop in the parent
/// links (a parent ID reused by a newer process) ends the walk.
pub fn ancestors(procs: &HashMap<u32, Proc>, start: u32) -> Vec<u32> {
    ancestors_below(procs, start, TREE_TOPS)
}

fn ancestors_below(procs: &HashMap<u32, Proc>, start: u32, tops: &[&str]) -> Vec<u32> {
    let mut out = Vec::new();
    let mut seen = vec![start];
    let mut current = start;
    while out.len() < MAX_DEPTH {
        let Some(proc) = procs.get(&current) else { break };
        let parent = proc.parent;
        if parent == 0 || seen.contains(&parent) {
            break;
        }
        let Some(up) = procs.get(&parent) else { break };
        if tops.contains(&up.exe.to_ascii_lowercase().as_str()) {
            break;
        }
        out.push(parent);
        seen.push(parent);
        current = parent;
    }
    out
}

/// The nearest ancestor that owns a window: the terminal or the editor. The
/// Windows side walks `ancestors` itself (platform/windows.rs); this states the
/// rule the tests pin down.
#[cfg(test)]
pub fn window_owner(procs: &HashMap<u32, Proc>, start: u32, has_window: impl Fn(u32) -> bool) -> Option<u32> {
    ancestors_below(procs, start, WINDOWS_TREE_TOPS).into_iter().find(|pid| has_window(*pid))
}

/// `/proc/<pid>/stat` → (name, parent). The name sits between the first `(`
/// and the LAST `)`: it may itself hold spaces and parentheses (`tmux: server`,
/// `Web Content`, `a) b (c`), so splitting on spaces would misread the parent.
#[cfg_attr(windows, allow(dead_code))]
pub fn parse_stat(line: &str) -> Option<(String, u32)> {
    let open = line.find('(')?;
    let close = line.rfind(')')?;
    if close < open {
        return None;
    }
    let name = &line[open + 1..close];
    let mut rest = line[close + 1..].split_ascii_whitespace();
    let _state = rest.next()?;
    let parent = rest.next()?.parse().ok()?;
    Some((name.to_string(), parent))
}

/// Of the windows on screen — (window, owner process, title) — the one to
/// bring forward: the windows of the nearest ancestor that has any, and among
/// them the one titled after the session's folder (see `pick_window`).
#[cfg_attr(windows, allow(dead_code))]
pub fn choose_window<'a, W>(ancestors: &[u32], windows: &'a [(W, u32, String)], folder: &str) -> Option<&'a W> {
    ancestors.iter().find_map(|pid| {
        let mine: Vec<(&'a W, String)> = windows
            .iter()
            .filter(|(_, owner, _)| owner == pid)
            .map(|(w, _, title)| (w, title.clone()))
            .collect();
        pick_window(&mine, folder).copied()
    })
}

/// Which of a process's windows to bring forward: the one whose title names
/// the session's folder (an editor with several projects open), else the first.
pub fn pick_window<'a, W>(windows: &'a [(W, String)], folder: &str) -> Option<&'a W> {
    let folder = folder.to_lowercase();
    let named = (!folder.is_empty())
        .then(|| windows.iter().find(|(_, title)| title.to_lowercase().contains(&folder)))
        .flatten();
    named.or_else(|| windows.first()).map(|(w, _)| w)
}

/// The last folder name of a path, either separator.
pub fn folder_name(path: &str) -> &str {
    path.trim_end_matches(['/', '\\']).rsplit(['/', '\\']).next().unwrap_or_default()
}

// ── Sessions seen so far ──────────────────────────────────────────────────────

/// Session ID → the processes that may own its window, nearest first: the one
/// that does on Windows, every ancestor on Linux. Empty for a session whose
/// window could not be found, so it is not looked for on every event. Small:
/// an old session is dropped once there are more than this many.
const MAX_SESSIONS: usize = 64;

static SESSIONS: Mutex<Vec<(String, Vec<u32>)>> = Mutex::new(Vec::new());

/// A session ID arrives in a hook payload: only what Claude Code sends (a
/// UUID) is kept, at most 128 characters.
fn valid_session(id: &str) -> bool {
    !id.is_empty() && id.len() <= 128 && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

pub fn remember(session: &str, mut owners: Vec<u32>) {
    if !valid_session(session) {
        return;
    }
    owners.truncate(MAX_DEPTH);
    let mut list = SESSIONS.lock().unwrap_or_else(|e| e.into_inner());
    list.retain(|(s, _)| s != session);
    list.push((session.to_string(), owners));
    let excess = list.len().saturating_sub(MAX_SESSIONS);
    list.drain(..excess);
}

/// True once the session has been looked at, window found or not.
pub fn known(session: &str) -> bool {
    let list = SESSIONS.lock().unwrap_or_else(|e| e.into_inner());
    list.iter().any(|(s, _)| s == session)
}

/// The processes that may own the session's window, nearest first, if any.
pub fn lookup(session: &str) -> Option<Vec<u32>> {
    let list = SESSIONS.lock().unwrap_or_else(|e| e.into_inner());
    list.iter().find(|(s, _)| s == session).map(|(_, pids)| pids.clone()).filter(|pids| !pids.is_empty())
}

pub fn forget(session: &str) {
    SESSIONS.lock().unwrap_or_else(|e| e.into_inner()).retain(|(s, _)| s != session);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tree(entries: &[(u32, u32, &str)]) -> HashMap<u32, Proc> {
        entries
            .iter()
            .map(|(pid, parent, exe)| (*pid, Proc { parent: *parent, exe: exe.to_string() }))
            .collect()
    }

    #[test]
    fn windows_terminal_is_found_above_the_shells() {
        // WindowsTerminal → pwsh → claude (node) → bash → nova-hook
        let procs = tree(&[
            (4, 0, "System"),
            (100, 4, "explorer.exe"),
            (200, 100, "WindowsTerminal.exe"),
            (300, 200, "pwsh.exe"),
            (400, 300, "node.exe"),
            (500, 400, "bash.exe"),
            (600, 500, "nova-hook.exe"),
        ]);
        assert_eq!(ancestors_below(&procs, 600, WINDOWS_TREE_TOPS), [500, 400, 300, 200]);
        assert_eq!(window_owner(&procs, 600, |pid| pid == 200 || pid == 100), Some(200));
    }

    #[test]
    fn vs_code_is_found_through_its_pty_host() {
        let procs = tree(&[
            (100, 1, "explorer.exe"),
            (210, 100, "Code.exe"),
            (220, 210, "Code.exe"),
            (300, 220, "powershell.exe"),
            (400, 300, "node.exe"),
            (600, 400, "nova-hook.exe"),
        ]);
        assert_eq!(window_owner(&procs, 600, |pid| pid == 210), Some(210));
    }

    #[test]
    fn a_classic_console_finds_nothing_rather_than_the_desktop() {
        // cmd.exe's window belongs to conhost, which is not an ancestor; the
        // walk must stop at explorer instead of picking the taskbar.
        let procs = tree(&[
            (100, 1, "explorer.exe"),
            (300, 100, "cmd.exe"),
            (400, 300, "node.exe"),
            (600, 400, "nova-hook.exe"),
        ]);
        assert_eq!(window_owner(&procs, 600, |pid| pid == 100), None);
    }

    #[test]
    fn a_relay_already_gone_or_a_loop_ends_the_walk() {
        assert!(ancestors(&tree(&[]), 600).is_empty());
        let looped = tree(&[(1, 2, "a.exe"), (2, 1, "b.exe"), (3, 1, "nova-hook.exe")]);
        assert_eq!(ancestors(&looped, 3), [1, 2]);
        let deep: Vec<(u32, u32, &str)> = (1..100).map(|i| (i, i + 1, "x.exe")).collect();
        assert_eq!(ancestors(&tree(&deep), 1).len(), MAX_DEPTH);
    }

    // ── Linux ──

    fn linux(entries: &[(u32, u32, &str)]) -> Vec<u32> {
        // platform/linux.rs leaves PID 1 out of the table; so do the fixtures.
        let start = entries.last().unwrap().0;
        ancestors_below(&tree(entries), start, LINUX_TREE_TOPS)
    }

    #[test]
    fn stat_lines_are_read_around_odd_process_names() {
        let line = "4242 (gnome-terminal-) S 1337 4242 4242 0 -1 4194560 2 0 0 0";
        assert_eq!(parse_stat(line), Some(("gnome-terminal-".to_string(), 1337)));
        // Spaces and parentheses in the name: only the last ')' ends it.
        let odd = "77 (a) b (c) S 12 77 77 34816 77";
        assert_eq!(parse_stat(odd), Some(("a) b (c".to_string(), 12)));
        assert_eq!(parse_stat("9 (tmux: server) S 1 9 9 0"), Some(("tmux: server".to_string(), 1)));
        assert_eq!(parse_stat("10 (Web Content) R 8 8 8"), Some(("Web Content".to_string(), 8)));
        assert_eq!(parse_stat("11 () S 2 0"), Some((String::new(), 2)));
        // Broken or cut short: nothing.
        assert_eq!(parse_stat(""), None);
        assert_eq!(parse_stat("12 (x S 3"), None);
        assert_eq!(parse_stat("13 )x( S 3"), None);
        assert_eq!(parse_stat("14 (x) S"), None);
        assert_eq!(parse_stat("15 (x) S -3"), None);
        assert_eq!(parse_stat("16 (x) S abc"), None);
    }

    #[test]
    fn linux_terminals_are_found_below_the_service_manager() {
        // systemd --user → gnome-terminal-server → bash → claude → sh → nova-hook
        let gnome = [
            (900, 1, "systemd"),
            (1000, 900, "gnome-terminal-"),
            (1100, 1000, "bash"),
            (1200, 1100, "claude"),
            (1300, 1200, "sh"),
            (1400, 1300, "nova-hook"),
        ];
        assert_eq!(linux(&gnome), [1300, 1200, 1100, 1000]);

        // A terminal started from the panel stops before the panel, which has
        // windows of its own.
        let panel = [
            (500, 400, "plasmashell"),
            (600, 500, "konsole"),
            (700, 600, "zsh"),
            (800, 700, "node"),
            (810, 800, "nova-hook"),
        ];
        assert_eq!(linux(&panel), [800, 700, 600]);

        // VS Code: the pty host and the zygote lead up to the main process.
        let code = [
            (20, 1, "systemd"),
            (30, 20, "code"),
            (31, 30, "code"),
            (32, 31, "code"),
            (40, 32, "bash"),
            (41, 40, "node"),
            (42, 41, "nova-hook"),
        ];
        assert_eq!(linux(&code), [41, 40, 32, 31, 30]);
    }

    #[test]
    fn linux_walks_end_at_logins_and_session_managers() {
        // Over ssh: nothing above the shell may be raised.
        let ssh = [(10, 1, "sshd"), (11, 10, "sshd-session"), (12, 11, "bash"), (13, 12, "claude"), (14, 13, "nova-hook")];
        assert_eq!(linux(&ssh), [13, 12]);
        // tmux's server is daemonised under the service manager: no terminal.
        let tmux = [(5, 1, "systemd"), (6, 5, "tmux: server"), (7, 6, "bash"), (8, 7, "claude"), (9, 8, "nova-hook")];
        assert_eq!(linux(&tmux), [8, 7, 6]);
        // An X session started by hand ends at xinit, names compared lower-cased.
        let xinit = [(2, 1, "xinit"), (3, 2, "Xorg"), (4, 2, "i3"), (50, 4, "xterm"), (51, 50, "bash"), (52, 51, "nova-hook")];
        assert_eq!(linux(&xinit), [51, 50]);
    }

    #[test]
    fn linux_tree_tops_fit_in_a_process_name() {
        for top in LINUX_TREE_TOPS {
            assert!(top.len() <= 15, "{top} is longer than /proc keeps");
            assert_eq!(*top, top.to_ascii_lowercase());
        }
    }

    #[test]
    fn the_nearest_ancestor_with_a_window_is_chosen() {
        let windows = vec![
            ("panel", 500, "Panel".to_string()),
            ("notes", 30, "notes — Visual Studio Code".to_string()),
            ("nova", 30, "lib.rs — nova — Visual Studio Code".to_string()),
            ("other", 99, "nova — elsewhere".to_string()),
        ];
        // The shell and node own nothing; VS Code's main process does.
        assert_eq!(choose_window(&[41, 40, 30, 500], &windows, "nova"), Some(&"nova"));
        assert_eq!(choose_window(&[41, 40, 30], &windows, "missing"), Some(&"notes"));
        // A nearer ancestor wins even when a farther one's title matches.
        assert_eq!(choose_window(&[500, 30], &windows, "nova"), Some(&"panel"));
        // A title alone never picks a window of another process.
        assert_eq!(choose_window(&[41, 40], &windows, "nova"), None);
        assert_eq!(choose_window::<&str>(&[1], &[], "x"), None);
    }

    #[test]
    fn the_window_named_after_the_project_wins() {
        let windows = vec![
            (1, "notes — Visual Studio Code".to_string()),
            (2, "app.ts — nova — Visual Studio Code".to_string()),
        ];
        assert_eq!(pick_window(&windows, "Nova"), Some(&2));
        assert_eq!(pick_window(&windows, "other"), Some(&1));
        assert_eq!(pick_window(&windows, ""), Some(&1));
        assert_eq!(pick_window::<i32>(&[], "x"), None);
        assert_eq!(folder_name(r"C:\Users\me\nova\"), "nova");
        assert_eq!(folder_name("/home/me/proj"), "proj");
    }

    #[test]
    fn sessions_are_remembered_by_id_and_only_plausible_ids_are_kept() {
        remember("s-test-1", vec![42]);
        remember("s-test-1", vec![43, 44]);
        assert_eq!(lookup("s-test-1"), Some(vec![43, 44]));
        remember("not a session/../x", vec![7]);
        assert!(!known("not a session/../x"));
        forget("s-test-1");
        assert!(!known("s-test-1"));

        // A session without a window is settled, with nothing to show.
        remember("s-test-2", Vec::new());
        assert!(known("s-test-2"));
        assert_eq!(lookup("s-test-2"), None);
        forget("s-test-2");

        // Only the latest sessions are kept. (One test: the list is shared.)
        for i in 0..(MAX_SESSIONS + 5) {
            remember(&format!("s-cap-{i}"), vec![1]);
        }
        assert!(!known("s-cap-0"));
        assert!(known(&format!("s-cap-{}", MAX_SESSIONS + 4)));
        for i in 0..(MAX_SESSIONS + 5) {
            forget(&format!("s-cap-{i}"));
        }
    }
}
