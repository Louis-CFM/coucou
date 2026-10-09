// Linux "Open terminal": bringing a session's terminal or editor window forward.
//
// session_window.rs keeps, per session, the relay's ancestors read from /proc
// (nearest first). When the button is clicked, the window one of them owns is
// brought forward by the best way the desktop offers:
//   * KDE Plasma on Wayland: a tiny KWin script, loaded over D-Bus, finds the
//     window by process ID, activates it, reports back and is unloaded;
//   * an X11 session (or an XWayland window): EWMH — `_NET_CLIENT_LIST` and
//     `_NET_WM_PID` to find it, a `_NET_ACTIVE_WINDOW` request to the window
//     manager to raise it, over the x11rb that global-hotkey already brings;
//   * kitty, whatever the session, also selects the session's tab when its
//     remote control listens on a socket.
// GNOME on Wayland has no such door for native windows: nothing is found, and
// the caller opens the folder in VS Code as before.
//
// Everything handed to a script or a command is a number read from /proc of a
// process we found ourselves (or our own D-Bus name, checked); nothing from a
// hook payload. Commands get their arguments one by one, never through a shell.
// This all runs off the UI thread (lib.rs `open_session`).

use std::collections::HashMap;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use crate::session_window::{self, Proc};

// ── The process tree ──────────────────────────────────────────────────────────

/// One process of ours: its parent and name from /proc. PID 1 and processes of
/// another user (sshd, a display manager, sudo) are not ours, which ends any
/// walk there.
fn read_proc(pid: u32, uid: u32) -> Option<Proc> {
    if pid <= 1 {
        return None;
    }
    let dir = format!("/proc/{pid}");
    if std::fs::metadata(&dir).ok()?.uid() != uid {
        return None;
    }
    let stat = std::fs::read_to_string(format!("{dir}/stat")).ok()?;
    let (exe, parent) = session_window::parse_stat(&stat)?;
    Some(Proc { parent, exe })
}

fn my_uid() -> u32 {
    unsafe { libc::getuid() }
}

/// The ancestors of a process, nearest first, below the top of the tree.
pub fn process_ancestors(pid: u32) -> Vec<u32> {
    let uid = my_uid();
    let mut procs = HashMap::new();
    let mut current = pid;
    // The relay, its ancestors, and the one that ends the walk.
    for _ in 0..session_window::MAX_DEPTH + 2 {
        let Some(p) = read_proc(current, uid) else { break };
        let parent = p.parent;
        procs.insert(current, p);
        if procs.contains_key(&parent) {
            break;
        }
        current = parent;
    }
    session_window::ancestors(&procs, pid)
}

/// What a session remembers: every ancestor. Which one owns a window is asked
/// when the button is clicked.
pub fn window_owners(ancestors: &[u32]) -> Vec<u32> {
    ancestors.to_vec()
}

/// The remembered ancestors still alive and still each other's parents, with
/// their names: a closed terminal's IDs may since belong to someone else.
fn still_linked(owners: &[u32]) -> Vec<(u32, String)> {
    let uid = my_uid();
    let procs: Vec<Option<Proc>> = owners.iter().map(|pid| read_proc(*pid, uid)).collect();
    linked_chain(owners, &procs)
}

/// `procs[i]` is what /proc says now of `owners[i]`. The nearest ones may have
/// exited — the `sh -c` that ran the relay does — so the chain starts at the
/// first one alive and still the child of the next, and ends where a process
/// is gone or its parent is no longer the next one.
fn linked_chain(owners: &[u32], procs: &[Option<Proc>]) -> Vec<(u32, String)> {
    let linked = |i: usize| {
        procs[i].as_ref().is_some_and(|p| owners.get(i + 1).is_none_or(|next| p.parent == *next))
    };
    let Some(start) = (0..owners.len().min(procs.len())).find(|i| linked(*i)) else { return Vec::new() };
    let mut out = Vec::new();
    for i in start..owners.len().min(procs.len()) {
        let Some(p) = &procs[i] else { break };
        out.push((owners[i], p.exe.clone()));
        if !linked(i) {
            break;
        }
    }
    out
}

// ── Bringing the window forward ───────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Method {
    KWin,
    X11,
}

