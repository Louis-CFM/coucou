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

/// Whether a window title names a project folder: JetBrains titles are the
/// project's name, then " – " and the open file; `folder` is lower case. The
/// name must be a whole word of the title, so "app" does not match "webapp".
pub fn title_names_folder(title: &str, folder: &str) -> bool {
    if folder.is_empty() {
        return false;
    }
    let title = title.to_lowercase();
    let name = title.split(['–', '—', '[']).next().unwrap_or_default().trim();
    name == folder
}

/// The project a session's folder belongs to: the nearest folder up from it
/// that holds an `.idea` (a JetBrains project), else the nearest that holds a
/// `.git`, else the folder itself. Claude Code reports the folder its shell is
/// in, which drifts into a sub-folder after a `cd`; the editor has the project
/// open, not that sub-folder.
pub fn project_root(path: &str) -> String {
    let start = std::path::Path::new(path);
    if !start.is_absolute() || !start.is_dir() {
        return path.to_string();
    }
    let up = |marker: &str| start.ancestors().find(|dir| dir.parent().is_some() && dir.join(marker).is_dir());
    up(".idea")
        .or_else(|| up(".git"))
        .map_or_else(|| path.to_string(), |dir| dir.to_string_lossy().into_owned())
}

/// The last folder name of a path, either separator.
pub fn folder_name(path: &str) -> &str {
    path.trim_end_matches(['/', '\\']).rsplit(['/', '\\']).next().unwrap_or_default()
}

// ── What the relay sent about its own parents ─────────────────────────────────

/// The relay's chain from the payload (`coucou_procs`: `[[pid, parent, exe], …]`,
/// the relay first), as the process table `ancestors` walks. The relay takes it
/// while it is alive: by the time the event is handled it has usually gone, and
/// a snapshot taken here would find nothing. None for an older relay, or when
/// the field is not what it should be (it comes from a local program, but is
/// still read as untrusted).
#[cfg_attr(not(windows), allow(dead_code))]
pub fn procs_from_payload(payload: &serde_json::Value) -> Option<(u32, HashMap<u32, Proc>)> {
    let rows = payload.get("coucou_procs")?.as_array()?;
    if rows.is_empty() || rows.len() > 64 {
        return None;
    }
    let mut procs = HashMap::new();
    let mut first = None;
    for row in rows {
        let row = row.as_array()?;
        let pid = u32::try_from(row.first()?.as_u64()?).ok()?;
        let parent = u32::try_from(row.get(1)?.as_u64()?).ok()?;
        let exe = row.get(2)?.as_str()?;
        if exe.len() > 260 {
            return None;
        }
        first.get_or_insert(pid);
        procs.insert(pid, Proc { parent, exe: exe.to_string() });
    }
    first.map(|start| (start, procs))
}

/// The window in front when the relay started (`coucou_foreground`: `[pid,
/// hwnd]`): the process that owns it, and the window.
#[cfg_attr(not(windows), allow(dead_code))]
pub fn foreground_from_payload(payload: &serde_json::Value) -> Option<(u32, isize)> {
    let pair = payload.get("coucou_foreground")?.as_array()?;
    let pid = u32::try_from(pair.first()?.as_u64()?).ok()?;
    let hwnd = isize::try_from(pair.get(1)?.as_i64()?).ok()?;
    (pid != 0 && hwnd != 0).then_some((pid, hwnd))
}

// ── Tabs ──────────────────────────────────────────────────────────────────────

/// The tab a session is in, inside a terminal window that has tabs (Windows
/// Terminal): the window, the tab's UI Automation runtime ID — which names it for
/// as long as it lives — and its title, for when the ID no longer matches.
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(not(windows), allow(dead_code))]
pub struct TabRef {
    pub hwnd: isize,
    pub runtime_id: Vec<i32>,
    pub title: String,
}

/// A tab's title without the state glyph Claude Code puts in front of it (✳, a
/// spinner…), which changes while the title does not.
#[cfg_attr(not(windows), allow(dead_code))]
pub fn strip_glyph(title: &str) -> &str {
    title.trim_start_matches(|c: char| !c.is_alphanumeric())
}

