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
//   * driftwm: `driftwm msg state` names each window's client PID, and
//     `driftwm msg focus --id` raises it;
//   * a session inside tmux: the pane is found from the environment tmux
//     gives it, the client attached to its session from `tmux list-clients`,
//     and that client's terminal is the window to raise, whatever the
//     terminal; tmux then shows the pane's window;
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
use std::io::Read;
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
    Driftwm,
}

/// Best first. On Plasma's Wayland session KWin sees every window, native or
/// XWayland; elsewhere EWMH is the standard way, with KWin's script as a
/// second try on Plasma's X11 session.
fn methods(session_type: &str, wayland_display: &str, display: &str, desktop: &str) -> Vec<Method> {
    let wayland = session_type.eq_ignore_ascii_case("wayland") || !wayland_display.trim().is_empty();
    let x11 = !display.trim().is_empty();
    let kde = desktop.split(':').any(|d| d.eq_ignore_ascii_case("kde"));
    let driftwm = desktop.split(':').any(|d| d.eq_ignore_ascii_case("driftwm"));
    let mut out = Vec::new();
    if driftwm && wayland {
        out.push(Method::Driftwm);
    }
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
    if let Some(pane) = tmux::locate(&chain) {
        return tmux::focus(&pane, folder);
    }
    raise(&chain, &[folder])
}

/// Brings forward the terminal or editor window at the end of `chain`. Where
/// windows can only be told apart by title (a compositor that reports no PID),
/// the first of `names` found in a title wins.
fn raise(chain: &[(u32, String)], names: &[&str]) -> bool {
    let folder = names.first().copied().unwrap_or_default();
    let pids: Vec<u32> = chain.iter().map(|(pid, _)| *pid).collect();
    let tab = kitty::focus_tab(chain);
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
            Method::Driftwm => driftwm::activate(chain, names),
        };
        if done {
            crate::log::line(format!("open terminal: window raised ({method:?})"));
        }
        done
    });
    tab || raised
}

/// True when the session runs in a terminal emulator. Such a session has no
/// folder to open instead: when its window could not be raised, nothing is
/// opened rather than an editor or an empty terminal.
pub fn runs_in_terminal(owners: &[u32]) -> bool {
    terminal_in(&still_linked(owners)).is_some()
}

/// The terminal emulator in a chain: the nearest process that holds the master
/// side of a pseudo-terminal, whatever it is called. A shell or an agent only
/// holds the slave side.
fn terminal_in(chain: &[(u32, String)]) -> Option<&(u32, String)> {
    chain.iter().find(|(pid, _)| holds_pty_master(*pid))
}

fn holds_pty_master(pid: u32) -> bool {
    let Ok(fds) = std::fs::read_dir(format!("/proc/{pid}/fd")) else { return false };
    fds.flatten().any(|fd| std::fs::read_link(fd.path()).is_ok_and(|t| t == Path::new("/dev/ptmx")))
}

/// Whether a window's `app_id` names the process `name` (as /proc keeps it, 15
/// bytes): `foot` ↔ `foot`, `kitty` ↔ `kitty`, `gnome-terminal-` ↔
/// `org.gnome.Terminal`, `wezterm-gui` ↔ `org.wezfurlong.wezterm`.
pub(crate) fn same_app(app_id: &str, name: &str) -> bool {
    let last = app_id.rsplit('.').next().unwrap_or(app_id).to_lowercase();
    let name = name.to_lowercase();
    !last.is_empty() && !name.is_empty() && (name.contains(&last) || last.contains(&name))
}

/// Runs a helper with nothing attached and a time limit; its output when it exits 0.
fn capture(cmd: &mut Command, limit: Duration) -> Option<Vec<u8>> {
    let mut child = cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().ok()?;
    let mut stdout = child.stdout.take()?;
    // Read alongside, so a reply larger than the pipe never stalls the helper.
    let reader = std::thread::spawn(move || {
        let mut out = Vec::new();
        let _ = stdout.read_to_end(&mut out);
        out
    });
    let deadline = Instant::now() + limit;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return reader.join().ok().filter(|_| status.success()),
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(20)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
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
    const REPLY_INTERFACE: &str = "fr.louisraille.Coucou.Focus";
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

        let name = format!("coucou-focus-{}-{}", std::process::id(), COUNTER.fetch_add(1, Ordering::Relaxed));
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
            assert!(text.contains(r#"callDBus(":1.42", "/", "fr.louisraille.Coucou.Focus""#));
            // Apart from the code itself, every quoted string is one we wrote.
            let quoted: Vec<&str> = text.split('"').skip(1).step_by(2).collect();
            assert_eq!(quoted, ["function", ":1.42", "/", "fr.louisraille.Coucou.Focus", "Activated", "NotFound"]);

            let empty = script(&[1], "", ":1.2").unwrap();
            assert!(empty.contains("String.fromCharCode();"));
            assert!(empty.contains("workspace.activeWindow = found") && empty.contains("workspace.activeClient = found"));
        }
    }
}