/// Best first. On Plasma's Wayland session KWin sees every window, native or
/// XWayland; elsewhere EWMH is the standard way, with KWin's script as a
/// second try on Plasma's X11 session.
fn methods(session_type: &str, wayland_display: &str, display: &str, desktop: &str) -> Vec<Method> {
    let wayland = session_type.eq_ignore_ascii_case("wayland") || !wayland_display.trim().is_empty();
    let x11 = !display.trim().is_empty();
    let kde = desktop.split(':').any(|d| d.eq_ignore_ascii_case("kde"));
    let mut out = Vec::new();
    if kde && wayland {
        out.push(Method::KWin);
    }
    if x11 {
        out.push(Method::X11);
    }
    if kde && !wayland {
        out.push(Method::KWin);
    }
    out
}

/// Brings forward the window a session remembered: the nearest ancestor's,
/// the one titled after `folder` if it has several. False when no way worked,
/// so the caller falls back to VS Code.
pub fn focus_session_window(owners: &[u32], folder: &str) -> bool {
    let chain = still_linked(owners);
    if chain.is_empty() {
        return false;
    }
    let pids: Vec<u32> = chain.iter().map(|(pid, _)| *pid).collect();
    let tab = kitty::focus_tab(&chain);
    let env = |k: &str| std::env::var(k).unwrap_or_default();
    let raised = methods(
        &env("XDG_SESSION_TYPE"),
        &env("WAYLAND_DISPLAY"),
        &env("DISPLAY"),
        &env("XDG_CURRENT_DESKTOP"),
    )
    .into_iter()
    .any(|method| {
        let done = match method {
            Method::KWin => kwin::activate(&pids, folder),
            Method::X11 => x11::activate(&pids, folder),
        };
        if done {
            crate::log::line(format!("open terminal: window raised ({method:?})"));
        }
        done
    });
    tab || raised
}

/// Runs a helper with nothing attached and a time limit; true when it exits 0.
fn run_quietly(cmd: &mut Command, limit: Duration) -> bool {
    let Ok(mut child) = cmd.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn() else {
        return false;
    };
    let deadline = Instant::now() + limit;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return status.success(),
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(20)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return false;
            }
        }
    }
}

// ── X11: EWMH ─────────────────────────────────────────────────────────────────

mod x11 {
    use x11rb::connection::Connection;
    use x11rb::protocol::xproto::{AtomEnum, ClientMessageEvent, ConnectionExt, EventMask, Window};
    use x11rb::rust_connection::RustConnection;

    use crate::session_window;

    type Fallible<T> = Result<T, Box<dyn std::error::Error>>;

    pub fn activate(ancestors: &[u32], folder: &str) -> bool {
        try_activate(ancestors, folder).unwrap_or(false)
    }

    fn atom(conn: &RustConnection, name: &str) -> Fallible<u32> {
        Ok(conn.intern_atom(false, name.as_bytes())?.reply()?.atom)
    }

    fn cardinal(conn: &RustConnection, window: Window, prop: u32) -> Option<u32> {
        let reply = conn.get_property(false, window, prop, AtomEnum::CARDINAL, 0, 1).ok()?.reply().ok()?;
        let value = reply.value32()?.next();
        value
    }

    /// `_NET_WM_NAME` (UTF-8), else the legacy `WM_NAME`.
    fn title(conn: &RustConnection, window: Window, net_wm_name: u32, utf8: u32) -> String {
        let read = |prop: u32, kind: u32| {
            conn.get_property(false, window, prop, kind, 0, 1024)
                .ok()
                .and_then(|c| c.reply().ok())
                .map(|r| String::from_utf8_lossy(&r.value).into_owned())
                .filter(|t| !t.is_empty())
        };
        read(net_wm_name, utf8)
            .or_else(|| read(AtomEnum::WM_NAME.into(), AtomEnum::STRING.into()))
            .unwrap_or_default()
    }

