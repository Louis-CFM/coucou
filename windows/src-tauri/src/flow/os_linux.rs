// Flow dictation on Linux. On X11: the key through XInput 2's raw key events
// (they reach every client without grabbing anything, so no key is ever taken
// away from an app), the paste through XTest, and the app in front from the
// active window's WM_CLASS. Wayland lets no app watch the keyboard: there the
// key goes through the desktop's GlobalShortcuts portal (see wayland.rs).

use std::os::fd::AsRawFd;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;
use std::sync::Arc;
use std::time::{Duration, Instant};

use x11rb::connection::Connection;
use x11rb::protocol::xinput::{self, ConnectionExt as _};
use x11rb::protocol::xproto::{self, AtomEnum, ConnectionExt as _};
use x11rb::protocol::xtest::ConnectionExt as _;
use x11rb::protocol::Event;
use x11rb::rust_connection::RustConnection;
use x11rb::wrapper::ConnectionExt as _;

use super::logic::FlowKey;
use super::KeyEvent;

// Keysyms (X11/keysymdef.h).
const XK_SHIFT_L: u32 = 0xffe1;
const XK_SHIFT_R: u32 = 0xffe2;
const XK_CONTROL_L: u32 = 0xffe3;
const XK_CONTROL_R: u32 = 0xffe4;
const XK_ALT_R: u32 = 0xffea;
const XK_SUPER_L: u32 = 0xffeb;
const XK_ISO_LEVEL3_SHIFT: u32 = 0xfe03;
const XK_ESCAPE: u32 = 0xff1b;
const XK_V: u32 = 0x0076;

/// Whether this session is Wayland (where X11 sees only XWayland's windows).
pub fn is_wayland() -> bool {
    std::env::var("XDG_SESSION_TYPE").map(|v| v.eq_ignore_ascii_case("wayland")).unwrap_or(false)
        || std::env::var_os("WAYLAND_DISPLAY").is_some()
}

/// The keyboard map: keycode → its keysyms.
struct Keymap {
    min: u8,
    per: usize,
    syms: Vec<u32>,
}

impl Keymap {
    fn read(conn: &RustConnection) -> Option<Keymap> {
        let setup = conn.setup();
        let (min, max) = (setup.min_keycode, setup.max_keycode);
        let reply = conn.get_keyboard_mapping(min, max - min + 1).ok()?.reply().ok()?;
        Some(Keymap { min, per: reply.keysyms_per_keycode as usize, syms: reply.keysyms })
    }

    fn syms(&self, keycode: u32) -> &[u32] {
        let i = keycode.saturating_sub(self.min as u32) as usize * self.per;
        self.syms.get(i..i + self.per).unwrap_or(&[])
    }

    fn has(&self, keycode: u32, sym: u32) -> bool {
        self.syms(keycode).contains(&sym)
    }

    fn keycode(&self, sym: u32) -> Option<u8> {
        (0..self.syms.len() / self.per.max(1)).find(|&k| self.syms[k * self.per..(k + 1) * self.per].first() == Some(&sym)).map(|k| k as u8 + self.min)
    }

    fn is_modifier(&self, keycode: u32) -> bool {
        self.syms(keycode).iter().any(|&s| (0xffe1..=0xffee).contains(&s) || s == XK_ISO_LEVEL3_SHIFT || s == 0xff7e)
    }
}