// ── kitty: the session's tab ──────────────────────────────────────────────────

mod driftwm {
    use super::*;

    /// The window to raise from a `driftwm msg --json state` reply. With the
    /// `pid` a driftwm that reports one gives each client, the nearest ancestor's
    /// own window. Without it, the terminal's windows are told by `app_id`, and
    /// the one titled after the session's folder is taken — or the only one.
    pub(super) fn pick(state: &serde_json::Value, chain: &[(u32, String)], names: &[&str]) -> Option<u64> {
        let folder = names.first().copied().unwrap_or_default();
        let windows = state.pointer("/Ok/State/windows")?.as_array()?;
        let text = |w: &serde_json::Value, key: &str| w.get(key).and_then(|t| t.as_str()).unwrap_or_default().to_string();
        let by_pid: Vec<(u64, u32, String)> = windows
            .iter()
            .filter_map(|w| {
                let pid = u32::try_from(w.get("pid")?.as_u64()?).ok()?;
                Some((w.get("id")?.as_u64()?, pid, text(w, "title")))
            })
            .collect();
        if !by_pid.is_empty() {
            let pids: Vec<u32> = chain.iter().map(|(pid, _)| *pid).collect();
            return session_window::choose_window(&pids, &by_pid, folder).copied();
        }
        let (_, terminal) = terminal_in(chain)?;
        let mine: Vec<(u64, String)> = windows
            .iter()
            .filter(|w| same_app(&text(w, "app_id"), terminal))
            .filter_map(|w| Some((w.get("id")?.as_u64()?, text(w, "title"))))
            .collect();
        for name in names.iter().map(|n| n.to_lowercase()).filter(|n| !n.is_empty()) {
            let named: Vec<&(u64, String)> = mine.iter().filter(|(_, title)| title.to_lowercase().contains(&name)).collect();
            if let [(id, _)] = named.as_slice() {
                return Some(*id);
            }
        }
        match mine.as_slice() {
            [(id, _)] => Some(*id),
            _ => None,
        }
    }

    pub fn activate(chain: &[(u32, String)], names: &[&str]) -> bool {
        let Some(driftwm) = super::super::find_on_path("driftwm") else { return false };
        let limit = Duration::from_secs(2);
        let Some(reply) = capture(Command::new(&driftwm).args(["msg", "--json", "state"]), limit) else {
            return false;
        };
        let Ok(state) = serde_json::from_slice::<serde_json::Value>(&reply) else { return false };
        let Some(id) = pick(&state, chain, names) else { return false };
        run_quietly(Command::new(&driftwm).args(["msg", "focus", "--id", &id.to_string()]), limit)
    }
}

mod tmux {
    use super::*;

    /// A session's pane: the server's socket and the pane's id, from the
    /// environment tmux gives every process it starts.
    pub(super) struct Pane {
        pub socket: PathBuf,
        pub id: String,
    }

    /// The pane's place: its session and window, and the session's name, which
    /// a terminal's title usually carries (tmux's `set-titles`).
    struct Target {
        session: String,
        window: String,
        name: String,
    }

    /// A terminal attached to the server.
    pub(super) struct Client {
        pub pid: u32,
        pub tty: String,
        pub session: String,
        pub activity: u64,
    }

    pub(super) fn locate(chain: &[(u32, String)]) -> Option<Pane> {
        chain.iter().find_map(|(pid, _)| parse(&std::fs::read(format!("/proc/{pid}/environ")).ok()?))
    }

    /// `TMUX=<socket>,<server pid>,<session>` and `TMUX_PANE=%<n>`, when both
    /// are of the expected shape.
    pub(super) fn parse(environ: &[u8]) -> Option<Pane> {
        let var = |name: &[u8]| environ.split(|b| *b == 0).find_map(|e| e.strip_prefix(name));
        let socket = std::str::from_utf8(var(b"TMUX=")?).ok()?.split(',').next()?;
        let id = std::str::from_utf8(var(b"TMUX_PANE=")?).ok()?;
        let plain = |c: char| c.is_ascii_alphanumeric() || "/_.-@+".contains(c);
        let socket_ok = !socket.is_empty() && socket.len() <= 107 && socket.starts_with('/') && socket.chars().all(plain);
        (socket_ok && is_id(id, '%')).then(|| Pane { socket: PathBuf::from(socket), id: id.to_string() })
    }