    fn try_activate(ancestors: &[u32], folder: &str) -> Fallible<bool> {
        let (conn, screen) = x11rb::connect(None)?;
        let root = conn.setup().roots.get(screen).ok_or("no screen")?.root;
        let client_list = atom(&conn, "_NET_CLIENT_LIST")?;
        let wm_pid = atom(&conn, "_NET_WM_PID")?;
        let net_wm_name = atom(&conn, "_NET_WM_NAME")?;
        let utf8 = atom(&conn, "UTF8_STRING")?;
        let active = atom(&conn, "_NET_ACTIVE_WINDOW")?;
        let wm_desktop = atom(&conn, "_NET_WM_DESKTOP")?;
        let current_desktop = atom(&conn, "_NET_CURRENT_DESKTOP")?;

        let clients: Vec<Window> = conn
            .get_property(false, root, client_list, AtomEnum::WINDOW, 0, 4096)?
            .reply()?
            .value32()
            .map(|v| v.collect())
            .unwrap_or_default();
        // Every window's process in one round trip; a window gone meanwhile is skipped.
        let cookies: Vec<_> = clients
            .iter()
            .map(|w| conn.get_property(false, *w, wm_pid, AtomEnum::CARDINAL, 0, 1))
            .collect::<Result<_, _>>()?;
        let mut windows: Vec<(Window, u32, String)> = Vec::new();
        for (window, cookie) in clients.iter().zip(cookies) {
            let Ok(reply) = cookie.reply() else { continue };
            let pid = reply.value32().and_then(|mut v| v.next());
            let Some(pid) = pid else { continue };
            if ancestors.contains(&pid) {
                windows.push((*window, pid, title(&conn, *window, net_wm_name, utf8)));
            }
        }
        let Some(&target) = session_window::choose_window(ancestors, &windows, folder) else {
            return Ok(false);
        };

        let to_root = EventMask::SUBSTRUCTURE_REDIRECT | EventMask::SUBSTRUCTURE_NOTIFY;
        // Its workspace first, for the window managers that won't switch on their own.
        if let Some(desktop) = cardinal(&conn, target, wm_desktop).filter(|d| *d != u32::MAX) {
            let ev = ClientMessageEvent::new(32, root, current_desktop, [desktop, 0, 0, 0, 0]);
            conn.send_event(false, root, to_root, ev)?;
        }
        // Source 2: a pager acting for the user, which window managers honour
        // over their focus-stealing prevention. Timestamp 0: "now".
        let ev = ClientMessageEvent::new(32, target, active, [2, 0, 0, 0, 0]);
        conn.send_event(false, root, to_root, ev)?;
        conn.flush()?;
        Ok(true)
    }
}

// ── KDE Plasma: a KWin script over D-Bus ──────────────────────────────────────

mod kwin {
    use std::io::Write;
    use std::sync::atomic::{AtomicU32, AtomicU8, Ordering};
    use std::sync::Arc;

    use dbus::blocking::Connection;
    use dbus::channel::MatchingReceiver;
    use dbus::message::MatchRule;

    use super::*;

    /// Where the script says what it did: our own connection, this interface.
    const REPLY_INTERFACE: &str = "fr.louisraille.Nova.Focus";
    const KWIN: &str = "org.kde.KWin";
    const TIMEOUT: Duration = Duration::from_secs(2);

    static COUNTER: AtomicU32 = AtomicU32::new(0);

