// "Open terminal" on Linux: brings the window a Claude Code session runs in to
// the front, and in Konsole the very tab it runs in, instead of opening its
// folder in VS Code (session_window.rs does the same on Windows).
//
// When the relay connects, its parents are walked up through /proc: the shell,
// Claude Code, the shell it was started from, the terminal or editor whose
// window we want. What is found is kept per session ID, in memory only. Konsole
// tells each of its sessions where it lives on D-Bus (KONSOLE_DBUS_SERVICE and
// KONSOLE_DBUS_SESSION in their environment), which picks the tab.
//
// Wayland lets no app raise another app's window, so the raising is asked of
// the compositor: KWin (KDE Plasma) runs a three-line script for us. Elsewhere
// — GNOME, wlroots — nothing can do it, and the island falls back to VS Code
// as before. Every call is `gdbus`, which ships with GLib, which the app's own
// WebKitGTK already needs.

use std::process::{Command, Stdio};
use std::sync::Mutex;

use crate::{log, platform, settings};

/// How far up we look. A session sits a handful of levels below its window.
const MAX_DEPTH: usize = 16;
/// Sessions remembered at once; an old one makes room for a new one.
const MAX_SESSIONS: usize = 64;
/// KWin's name for the script while it is loaded.
const SCRIPT_NAME: &str = "coucou-focus";

#[derive(Debug, Clone, PartialEq)]
struct Konsole {
    /// Konsole's D-Bus name, `:1.566` or `org.kde.konsole-1234`.
    service: String,
    /// The tab's number, as in `/Sessions/3`.
    session: u32,
}

#[derive(Debug, Clone, PartialEq)]
struct Target {
    /// The relay's parents, nearest first.
    pids: Vec<u32>,
    konsole: Option<Konsole>,
}

static TARGETS: Mutex<Vec<(String, Target)>> = Mutex::new(Vec::new());

// ── Remembering ───────────────────────────────────────────────────────────────

/// Called for a session's events until its window is known. The relay must still
/// be running for its parents to be found; if it has already exited, a later
/// event of the same session tries again.
pub fn note(session: &str, relay: u32) {
    if session.is_empty() || known(session) {
        return;
    }
    let pids = ancestors(relay, |pid| read_stat(pid));
    if pids.is_empty() {
        return;
    }
    let konsole = std::iter::once(relay)
        .chain(pids.iter().copied())
        .find_map(|pid| konsole_of(&read_environ(pid)?));
    let mut targets = TARGETS.lock().unwrap_or_else(|e| e.into_inner());
    if targets.len() >= MAX_SESSIONS {
        targets.remove(0);
    }
    targets.push((session.to_string(), Target { pids, konsole }));
}

pub fn forget(session: &str) {
    TARGETS.lock().unwrap_or_else(|e| e.into_inner()).retain(|(s, _)| s != session);
}

fn known(session: &str) -> bool {
    TARGETS.lock().unwrap_or_else(|e| e.into_inner()).iter().any(|(s, _)| s == session)
}

fn lookup(session: &str) -> Option<Target> {
    TARGETS
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .iter()
        .find(|(s, _)| s == session)
        .map(|(_, t)| t.clone())
}

/// `pid`'s parent and executable name, from `/proc/<pid>/stat`.
fn read_stat(pid: u32) -> Option<(u32, String)> {
    parse_stat(&std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?)
}

/// `1234 (some (odd) name) S 567 …` → (567, "some (odd) name"). The name may
/// hold spaces and parentheses, so it ends at the last `)`.
fn parse_stat(stat: &str) -> Option<(u32, String)> {
    let open = stat.find('(')?;
    let close = stat.rfind(')')?;
    let name = stat.get(open + 1..close)?.to_string();
    let ppid = stat.get(close + 1..)?.split_whitespace().nth(1)?.parse().ok()?;
    Some((ppid, name))
}

/// The parents of `start`, nearest first, up to (not including) init or the
/// user's service manager, which are never a session's window.
fn ancestors(start: u32, stat: impl Fn(u32) -> Option<(u32, String)>) -> Vec<u32> {
    let mut out = Vec::new();
    let mut current = start;
    while out.len() < MAX_DEPTH {
        let Some((parent, _)) = stat(current) else { break };
        if parent <= 1 || parent == start || out.contains(&parent) {
            break;
        }
        let Some((_, name)) = stat(parent) else { break };
        if name == "systemd" || name == "init" {
            break;
        }
        out.push(parent);
        current = parent;
    }
    out
}

fn read_environ(pid: u32) -> Option<Vec<u8>> {
    std::fs::read(format!("/proc/{pid}/environ")).ok()
}

/// Where Konsole says this process's tab lives, if it runs in Konsole.
fn konsole_of(environ: &[u8]) -> Option<Konsole> {
    let var = |name: &str| {
        environ.split(|b| *b == 0).find_map(|entry| {
            let entry = std::str::from_utf8(entry).ok()?;
            entry.strip_prefix(name)?.strip_prefix('=').map(str::to_string)
        })
    };
    let service = var("KONSOLE_DBUS_SERVICE")?;
    let session = var("KONSOLE_DBUS_SESSION")?;
    let session = session.strip_prefix("/Sessions/")?.parse().ok()?;
    valid_bus_name(&service).then_some(Konsole { service, session })
}