    /// `%3`, `$0`, `@12`: a sigil and digits, as tmux names panes, sessions and windows.
    fn is_id(s: &str, sigil: char) -> bool {
        let digits = s.strip_prefix(sigil).unwrap_or_default();
        !digits.is_empty() && digits.len() <= 12 && digits.bytes().all(|b| b.is_ascii_digit())
    }

    fn is_tty(s: &str) -> bool {
        s.starts_with("/dev/") && s.len() <= 32 && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '/')
    }

    /// `tmux -S <socket> …`, with the server's own binary when it can be read.
    fn command(pane: &Pane) -> Option<Command> {
        let tmux = super::super::find_on_path("tmux")?;
        let mut cmd = Command::new(tmux);
        cmd.arg("-S").arg(&pane.socket);
        Some(cmd)
    }

    fn ask(pane: &Pane, args: &[&str]) -> Option<String> {
        let out = capture(command(pane)?.args(args), Duration::from_secs(2))?;
        Some(String::from_utf8_lossy(&out).into_owned())
    }

    fn tell(pane: &Pane, args: &[&str]) -> bool {
        command(pane).is_some_and(|mut cmd| run_quietly(cmd.args(args), Duration::from_secs(2)))
    }

    fn target(pane: &Pane) -> Option<Target> {
        let line = ask(pane, &["display-message", "-p", "-t", &pane.id, "#{session_id}\t#{window_id}\t#{session_name}"])?;
        let mut parts = line.trim_end_matches('\n').splitn(3, '\t');
        let (session, window, name) = (parts.next()?, parts.next()?, parts.next().unwrap_or_default());
        (is_id(session, '$') && is_id(window, '@'))
            .then(|| Target { session: session.into(), window: window.into(), name: name.into() })
    }

    fn clients(pane: &Pane) -> Vec<Client> {
        ask(pane, &["list-clients", "-F", "#{client_pid}\t#{client_tty}\t#{session_id}\t#{client_activity}"])
            .map(|text| parse_clients(&text))
            .unwrap_or_default()
    }

    pub(super) fn parse_clients(text: &str) -> Vec<Client> {
        text.lines()
            .filter_map(|line| {
                let mut p = line.split('\t');
                let pid = p.next()?.parse().ok()?;
                let tty = p.next()?;
                let session = p.next()?;
                let activity = p.next().and_then(|a| a.parse().ok()).unwrap_or(0);
                (is_tty(tty) && is_id(session, '$')).then(|| Client { pid, tty: tty.into(), session: session.into(), activity })
            })
            .collect()
    }

    /// The client to show the pane in: one attached to its session, else the
    /// one used last, which is switched to the session.
    pub(super) fn choose<'a>(clients: &'a [Client], session: &str) -> Option<&'a Client> {
        clients
            .iter()
            .filter(|c| c.session == session)
            .max_by_key(|c| c.activity)
            .or_else(|| clients.iter().max_by_key(|c| c.activity))
    }

    /// Raises the window of the terminal the pane is shown in, and makes tmux
    /// show the pane: its window in front, that client on its session.
    pub(super) fn focus(pane: &Pane, folder: &str) -> bool {
        let Some(target) = target(pane) else { return false };
        let clients = clients(pane);
        let Some(client) = choose(&clients, &target.session) else { return false };
        let chain = still_linked(&process_ancestors(client.pid));
        let raised = raise(&chain, &[folder, &target.name]);
        if client.session != target.session {
            tell(pane, &["switch-client", "-c", &client.tty, "-t", &target.session]);
        }
        let shown = tell(pane, &["select-window", "-t", &target.window])
            && tell(pane, &["select-pane", "-t", &pane.id]);
        if shown {
            crate::log::line(format!("open terminal: tmux pane {} shown", pane.id));
        }
        raised || shown
    }
}

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
        // driftwm on Wayland: its own IPC first; XWayland windows as a second try.
        assert_eq!(methods("wayland", "wayland-1", ":1", "driftwm"), [Driftwm, X11]);
        assert_eq!(methods("", "wayland-1", "", "driftwm"), [Driftwm]);
    }

    fn chain(entries: &[(u32, &str)]) -> Vec<(u32, String)> {
        entries.iter().map(|(pid, name)| (*pid, name.to_string())).collect()
    }

    #[test]
    fn a_tmux_pane_is_read_from_the_environment_tmux_gives_it() {
        let env = b"HOME=/home/me\0TMUX=/tmp/tmux-1000/default,4242,0\0TMUX_PANE=%7\0";
        let pane = tmux::parse(env).unwrap();
        assert_eq!(pane.socket, Path::new("/tmp/tmux-1000/default"));
        assert_eq!(pane.id, "%7");
        assert!(tmux::parse(b"TMUX=/tmp/tmux-1000/default,1,0\0").is_none());
        assert!(tmux::parse(b"TMUX=/tmp/x,1,0\0TMUX_PANE=7\0").is_none());
        assert!(tmux::parse(b"TMUX=/tmp/a b,1,0\0TMUX_PANE=%7\0").is_none());
        assert!(tmux::parse(b"TMUX=;rm,1,0\0TMUX_PANE=%7\0").is_none());
    }

    #[test]
    fn the_client_on_the_panes_session_is_shown_else_the_one_used_last() {
        let text = "4100\t/dev/pts/6\t$3\t1700000100\n4200\t/dev/pts/3\t$5\t1700000200\nbad\t/dev/pts/1\t$1\t1\n";
        let clients = tmux::parse_clients(text);
        assert_eq!(clients.len(), 2);
        assert_eq!(tmux::choose(&clients, "$3").map(|c| c.pid), Some(4100));
        // Nobody on $0: the most recently used client gets switched to it.
        assert_eq!(tmux::choose(&clients, "$0").map(|c| c.pid), Some(4200));
        assert!(tmux::choose(&[], "$0").is_none());
    }

    #[test]
    fn driftwm_raises_the_nearest_ancestors_window_by_pid() {
        let state = serde_json::json!({"Ok": {"State": {"windows": [
            {"id": 8, "app_id": "foot", "title": "api · claude", "pid": 300},
            {"id": 16, "app_id": "foot", "title": "◑ coucou", "pid": 200},
            {"id": 43, "app_id": "foot", "title": "~/notes", "pid": 100},
            {"id": 50, "app_id": "suspended", "title": ""}
        ]}}});
        // claude (10) → foot (200): foot's window, not another foot's.
        assert_eq!(driftwm::pick(&state, &chain(&[(10, "claude"), (200, "foot")]), &[""]), Some(16));
        assert_eq!(driftwm::pick(&state, &chain(&[(10, "claude"), (999, "foot")]), &[""]), None);
        assert_eq!(driftwm::pick(&serde_json::json!({"Err": "x"}), &chain(&[(200, "foot")]), &[""]), None);
    }

    #[test]
    fn without_pids_the_terminals_window_is_told_by_its_title() {
        // Ancestors that hold a pty master are read from /proc, so the chain
        // here is this test's own process tree with a terminal's name on it.
        let me = std::process::id();
        let holds = holds_pty_master(me);
        let older = serde_json::json!({"Ok": {"State": {"windows": [
            {"id": 8, "app_id": "foot", "title": "api · claude"},
            {"id": 16, "app_id": "foot", "title": "◑ coucou"},
            {"id": 43, "app_id": "org.gnome.Terminal", "title": "~/notes"},
            {"id": 9, "app_id": "chromium", "title": "coucou - GitHub"}
        ]}}});
        if holds {
            assert_eq!(driftwm::pick(&older, &chain(&[(me, "foot")]), &["coucou"]), Some(16));
            assert_eq!(driftwm::pick(&older, &chain(&[(me, "gnome-terminal-")]), &["notes"]), Some(43));
            // The folder names no window, the tmux session does.
            assert_eq!(driftwm::pick(&older, &chain(&[(me, "foot")]), &["me", "api"]), Some(8));
            // Two foot windows and no name in a title: no guess.
            assert_eq!(driftwm::pick(&older, &chain(&[(me, "foot")]), &["other"]), None);
        } else {
            // No terminal in the chain: nothing to match against.
            assert_eq!(driftwm::pick(&older, &chain(&[(me, "foot")]), &["coucou"]), None);
        }
    }

    #[test]
    fn a_window_is_matched_to_its_process_by_app_id() {
        assert!(same_app("foot", "foot"));
        assert!(same_app("Alacritty", "alacritty"));
        assert!(same_app("org.gnome.Terminal", "gnome-terminal-"));
        assert!(same_app("org.wezfurlong.wezterm", "wezterm-gui"));
        assert!(same_app("com.mitchellh.ghostty", "ghostty"));
        assert!(!same_app("chromium", "foot"));
        assert!(!same_app("", "foot"));
        assert!(!runs_in_terminal(&[u32::MAX - 1]));
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