    /// A unique bus name as the bus hands it out (`:1.42`), nothing else: it is
    /// the one string the script holds.
    fn is_unique_name(name: &str) -> bool {
        let Some(rest) = name.strip_prefix(':') else { return false };
        let mut parts = rest.split('.');
        let ok = |p: Option<&str>| p.is_some_and(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()));
        ok(parts.next()) && ok(parts.next()) && parts.next().is_none()
    }

    /// The script: finds the windows of the nearest ancestor that has any —
    /// the one whose caption names the folder, else the first — activates it,
    /// and calls `reply_to` back with `Activated` or `NotFound`. Process IDs
    /// are numbers and the folder name travels as character codes, so nothing
    /// in it can be read as code. Works on Plasma 6 (`windowList`,
    /// `activeWindow`) and Plasma 5 (`clientList`, `activeClient`).
    pub(super) fn script(pids: &[u32], folder: &str, reply_to: &str) -> Option<String> {
        if !is_unique_name(reply_to) || pids.is_empty() {
            return None;
        }
        let pids = pids.iter().map(u32::to_string).collect::<Vec<_>>().join(", ");
        let folder = folder.to_lowercase().encode_utf16().map(|c| c.to_string()).collect::<Vec<_>>().join(", ");
        Some(format!(
            r#"(function () {{
    var pids = [{pids}];
    var folder = String.fromCharCode({folder});
    var plasma6 = typeof workspace.windowList === "function";
    var windows = plasma6 ? workspace.windowList() : workspace.clientList();
    var found = null;
    for (var i = 0; i < pids.length && !found; i++) {{
        var first = null;
        for (var j = 0; j < windows.length; j++) {{
            var w = windows[j];
            if (w.pid !== pids[i] || !w.normalWindow) continue;
            if (!first) first = w;
            if (folder && String(w.caption).toLowerCase().indexOf(folder) >= 0) {{ found = w; break; }}
        }}
        if (!found) found = first;
    }}
    if (found) {{
        if (found.minimized) found.minimized = false;
        if (plasma6) workspace.activeWindow = found; else workspace.activeClient = found;
    }}
    callDBus("{reply_to}", "/", "{REPLY_INTERFACE}", found ? "Activated" : "NotFound");
}})();
"#
        ))
    }

    /// Unloads the script and removes its file, whatever happened.
    struct Loaded<'a> {
        conn: &'a Connection,
        name: String,
        path: PathBuf,
    }

    impl Drop for Loaded<'_> {
        fn drop(&mut self) {
            let proxy = self.conn.with_proxy(KWIN, "/Scripting", TIMEOUT);
            let _: Result<(bool,), _> = proxy.method_call("org.kde.kwin.Scripting", "unloadScript", (self.name.as_str(),));
            let _ = std::fs::remove_file(&self.path);
        }
    }

    /// The runtime directory, checked private, where the script file is written.
    fn script_dir() -> Option<PathBuf> {
        super::super::relay_socket_path()?.parent().map(Path::to_path_buf)
    }

    pub fn activate(pids: &[u32], folder: &str) -> bool {
        let Ok(conn) = Connection::new_session() else { return false };
        let reply_to = conn.unique_name().to_string();
        let Some(text) = script(pids, folder, &reply_to) else { return false };
        let Some(dir) = script_dir() else { return false };

        // 0 unanswered, 1 activated, 2 not found.
        let outcome = Arc::new(AtomicU8::new(0));
        let seen = outcome.clone();
        conn.start_receive(
            MatchRule::new_method_call(),
            Box::new(move |msg, c| {
                if msg.interface().as_deref() == Some(REPLY_INTERFACE) {
                    let result = if msg.member().as_deref() == Some("Activated") { 1 } else { 2 };
                    seen.store(result, Ordering::SeqCst);
                    let _ = dbus::channel::Sender::send(c, msg.method_return());
                }
                true
            }),
        );

        let name = format!("nova-focus-{}-{}", std::process::id(), COUNTER.fetch_add(1, Ordering::Relaxed));
        let path = dir.join(format!("{name}.js"));
        let written = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)
            .and_then(|mut f| f.write_all(text.as_bytes()));
        if written.is_err() {
            let _ = std::fs::remove_file(&path);
            return false;
        }
        let loaded = Loaded { conn: &conn, name, path };

        let scripting = conn.with_proxy(KWIN, "/Scripting", TIMEOUT);
        let Some(path_str) = loaded.path.to_str() else { return false };
        let id: i32 = match scripting.method_call("org.kde.kwin.Scripting", "loadScript", (path_str, loaded.name.as_str())) {
            Ok((id,)) => id,
            Err(_) => return false,
        };
        if id < 0 {
            return false;
        }
        // Plasma 6 puts the script at /Scripting/Script<id>, Plasma 5 at /<id>.
        let run = |path: String| {
            conn.with_proxy(KWIN, path, TIMEOUT).method_call::<(), _, _, _>("org.kde.kwin.Script", "run", ())
        };
        if run(format!("/Scripting/Script{id}")).is_err() && run(format!("/{id}")).is_err() {
            return false;
        }

        // KWin reads the file and runs it on its own time; wait for the answer.
        let deadline = Instant::now() + TIMEOUT;
        while outcome.load(Ordering::SeqCst) == 0 && Instant::now() < deadline {
            let _ = conn.process(Duration::from_millis(50));
        }
        let activated = outcome.load(Ordering::SeqCst) == 1;
        drop(loaded);
        activated
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn only_a_bus_unique_name_is_put_in_the_script() {
            assert!(is_unique_name(":1.42"));
            assert!(is_unique_name(":12.3456"));
            for bad in ["", ":", ":1", ":1.", ":.1", "1.42", ":1.42.3", ":1.4a", "org.kde.KWin", ":1.42\"); x(\""] {
                assert!(!is_unique_name(bad), "{bad}");
            }
            assert!(script(&[1], "x", "org.kde.KWin").is_none());
            assert!(script(&[], "x", ":1.2").is_none());
        }

        #[test]
        fn the_script_holds_numbers_only() {
            let text = script(&[4242, 17], "Café \"); evil(); //", ":1.42").unwrap();
            assert!(text.contains("var pids = [4242, 17];"));
            // The folder travels as UTF-16 codes, lower-cased: no quote, no word of it.
            assert!(text.contains("String.fromCharCode(99, 97, 102, 233, 32, 34, 41, 59, 32"));
            assert!(!text.contains("evil"));
            assert!(text.contains(r#"callDBus(":1.42", "/", "fr.louisraille.Nova.Focus""#));
            // Apart from the code itself, every quoted string is one we wrote.
            let quoted: Vec<&str> = text.split('"').skip(1).step_by(2).collect();
            assert_eq!(quoted, ["function", ":1.42", "/", "fr.louisraille.Nova.Focus", "Activated", "NotFound"]);

            let empty = script(&[1], "", ":1.2").unwrap();
            assert!(empty.contains("String.fromCharCode();"));
            assert!(empty.contains("workspace.activeWindow = found") && empty.contains("workspace.activeClient = found"));
        }
    }
}