pub struct KeyListener {
    stop: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Drop for KeyListener {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

pub fn keys_supported() -> Result<(), &'static str> {
    if is_wayland() {
        Err("wayland")
    } else if std::env::var_os("DISPLAY").is_none() {
        Err("no-display")
    } else {
        Ok(())
    }
}

pub fn listen(key: FlowKey, tx: Sender<(KeyEvent, Instant)>) -> Result<KeyListener, String> {
    let (conn, screen) = x11rb::connect(None).map_err(|e| e.to_string())?;
    let root = conn.setup().roots[screen].root;
    let version = conn.xinput_xi_query_version(2, 0).map_err(|e| e.to_string())?.reply().map_err(|e| e.to_string())?;
    if version.major_version < 2 {
        return Err("XInput 2 is missing".into());
    }
    let mask = xinput::EventMask {
        deviceid: xinput::Device::ALL_MASTER.into(),
        mask: vec![xinput::XIEventMask::RAW_KEY_PRESS | xinput::XIEventMask::RAW_KEY_RELEASE],
    };
    conn.xinput_xi_select_events(root, &[mask]).map_err(|e| e.to_string())?;
    conn.flush().map_err(|e| e.to_string())?;
    let keymap = Keymap::read(&conn).ok_or("no keyboard map")?;
    let stop = Arc::new(AtomicBool::new(false));
    let stop_thread = stop.clone();
    let thread = std::thread::Builder::new()
        .name("coucou-flow-keys".into())
        .spawn(move || run(conn, keymap, key, tx, stop_thread))
        .map_err(|e| e.to_string())?;
    Ok(KeyListener { stop, thread: Some(thread) })
}

fn run(conn: RustConnection, keymap: Keymap, key: FlowKey, tx: Sender<(KeyEvent, Instant)>, stop: Arc<AtomicBool>) {
    let fd = conn.stream().as_raw_fd();
    let ours = |code: u32| match key {
        FlowKey::RightCtrl => keymap.has(code, XK_CONTROL_R),
        FlowKey::RightAlt => keymap.has(code, XK_ALT_R) || keymap.has(code, XK_ISO_LEVEL3_SHIFT),
        FlowKey::RightShift => keymap.has(code, XK_SHIFT_R),
        FlowKey::LeftCtrlSuper => false,
    };
    let mut combo = 0u8;
    while !stop.load(Ordering::Relaxed) {
        // Sleep in poll() until the server writes, waking now and then for `stop`.
        let mut pfd = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
        unsafe { libc::poll(&mut pfd, 1, 300) };
        loop {
            let event = match conn.poll_for_event() {
                Ok(Some(e)) => e,
                Ok(None) => break,
                Err(_) => return,
            };
            let (code, down) = match event {
                Event::XinputRawKeyPress(e) => (e.detail, true),
                Event::XinputRawKeyRelease(e) => (e.detail, false),
                _ => continue,
            };
            let now = Instant::now();
            if key == FlowKey::LeftCtrlSuper && (keymap.has(code, XK_CONTROL_L) || keymap.has(code, XK_SUPER_L)) {
                let bit = if keymap.has(code, XK_CONTROL_L) { 1 } else { 2 };
                let before = combo;
                combo = if down { combo | bit } else { combo & !bit };
                if combo == 3 && down {
                    let _ = tx.send((KeyEvent::Down, now));
                } else if before == 3 && combo != 3 {
                    let _ = tx.send((KeyEvent::Up, now));
                }
                continue;
            }
            if ours(code) {
                let _ = tx.send((if down { KeyEvent::Down } else { KeyEvent::Up }, now));
            } else if down && keymap.has(code, XK_ESCAPE) {
                let _ = tx.send((KeyEvent::Escape, now));
            } else if down && !keymap.is_modifier(code) {
                let _ = tx.send((KeyEvent::Other, now));
            }
        }
    }
}

/// Nothing to wait for: the paste is sent once the key is up on X11.
pub fn wait_key_released(_key: FlowKey) {
    std::thread::sleep(Duration::from_millis(30));
}

/// Ctrl+V (Ctrl+Shift+V for a terminal) in the app in front: through XTest on
/// X11, through the RemoteDesktop portal on Wayland.
pub fn send_paste(shift: bool) -> Result<(), String> {
    if is_wayland() {
        return super::wayland::send_paste(shift);
    }
    let (conn, screen) = x11rb::connect(None).map_err(|e| e.to_string())?;
    let root = conn.setup().roots[screen].root;
    let keymap = Keymap::read(&conn).ok_or("no keyboard map")?;
    let ctrl = keymap.keycode(XK_CONTROL_L).ok_or("no Ctrl key")?;
    let shift_code = keymap.keycode(XK_SHIFT_L).ok_or("no Shift key")?;
    let v = keymap.keycode(XK_V).ok_or("no V key")?;
    let press = |code: u8, down: bool| {
        conn.xtest_fake_input(if down { xproto::KEY_PRESS_EVENT } else { xproto::KEY_RELEASE_EVENT }, code, 0, root, 0, 0, 0)
    };
    let mut seq = vec![(ctrl, true)];
    if shift {
        seq.push((shift_code, true));
    }
    seq.extend([(v, true), (v, false)]);
    if shift {
        seq.push((shift_code, false));
    }
    seq.push((ctrl, false));
    for (code, down) in seq {
        press(code, down).map_err(|e| e.to_string())?;
    }
    conn.sync().map_err(|e| e.to_string())?;
    Ok(())
}

fn atom(conn: &RustConnection, name: &str) -> Option<u32> {
    Some(conn.intern_atom(false, name.as_bytes()).ok()?.reply().ok()?.atom)
}

/// WM_CLASS's class ("Slack", "gnome-terminal-server") → (id, name).
fn class_of(conn: &RustConnection, window: u32) -> Option<(String, String)> {
    let reply = conn.get_property(false, window, AtomEnum::WM_CLASS, AtomEnum::STRING, 0, 256).ok()?.reply().ok()?;
    let parts: Vec<&[u8]> = reply.value.split(|&b| b == 0).filter(|p| !p.is_empty()).collect();
    let class = String::from_utf8_lossy(parts.last()?).to_string();
    if class.is_empty() || class.eq_ignore_ascii_case("coucou") {
        return None;
    }
    Some((class.to_lowercase(), super::display_name(&class)))
}

/// The app in front: (id, name). None on Wayland, where only the desktop knows.
pub fn foreground_app() -> Option<(String, String)> {
    if is_wayland() {
        return None;
    }
    let (conn, screen) = x11rb::connect(None).ok()?;
    let root = conn.setup().roots[screen].root;
    let active = atom(&conn, "_NET_ACTIVE_WINDOW")?;
    let reply = conn.get_property(false, root, active, AtomEnum::WINDOW, 0, 1).ok()?.reply().ok()?;
    let window = reply.value32()?.next()?;
    if window == 0 {
        return None;
    }
    class_of(&conn, window)
}

/// Apps with a window, for "Add an app" in Styles.
pub fn running_apps() -> Vec<(String, String)> {
    let Ok((conn, screen)) = x11rb::connect(None) else { return Vec::new() };
    let root = conn.setup().roots[screen].root;
    let Some(list) = atom(&conn, "_NET_CLIENT_LIST") else { return Vec::new() };
    let Ok(Ok(reply)) = conn.get_property(false, root, list, AtomEnum::WINDOW, 0, 1024).map(|c| c.reply()) else {
        return Vec::new();
    };
    let mut out: Vec<(String, String)> = Vec::new();
    for window in reply.value32().into_iter().flatten() {
        if let Some(app) = class_of(&conn, window) {
            if !out.iter().any(|(id, _)| *id == app.0) {
                out.push(app);
            }
        }
    }
    out
}

/// Terminals paste with Ctrl+Shift+V.
pub fn is_terminal(id: &str) -> bool {
    matches!(
        id,
        "gnome-terminal-server" | "gnome-terminal" | "kgx" | "org.gnome.console" | "ptyxis" | "konsole" | "kitty"
            | "alacritty" | "xterm" | "uxterm" | "terminator" | "tilix" | "org.wezfurlong.wezterm" | "wezterm"
            | "foot" | "xfce4-terminal" | "mate-terminal" | "lxterminal" | "qterminal" | "blackbox"
            | "com.raggesilver.blackbox" | "ghostty" | "com.mitchellh.ghostty" | "warp" | "terminal"
    )
}