/// A unique name (`:1.566`) or Konsole's well-known one — never anything that
/// could be read as an option by gdbus.
fn valid_bus_name(name: &str) -> bool {
    let unique = name
        .strip_prefix(':')
        .is_some_and(|rest| !rest.is_empty() && rest.split('.').all(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit())));
    let konsole = name
        .strip_prefix("org.kde.konsole")
        .is_some_and(|rest| rest.is_empty() || rest.strip_prefix('-').is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit())));
    unique || konsole
}

// ── Focusing ──────────────────────────────────────────────────────────────────

/// Brings the session's window forward — its Konsole tab first — when it is
/// known and KWin can do it. False sends the caller to its fallback.
pub fn focus(session: &str, folder: &str) -> bool {
    let Some(target) = lookup(session) else { return false };
    let mut pids = target.pids;
    if let Some(konsole) = &target.konsole {
        // The tab is picked even if the window then cannot be raised: the
        // terminal is still on the right session when the user gets there.
        if select_konsole_tab(konsole) {
            if let Some(pid) = bus_owner_pid(&konsole.service) {
                pids.retain(|p| *p != pid);
                pids.insert(0, pid);
            }
        }
    }
    let raised = raise_window(&pids, folder);
    log::line(format!("open terminal: {}", if raised { "raised" } else { "no KWin — fallback" }));
    raised
}

/// `gdbus call` on the session bus; its output, or None when it failed.
fn gdbus(args: &[&str]) -> Option<String> {
    let out = Command::new("gdbus")
        .args(["call", "--session", "--timeout", "2"])
        .args(args)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Finds the Konsole window holding the tab and makes it the current one.
fn select_konsole_tab(k: &Konsole) -> bool {
    let Ok(out) = Command::new("gdbus")
        .args(["introspect", "--session", "--dest", &k.service, "--object-path", "/Windows"])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
    else {
        return false;
    };
    let session = k.session.to_string();
    for window in window_nodes(&String::from_utf8_lossy(&out.stdout)) {
        let path = format!("/Windows/{window}");
        let Some(list) = gdbus(&["--dest", &k.service, "--object-path", &path, "--method", "org.kde.konsole.Window.sessionList"]) else {
            continue;
        };
        if quoted_items(&list).iter().any(|s| *s == session) {
            return gdbus(&[
                "--dest", &k.service, "--object-path", &path,
                "--method", "org.kde.konsole.Window.setCurrentSession", &session,
            ])
            .is_some();
        }
    }
    false
}

/// The `node N {` children of an introspected `/Windows`.
fn window_nodes(introspection: &str) -> Vec<u32> {
    introspection
        .lines()
        .filter_map(|l| l.trim().strip_prefix("node ")?.strip_suffix(" {")?.parse().ok())
        .collect()
}

/// `(['1', '2'],)` → ["1", "2"].
fn quoted_items(reply: &str) -> Vec<&str> {
    reply.split('\'').skip(1).step_by(2).collect()
}

/// The process behind a D-Bus name: Konsole's own, whose window KWin knows.
fn bus_owner_pid(service: &str) -> Option<u32> {
    let out = gdbus(&[
        "--dest", "org.freedesktop.DBus", "--object-path", "/org/freedesktop/DBus",
        "--method", "org.freedesktop.DBus.GetConnectionUnixProcessID", service,
    ])?;
    // `(uint32 267144,)`: the last number is the PID.
    out.split(|c: char| !c.is_ascii_digit()).filter(|s| !s.is_empty()).last()?.parse().ok()
}

/// The script KWin runs: the first of `pids`, nearest first, that has a normal
/// window gets activated — the one whose title names `folder` when it has
/// several. Written for KWin 6, with KWin 5's names as a fallback.
fn kwin_script(pids: &[u32], folder: &str) -> String {
    let pids = serde_json::to_string(pids).unwrap_or_else(|_| "[]".into());
    let folder = serde_json::to_string(folder).unwrap_or_else(|_| "\"\"".into());
    format!(
        r#"(function () {{
  const pids = {pids};
  const folder = {folder};
  const all = workspace.windowList ? workspace.windowList() : workspace.clientList();
  for (const pid of pids) {{
    const wins = all.filter(function (w) {{ return w.pid === pid && w.normalWindow; }});
    if (wins.length === 0) continue;
    const named = folder ? wins.filter(function (w) {{ return String(w.caption).indexOf(folder) >= 0; }}) : [];
    const w = named.length ? named[0] : wins[0];
    if (w.minimized) w.minimized = false;
    if ("activeWindow" in workspace) workspace.activeWindow = w; else workspace.activeClient = w;
    return;
  }}
}})();
"#
    )
}