// ── kitty: the session's tab ──────────────────────────────────────────────────

mod kitty {
    use super::*;

    /// `KITTY_LISTEN_ON` from a process environment (NUL-separated), when it is
    /// a Unix socket address made of plain path characters.
    pub(super) fn listen_on(environ: &[u8]) -> Option<String> {
        let value = environ
            .split(|b| *b == 0)
            .find_map(|entry| entry.strip_prefix(b"KITTY_LISTEN_ON="))?;
        let value = std::str::from_utf8(value).ok()?;
        let path = value.strip_prefix("unix:")?;
        let plain = |c: char| c.is_ascii_alphanumeric() || "/_.-@+:".contains(c);
        (!path.is_empty() && path.len() <= 107 && path.chars().all(plain)).then(|| value.to_string())
    }

    /// `kitten` beside the running kitty, else on $PATH.
    fn kitten(kitty_pid: u32) -> Option<PathBuf> {
        let beside = std::fs::read_link(format!("/proc/{kitty_pid}/exe"))
            .ok()
            .and_then(|exe| exe.parent().map(|d| d.join("kitten")));
        beside
            .filter(|p| std::fs::metadata(p).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0))
            .or_else(|| super::super::find_on_path("kitten"))
    }

    /// When the session runs in kitty and kitty's remote control listens on a
    /// socket (`listen_on` and `allow_remote_control`), focuses the session's
    /// tab and window. Quietly nothing otherwise.
    pub fn focus_tab(chain: &[(u32, String)]) -> bool {
        let Some(at) = chain.iter().position(|(_, name)| name == "kitty") else { return false };
        let Some((shell, _)) = at.checked_sub(1).and_then(|i| chain.get(i)) else { return false };
        let kitty_pid = chain[at].0;
        let Ok(environ) = std::fs::read(format!("/proc/{shell}/environ")) else { return false };
        let Some(to) = listen_on(&environ) else { return false };
        let Some(kitten) = kitten(kitty_pid) else { return false };
        run_quietly(
            Command::new(kitten).args(["@", "--to", &to, "focus-window", "--match", &format!("pid:{shell}")]),
            Duration::from_secs(2),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_best_way_comes_first_for_each_desktop() {
        use Method::*;
        // Plasma on Wayland: KWin sees everything; XWayland as a second try.
        assert_eq!(methods("wayland", "wayland-0", ":0", "KDE"), [KWin, X11]);
        assert_eq!(methods("", "wayland-0", "", "KDE"), [KWin]);
        // Plasma on X11: EWMH, then KWin.
        assert_eq!(methods("x11", "", ":0", "KDE"), [X11, KWin]);
        // Any X11 session.
        assert_eq!(methods("x11", "", ":0", "XFCE"), [X11]);
        // GNOME on Wayland: only XWayland windows can be reached.
        assert_eq!(methods("wayland", "wayland-0", ":0", "ubuntu:GNOME"), [X11]);
        assert_eq!(methods("wayland", "wayland-0", "", "GNOME"), []);
        assert_eq!(methods("tty", "", "", ""), []);
    }

    #[test]
    fn kitty_sockets_are_read_from_the_shell_environment() {
        let env = b"HOME=/home/me\0KITTY_LISTEN_ON=unix:/tmp/kitty-4242\0TERM=xterm-kitty\0";
        assert_eq!(kitty::listen_on(env).as_deref(), Some("unix:/tmp/kitty-4242"));
        assert_eq!(kitty::listen_on(b"KITTY_LISTEN_ON=unix:@mykitty\0").as_deref(), Some("unix:@mykitty"));
        // Not a socket of the expected shape: left alone.
        assert_eq!(kitty::listen_on(b"KITTY_LISTEN_ON=tcp:localhost:5000\0"), None);
        assert_eq!(kitty::listen_on(b"KITTY_LISTEN_ON=unix:/tmp/a b\0"), None);
        assert_eq!(kitty::listen_on(b"KITTY_LISTEN_ON=unix:$(rm)\0"), None);
        assert_eq!(kitty::listen_on(b"KITTY_LISTEN_ON=unix:\0"), None);
        assert_eq!(kitty::listen_on(b"XKITTY_LISTEN_ON=unix:/x\0"), None);
        assert_eq!(kitty::listen_on(b""), None);
    }

    #[test]
    fn our_own_ancestors_are_read_from_proc() {
        // This test process's parent is ours (cargo) or the walk stops above it:
        // either way every ID found is a live process of ours, nearest first.
        let me = std::process::id();
        let found = process_ancestors(me);
        let linked = still_linked(&found);
        assert_eq!(linked.len(), found.len());
        assert!(!found.contains(&me) && !found.contains(&1));
        assert!(still_linked(&[u32::MAX - 1]).is_empty());
    }

    #[test]
    fn a_chain_starts_past_exited_shells_and_ends_where_it_breaks() {
        let p = |parent: u32, name: &str| Some(Proc { parent, exe: name.to_string() });
        let names = |chain: Vec<(u32, String)>| chain.into_iter().map(|(pid, _)| pid).collect::<Vec<_>>();
        // sh (gone) → claude → bash → kitty
        let owners = [10, 20, 30, 40];
        let alive = [None, p(30, "claude"), p(40, "bash"), p(1, "kitty")];
        assert_eq!(names(linked_chain(&owners, &alive)), [20, 30, 40]);
        assert_eq!(linked_chain(&owners, &alive)[2].1, "kitty");
        // An ID reused by an unrelated process is not a start.
        let reused = [p(999, "other"), p(30, "claude"), p(40, "bash"), p(1, "kitty")];
        assert_eq!(names(linked_chain(&owners, &reused)), [20, 30, 40]);
        // The terminal closed and its ID went to someone else: cut there.
        let closed = [None, p(30, "claude"), p(40, "bash"), None];
        assert_eq!(names(linked_chain(&owners, &closed)), [20, 30]);
        let moved = [None, p(30, "claude"), p(77, "bash"), p(1, "kitty")];
        assert_eq!(names(linked_chain(&owners, &moved)), [20, 30]);
        // Nothing left.
        assert!(linked_chain(&owners, &[None, None, None, None]).is_empty());
        assert!(linked_chain(&[], &[]).is_empty());
    }
}