/// Which of a window's tabs is the one remembered: by runtime ID; failing that,
/// by title, but only when that names exactly one tab (two tabs called `claude`
/// would be a guess).
#[cfg_attr(not(windows), allow(dead_code))]
pub fn pick_tab(tabs: &[(Vec<i32>, String)], wanted: &TabRef) -> Option<usize> {
    if !wanted.runtime_id.is_empty() {
        if let Some(i) = tabs.iter().position(|(id, _)| *id == wanted.runtime_id) {
            return Some(i);
        }
    }
    let title = strip_glyph(&wanted.title);
    if title.is_empty() {
        return None;
    }
    let mut named = tabs.iter().enumerate().filter(|(_, (_, name))| strip_glyph(name) == title);
    match (named.next(), named.next()) {
        (Some((i, _)), None) => Some(i),
        _ => None,
    }
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

/// Session ID → the port of the IDE it runs in (`ide_port` of the payload, from
/// CLAUDE_CODE_SSE_PORT), see jetbrains.rs. Kept apart from `SESSIONS`: it comes
/// with every event, the window is looked for once.
static IDE_PORTS: Mutex<Vec<(String, u16)>> = Mutex::new(Vec::new());

/// The IDE port the relay sent: a number that is a port, nothing else.
pub fn ide_port_from_payload(payload: &serde_json::Value) -> Option<u16> {
    payload.get("ide_port")?.as_u64().and_then(|p| u16::try_from(p).ok()).filter(|p| *p > 0)
}

pub fn remember_ide_port(session: &str, port: u16) {
    if !valid_session(session) {
        return;
    }
    let mut list = IDE_PORTS.lock().unwrap_or_else(|e| e.into_inner());
    list.retain(|(s, _)| s != session);
    list.push((session.to_string(), port));
    let excess = list.len().saturating_sub(MAX_SESSIONS);
    list.drain(..excess);
}

pub fn ide_port(session: &str) -> Option<u16> {
    let list = IDE_PORTS.lock().unwrap_or_else(|e| e.into_inner());
    list.iter().find(|(s, _)| s == session).map(|(_, port)| *port)
}

pub fn forget(session: &str) {
    SESSIONS.lock().unwrap_or_else(|e| e.into_inner()).retain(|(s, _)| s != session);
    IDE_PORTS.lock().unwrap_or_else(|e| e.into_inner()).retain(|(s, _)| s != session);
    TABS.lock().unwrap_or_else(|e| e.into_inner()).retain(|(s, _)| s != session);
}

/// Session ID → its tab. Kept apart from `SESSIONS`: it is looked at again at
/// every prompt (the tab may have been moved or recreated), the window is not.
#[cfg_attr(not(windows), allow(dead_code))]
static TABS: Mutex<Vec<(String, TabRef)>> = Mutex::new(Vec::new());

#[cfg_attr(not(windows), allow(dead_code))]
pub fn remember_tab(session: &str, tab: TabRef) {
    if !valid_session(session) {
        return;
    }
    let mut list = TABS.lock().unwrap_or_else(|e| e.into_inner());
    list.retain(|(s, _)| s != session);
    list.push((session.to_string(), tab));
    let excess = list.len().saturating_sub(MAX_SESSIONS);
    list.drain(..excess);
}

#[cfg_attr(not(windows), allow(dead_code))]
pub fn tab_of(session: &str) -> Option<TabRef> {
    let list = TABS.lock().unwrap_or_else(|e| e.into_inner());
    list.iter().find(|(s, _)| s == session).map(|(_, tab)| tab.clone())
}

#[cfg(test)]
mod tests {
    use super::project_root;

    #[test]
    fn a_sub_folder_belongs_to_the_project_that_holds_it() {
        let base = std::env::temp_dir().join(format!("coucou-root-{}", std::process::id()));
        let sub = base.join("app/src/deep");
        std::fs::create_dir_all(&sub).unwrap();
        std::fs::create_dir_all(base.join("app/.git")).unwrap();
        let text = |p: &std::path::Path| p.to_string_lossy().into_owned();
        // Only a .git: that is the root.
        assert_eq!(project_root(&text(&sub)), text(&base.join("app")));
        // An .idea nearer than the .git wins; one above it does not.
        std::fs::create_dir_all(base.join("app/src/.idea")).unwrap();
        assert_eq!(project_root(&text(&sub)), text(&base.join("app/src")));
        // Nothing: the folder itself, and a path that is not a folder is left alone.
        let bare = base.join("bare");
        std::fs::create_dir_all(&bare).unwrap();
        assert_eq!(project_root(&text(&bare)), text(&bare));
        assert_eq!(project_root("/nowhere/at/all"), "/nowhere/at/all");
        assert_eq!(project_root("relative/dir"), "relative/dir");
        let _ = std::fs::remove_dir_all(&base);
    }

    use super::{ide_port_from_payload, title_names_folder};

    #[test]
    fn the_ide_port_of_a_payload_is_a_port_or_nothing() {
        use serde_json::json;
        assert_eq!(ide_port_from_payload(&json!({ "ide_port": 46143 })), Some(46143));
        for bad in [json!({ "ide_port": 0 }), json!({ "ide_port": 70000 }), json!({ "ide_port": "46143" }),
                    json!({ "ide_port": -1 }), json!({ "ide_port": null }), json!({})] {
            assert_eq!(ide_port_from_payload(&bad), None, "{bad}");
        }
    }

    #[test]
    fn a_title_names_a_project_by_its_first_part() {
        assert!(title_names_folder("coucou", "coucou"));
        assert!(title_names_folder("Coucou – main.rs", "coucou"));
        assert!(title_names_folder("coucou [~/Projets/coucou] – src/lib.rs", "coucou"));
        assert!(!title_names_folder("meyclub – coucou.php", "coucou"));
        assert!(!title_names_folder("webapp", "app"));
        assert!(!title_names_folder("coucou", ""));
    }

    use super::*;

    fn tree(entries: &[(u32, u32, &str)]) -> HashMap<u32, Proc> {
        entries
            .iter()
            .map(|(pid, parent, exe)| (*pid, Proc { parent: *parent, exe: exe.to_string() }))
            .collect()
    }

    #[test]
    fn the_relays_own_chain_becomes_a_process_table() {
        use serde_json::json;
        let payload = json!({ "coucou_procs": [
            [600, 500, "coucou-hook.exe"], [500, 300, "wsl.exe"], [300, 200, "wsl.exe"],
            [200, 100, "WindowsTerminal.exe"], [100, 4, "explorer.exe"], [4, 0, "System"],
        ]});
        let (start, procs) = procs_from_payload(&payload).unwrap();
        assert_eq!(start, 600);
        // Walked like a live snapshot: up to the terminal, not into the desktop.
        assert_eq!(ancestors_below(&procs, start, WINDOWS_TREE_TOPS), [500, 300, 200]);
        assert_eq!(window_owner(&procs, start, |pid| pid == 200), Some(200));
        // Absent, empty or malformed: nothing, so the live snapshot is tried.
        assert!(procs_from_payload(&json!({})).is_none());
        assert!(procs_from_payload(&json!({ "coucou_procs": [] })).is_none());
        assert!(procs_from_payload(&json!({ "coucou_procs": "x" })).is_none());
        assert!(procs_from_payload(&json!({ "coucou_procs": [[1, 2]] })).is_none());
        assert!(procs_from_payload(&json!({ "coucou_procs": [[-1, 2, "a"]] })).is_none());
        assert!(procs_from_payload(&json!({ "coucou_procs": [[1, 2, "a".repeat(300)]] })).is_none());
        let many: Vec<_> = (1..80).map(|i| json!([i, i + 1, "x.exe"])).collect();
        assert!(procs_from_payload(&json!({ "coucou_procs": many })).is_none());
    }

    #[test]
    fn the_window_in_front_is_read_from_the_payload() {
        use serde_json::json;
        assert_eq!(foreground_from_payload(&json!({ "coucou_foreground": [200, 853906] })), Some((200, 853906)));
        assert_eq!(foreground_from_payload(&json!({ "coucou_foreground": [0, 853906] })), None);
        assert_eq!(foreground_from_payload(&json!({ "coucou_foreground": [200, 0] })), None);
        assert_eq!(foreground_from_payload(&json!({ "coucou_foreground": [200] })), None);
        assert_eq!(foreground_from_payload(&json!({})), None);
    }

    #[test]
    fn the_state_glyph_in_a_tab_title_is_ignored() {
        assert_eq!(strip_glyph("✳ Claude Code"), "Claude Code");
        assert_eq!(strip_glyph("⠂ coucou"), "coucou");
        assert_eq!(strip_glyph("Ubuntu"), "Ubuntu");
        assert_eq!(strip_glyph("✳"), "");
    }

    #[test]
    fn a_tab_is_found_by_its_id_or_by_a_title_that_is_its_alone() {
        let tabs = vec![
            (vec![42, 7, 1], "✳ coucou".to_string()),
            (vec![42, 7, 2], "pulse".to_string()),
            (vec![42, 7, 3], "pulse".to_string()),
        ];
        let tab = |id: Vec<i32>, title: &str| TabRef { hwnd: 1, runtime_id: id, title: title.into() };
        // The ID wins, even when the title has changed.
        assert_eq!(pick_tab(&tabs, &tab(vec![42, 7, 2], "something else")), Some(1));
        // The ID is gone (tab recreated): the title, glyph or not, if it is unique.
        assert_eq!(pick_tab(&tabs, &tab(vec![42, 9, 9], "⠂ coucou")), Some(0));
        // Two tabs with that title, or none: no guess.
        assert_eq!(pick_tab(&tabs, &tab(vec![42, 9, 9], "pulse")), None);
        assert_eq!(pick_tab(&tabs, &tab(vec![], "nothing")), None);
        assert_eq!(pick_tab(&tabs, &tab(vec![], "")), None);
        assert_eq!(pick_tab(&[], &tab(vec![1], "a")), None);
    }

    #[test]
    fn a_session_keeps_its_tab_until_it_ends() {
        let tab = TabRef { hwnd: 5, runtime_id: vec![1, 2], title: "x".into() };
        remember_tab("tab-session-1", tab.clone());
        assert_eq!(tab_of("tab-session-1"), Some(tab.clone()));
        let moved = TabRef { runtime_id: vec![3], ..tab };
        remember_tab("tab-session-1", moved.clone());
        assert_eq!(tab_of("tab-session-1"), Some(moved));
        forget("tab-session-1");
        assert_eq!(tab_of("tab-session-1"), None);
        // Nothing valid to key on, nothing kept.
        remember_tab("bad id!", TabRef { hwnd: 1, runtime_id: vec![], title: String::new() });
        assert_eq!(tab_of("bad id!"), None);
    }

    #[test]
    fn windows_terminal_is_found_above_the_shells() {
        // WindowsTerminal → pwsh → claude (node) → bash → coucou-hook
        let procs = tree(&[
            (4, 0, "System"),
            (100, 4, "explorer.exe"),
            (200, 100, "WindowsTerminal.exe"),
            (300, 200, "pwsh.exe"),
            (400, 300, "node.exe"),
            (500, 400, "bash.exe"),
            (600, 500, "coucou-hook.exe"),
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
            (600, 400, "coucou-hook.exe"),
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
            (600, 400, "coucou-hook.exe"),
        ]);
        assert_eq!(window_owner(&procs, 600, |pid| pid == 100), None);
    }

    #[test]
    fn a_relay_already_gone_or_a_loop_ends_the_walk() {
        assert!(ancestors(&tree(&[]), 600).is_empty());
        let looped = tree(&[(1, 2, "a.exe"), (2, 1, "b.exe"), (3, 1, "coucou-hook.exe")]);
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
        // systemd --user → gnome-terminal-server → bash → claude → sh → coucou-hook
        let gnome = [
            (900, 1, "systemd"),
            (1000, 900, "gnome-terminal-"),
            (1100, 1000, "bash"),
            (1200, 1100, "claude"),
            (1300, 1200, "sh"),
            (1400, 1300, "coucou-hook"),
        ];
        assert_eq!(linux(&gnome), [1300, 1200, 1100, 1000]);

        // A terminal started from the panel stops before the panel, which has
        // windows of its own.
        let panel = [
            (500, 400, "plasmashell"),
            (600, 500, "konsole"),
            (700, 600, "zsh"),
            (800, 700, "node"),
            (810, 800, "coucou-hook"),
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
            (42, 41, "coucou-hook"),
        ];
        assert_eq!(linux(&code), [41, 40, 32, 31, 30]);
    }

    #[test]
    fn linux_walks_end_at_logins_and_session_managers() {
        // Over ssh: nothing above the shell may be raised.
        let ssh = [(10, 1, "sshd"), (11, 10, "sshd-session"), (12, 11, "bash"), (13, 12, "claude"), (14, 13, "coucou-hook")];
        assert_eq!(linux(&ssh), [13, 12]);
        // tmux's server is daemonised under the service manager: no terminal.
        let tmux = [(5, 1, "systemd"), (6, 5, "tmux: server"), (7, 6, "bash"), (8, 7, "claude"), (9, 8, "coucou-hook")];
        assert_eq!(linux(&tmux), [8, 7, 6]);
        // An X session started by hand ends at xinit, names compared lower-cased.
        let xinit = [(2, 1, "xinit"), (3, 2, "Xorg"), (4, 2, "i3"), (50, 4, "xterm"), (51, 50, "bash"), (52, 51, "coucou-hook")];
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
            ("coucou", 30, "lib.rs — coucou — Visual Studio Code".to_string()),
            ("other", 99, "coucou — elsewhere".to_string()),
        ];
        // The shell and node own nothing; VS Code's main process does.
        assert_eq!(choose_window(&[41, 40, 30, 500], &windows, "coucou"), Some(&"coucou"));
        assert_eq!(choose_window(&[41, 40, 30], &windows, "missing"), Some(&"notes"));
        // A nearer ancestor wins even when a farther one's title matches.
        assert_eq!(choose_window(&[500, 30], &windows, "coucou"), Some(&"panel"));
        // A title alone never picks a window of another process.
        assert_eq!(choose_window(&[41, 40], &windows, "coucou"), None);
        assert_eq!(choose_window::<&str>(&[1], &[], "x"), None);
    }

    #[test]
    fn the_window_named_after_the_project_wins() {
        let windows = vec![
            (1, "notes — Visual Studio Code".to_string()),
            (2, "app.ts — coucou — Visual Studio Code".to_string()),
        ];
        assert_eq!(pick_window(&windows, "Coucou"), Some(&2));
        assert_eq!(pick_window(&windows, "other"), Some(&1));
        assert_eq!(pick_window(&windows, ""), Some(&1));
        assert_eq!(pick_window::<i32>(&[], "x"), None);
        assert_eq!(folder_name(r"C:\Users\me\coucou\"), "coucou");
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