/// Asks KWin to run [`kwin_script`]. False when there is no KWin to ask.
fn raise_window(pids: &[u32], folder: &str) -> bool {
    if pids.is_empty() {
        return false;
    }
    let dir = settings::local_dir();
    if platform::ensure_private_dir(&dir).is_err() {
        return false;
    }
    let path = dir.join("kwin-focus.js");
    if std::fs::write(&path, kwin_script(pids, folder)).is_err() {
        return false;
    }
    let path = path.to_string_lossy().into_owned();
    let unload = || {
        gdbus(&["--dest", "org.kde.KWin", "--object-path", "/Scripting", "--method", "org.kde.kwin.Scripting.unloadScript", SCRIPT_NAME])
    };
    // A copy left loaded by an earlier click would make the load fail.
    let _ = unload();
    let Some(loaded) = gdbus(&[
        "--dest", "org.kde.KWin", "--object-path", "/Scripting",
        "--method", "org.kde.kwin.Scripting.loadScript", &path, SCRIPT_NAME,
    ]) else {
        return false;
    };
    let Some(id) = loaded.split(|c: char| !c.is_ascii_digit() && c != '-').find(|s| !s.is_empty()).and_then(|s| s.parse::<i32>().ok()) else {
        return false;
    };
    if id < 0 {
        return false;
    }
    // KWin 6 (and late 5) put the script at /Scripting/Script<id>, older 5 at /<id>.
    let ran = [format!("/Scripting/Script{id}"), format!("/{id}")].iter().any(|object| {
        gdbus(&["--dest", "org.kde.KWin", "--object-path", object, "--method", "org.kde.kwin.Script.run"]).is_some()
    });
    let _ = unload();
    ran
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    #[test]
    fn stat_names_may_hold_spaces_and_parentheses() {
        assert_eq!(parse_stat("42 (bash) S 7 42 42 0"), Some((7, "bash".into())));
        assert_eq!(parse_stat("42 (Web Content (x)) S 9 1 1"), Some((9, "Web Content (x)".into())));
        assert_eq!(parse_stat("garbage"), None);
    }

    #[test]
    fn the_walk_goes_up_to_the_service_manager_and_no_further() {
        // relay 50 → bash 40 → claude 30 → bash 20 → konsole 10 → systemd 5 → init 1
        let tree: HashMap<u32, (u32, &str)> = [
            (50, (40, "coucou-hook")), (40, (30, "bash")), (30, (20, "claude")),
            (20, (10, "bash")), (10, (5, "konsole")), (5, (1, "systemd")),
        ]
        .into();
        let stat = |pid: u32| tree.get(&pid).map(|(p, n)| (*p, n.to_string()));
        assert_eq!(ancestors(50, stat), vec![40, 30, 20, 10]);
        // A loop in the parent links ends the walk.
        let looped: HashMap<u32, (u32, &str)> = [(3, (4, "a")), (4, (3, "b"))].into();
        assert_eq!(ancestors(3, |p| looped.get(&p).map(|(q, n)| (*q, n.to_string()))), vec![4]);
        // A relay already gone has no parents.
        assert!(ancestors(99, stat).is_empty());
    }

    #[test]
    fn konsole_is_read_from_the_environment_and_checked() {
        let env = |pairs: &[&str]| pairs.join("\0").into_bytes();
        assert_eq!(
            konsole_of(&env(&["HOME=/h", "KONSOLE_DBUS_SERVICE=:1.566", "KONSOLE_DBUS_SESSION=/Sessions/3"])),
            Some(Konsole { service: ":1.566".into(), session: 3 })
        );
        assert!(konsole_of(&env(&["KONSOLE_DBUS_SERVICE=org.kde.konsole-1234", "KONSOLE_DBUS_SESSION=/Sessions/1"])).is_some());
        // Anything that is not a bus name, or not a session path, is not Konsole.
        for bad in ["--help", ":1.x", "", "org.kde.KWin", ":"] {
            let e = env(&[&format!("KONSOLE_DBUS_SERVICE={bad}"), "KONSOLE_DBUS_SESSION=/Sessions/1"]);
            assert!(konsole_of(&e).is_none(), "{bad}");
        }
        assert!(konsole_of(&env(&["KONSOLE_DBUS_SERVICE=:1.5", "KONSOLE_DBUS_SESSION=/Windows/1"])).is_none());
        assert!(konsole_of(&env(&["PATH=/bin"])).is_none());
    }

    #[test]
    fn gdbus_replies_are_read() {
        let intro = "node /Windows {\n  interface org.freedesktop.DBus.Peer {\n  };\n  node 1 {\n  };\n  node 2 {\n  };\n};";
        assert_eq!(window_nodes(intro), vec![1, 2]);
        assert_eq!(quoted_items("(['1', '12'],)"), vec!["1", "12"]);
        assert!(quoted_items("(@as [],)").is_empty());
    }

    #[test]
    fn the_script_carries_only_numbers_and_a_quoted_folder() {
        let script = kwin_script(&[10, 20], "my \"proj\"\n</script>");
        assert!(script.contains("const pids = [10,20];"));
        assert!(script.contains(r#"const folder = "my \"proj\"\n</script>";"#));
    }
}
