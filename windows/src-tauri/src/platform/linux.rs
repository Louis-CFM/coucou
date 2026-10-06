// Linux: XDG directories for files, xdg-open for links and folders, and
// gtk-layer-shell for the island window.
//
// Wayland gives an app no global cursor position and no say over where its
// window goes, so the island works differently from Windows:
//   * it is a layer-shell surface anchored to the top edge, above everything,
//     on compositors that support it (COSMIC, KDE, wlroots — not GNOME);
//   * click-through is the window's input region, set to the island shape, so
//     the compositor itself sends every other click to whatever is underneath;
//   * the cursor comes from the page's own mouse events, which only fire over
//     the island — Mochi's eyes follow the pointer there, not across the screen.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

use gtk::glib::translate::ToGlibPtr;
use gtk::prelude::*;
use tauri::{AppHandle, Emitter, WebviewWindow};

use super::{home_dir, LocalTime};

/// File name of the Claude Code relay.
pub const HOOK_EXE: &str = "coucou-hook";

/// Environment variable holding the home directory.
pub const HOME_VAR: &str = "HOME";

// ── Files ─────────────────────────────────────────────────────────────────────

/// An XDG base directory (`$XDG_CONFIG_HOME` …), or its fallback under the home
/// directory when it is unset or not absolute.
fn xdg(var: &str, fallback: &str) -> PathBuf {
    std::env::var_os(var)
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| home_dir().join(fallback))
}

/// ~/.config/coucou — preferences.
pub fn config_dir() -> PathBuf {
    xdg("XDG_CONFIG_HOME", ".config").join("coucou")
}

/// ~/.local/share/coucou — where coucou-hook, the inbox and the log live. The
/// relay has to sit at a stable path: an AppImage is mounted somewhere new on
/// every launch.
pub fn local_dir() -> PathBuf {
    xdg("XDG_DATA_HOME", ".local/share").join("coucou")
}

/// Environment the webview must inherit. Set before any thread or process starts.
pub fn prepare_environment() {
    work_around_nvidia_explicit_sync();
    isolate_appimage_gstreamer_registry();
}

/// With NVIDIA's proprietary driver, WebKitGTK's DMABUF renderer commits frames
/// to a Wayland surface after announcing explicit sync without an acquire point.
/// The compositor answers with a protocol error and the app dies on its first
/// frame ("explicit sync is used, but no acquire point is set", seen on KDE with
/// an RTX 2080 Ti). Software frames avoid it, and an island this small does not
/// need the fast path. A value the user set themselves stays.
fn work_around_nvidia_explicit_sync() {
    if Path::new("/proc/driver/nvidia/version").exists()
        && std::env::var_os("WEBKIT_DISABLE_DMABUF_RENDERER").is_none()
    {
        std::env::set_var("WEBKIT_DISABLE_DMABUF_RENDERER", "1");
    }
}

/// Inside an AppImage, WebKit uses the GStreamer bundled with it, and GStreamer
/// keeps its plugin registry in ~/.cache/gstreamer-1.0 by default — the same
/// file the system's GStreamer uses. The AppImage is mounted somewhere new on
/// every launch, so each launch would rewrite the system's registry with
/// plugin paths that vanish once Coucou quits. Give ours its own file.
fn isolate_appimage_gstreamer_registry() {
    if std::env::var_os("APPIMAGE").is_none() || std::env::var_os("GST_REGISTRY").is_some() {
        return;
    }
    let cache = xdg("XDG_CACHE_HOME", ".cache").join("coucou");
    if std::fs::create_dir_all(&cache).is_ok() {
        std::env::set_var("GST_REGISTRY", cache.join("gstreamer-registry.bin"));
    }
}

pub fn local_time() -> LocalTime {
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    unsafe {
        let now = libc::time(std::ptr::null_mut());
        libc::localtime_r(&now, &mut tm);
    }
    LocalTime {
        year: (tm.tm_year + 1900) as u32,
        month: (tm.tm_mon + 1) as u32,
        day: tm.tm_mday as u32,
        hour: tm.tm_hour as u32,
        minute: tm.tm_min as u32,
        second: tm.tm_sec as u32,
    }
}

/// Creates `dir` and closes it to other users. The log, the inbox of dropped
/// files and the relay binary live under these directories; with the default
/// umask they would come out 0755 and readable by anyone on the machine.
pub fn ensure_private_dir(dir: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(dir)?;
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
}

/// True when `dir` is a real directory (not a symlink), owned by us, with no
/// access for group or others: what `$XDG_RUNTIME_DIR` promises, checked
/// rather than assumed, since the socket in it decides who can answer a
/// permission request.
fn is_private_dir(dir: &Path) -> bool {
    use std::os::unix::fs::MetadataExt;
    std::fs::symlink_metadata(dir)
        .map(|m| {
            m.file_type().is_dir() && m.uid() == unsafe { libc::getuid() } && m.mode() & 0o077 == 0
        })
        .unwrap_or(false)
}

/// Where coucou-hook finds us: `$XDG_RUNTIME_DIR/coucou.sock`, or
/// `/run/user/<uid>/coucou.sock` when the variable is missing. A directory
/// that is not ours and private means no relay at all — never a fallback to a
/// shared place like /tmp. Must match `socket_path()` in hook/src/unix.rs
/// exactly.
pub fn relay_socket_path() -> Option<PathBuf> {
    let dir = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| PathBuf::from(format!("/run/user/{}", unsafe { libc::getuid() })));
    is_private_dir(&dir).then(|| dir.join("coucou.sock"))
}

// ── Processes ─────────────────────────────────────────────────────────────────

/// Nothing to hide: a spawned process only gets a terminal if it asks for one.
pub fn no_console(cmd: &mut Command) -> &mut Command {
    cmd
}

pub fn open_url(url: &str) {
    let _ = Command::new("xdg-open").arg(url).spawn();
}

pub fn reveal_folder(path: &str) {
    let _ = Command::new("xdg-open").arg(path).spawn();
}

/// Our own `which`: the first executable file named `stem` on $PATH.
pub fn find_on_path(stem: &str) -> Option<PathBuf> {
    let dirs = std::env::var_os("PATH")?;
    std::env::split_paths(&dirs)
        .map(|dir| dir.join(stem))
        .find(|p| {
            std::fs::metadata(p)
                .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
                .unwrap_or(false)
        })
}

// ── Cursor ────────────────────────────────────────────────────────────────────

/// Nothing polls the cursor here: the page reports it over the island, and the
/// input region decides click-through (see the top of this file).
pub const CURSOR_POLL: bool = false;

pub fn cursor_physical() -> Option<(f64, f64)> {
    None
}

pub fn left_button_down() -> bool {
    false
}

// ── Island window ─────────────────────────────────────────────────────────────

/// The few gtk-layer-shell calls we need, straight from the C library.
mod layer {
    use gtk::ffi::GtkWindow;
    use std::os::raw::{c_char, c_int};

    pub const LAYER_OVERLAY: c_int = 3;
    pub const EDGE_TOP: c_int = 2;
    pub const KEYBOARD_NONE: c_int = 0;
    pub const KEYBOARD_ON_DEMAND: c_int = 2;

    #[link(name = "gtk-layer-shell")]
    extern "C" {
        pub fn gtk_layer_is_supported() -> c_int;
        pub fn gtk_layer_init_for_window(window: *mut GtkWindow);
        pub fn gtk_layer_set_namespace(window: *mut GtkWindow, name_space: *const c_char);
        pub fn gtk_layer_set_layer(window: *mut GtkWindow, layer: c_int);
        pub fn gtk_layer_set_anchor(window: *mut GtkWindow, edge: c_int, anchor: c_int);
        pub fn gtk_layer_set_exclusive_zone(window: *mut GtkWindow, zone: c_int);
        pub fn gtk_layer_set_keyboard_mode(window: *mut GtkWindow, mode: c_int);
        pub fn gtk_layer_set_monitor(
            window: *mut GtkWindow,
            monitor: *mut gtk::gdk::ffi::GdkMonitor,
        );
    }
}

/// True once the island window is a layer-shell surface.
static LAYER_SURFACE: AtomicBool = AtomicBool::new(false);

/// The input region last asked for, re-applied whenever the window is mapped:
/// GTK resets it to the whole window on map. Until the page reports the island
/// shape it is empty, so nothing takes the mouse.
type Region = Option<(f64, f64, f64, f64)>;
static INPUT_REGION: Mutex<Region> = Mutex::new(Some((0.0, 0.0, 0.0, 0.0)));

fn gtk_window_ptr(win: &gtk::ApplicationWindow) -> *mut gtk::ffi::GtkWindow {
    let w: &gtk::Window = win.upcast_ref();
    w.to_glib_none().0
}

/// WebKitGTK has no competing drop target to remove.
pub fn unblock_webview_drops(_app: &AppHandle) {}

/// WebKitGTK sends the page no mouseleave when the pointer leaves the surface
/// (and Wayland has no global cursor either), so the island would never learn
/// the mouse is gone and never auto-close. GTK does get the compositor's leave:
/// report it as the cursor being far away, which is what the Windows poll says.
fn report_pointer_leaving(win: &WebviewWindow, gw: &gtk::ApplicationWindow) {
    gw.add_events(gtk::gdk::EventMask::LEAVE_NOTIFY_MASK);
    let win = win.clone();
    gw.connect_leave_notify_event(move |_, ev| {
        // Moving onto the webview inside the window is not leaving.
        if ev.detail() != gtk::gdk::NotifyType::Inferior {
            let _ = win.emit("cursor", crate::island::CursorPayload { x: -10_000.0, y: -10_000.0 });
        }
        gtk::glib::Propagation::Proceed
    });
}

/// Turns the island into an overlay surface on the top edge that never takes
/// the keyboard. Must run before the window is first shown: a layer surface
/// cannot be made out of a window the compositor already knows.
///
/// Without layer-shell (GNOME, X11, or COUCOU_LAYER_SHELL=0) the window stays
/// an ordinary always-on-top window that refuses focus; where it lands is then
/// up to the window manager.
pub fn make_non_activating(win: &WebviewWindow) {
    let Ok(gw) = win.gtk_window() else { return };
    report_pointer_leaving(win, &gw);
    // COUCOU_LAYER_SHELL=0 is the way out on a compositor where it misbehaves.
    let wanted = std::env::var("COUCOU_LAYER_SHELL").map(|v| v != "0").unwrap_or(true);
    let supported = unsafe { layer::gtk_layer_is_supported() } != 0;
    if !wanted || !supported || gw.is_realized() {
        let why = if !wanted {
            "COUCOU_LAYER_SHELL=0"
        } else if supported {
            "window already shown"
        } else {
            "compositor has no layer-shell"
        };
        crate::log::line(format!("island is a regular window ({why})"));
        gw.set_accept_focus(false);
        return;
    }
    // tao gives undecorated Wayland windows an empty titlebar to force
    // client-side decorations. A layer surface has none, and a client-decorated
    // GtkWindow recomputes its own input region (shadow margins included) on
    // every map, over ours.
    gw.set_titlebar(None::<&gtk::Widget>);
    let ptr = gtk_window_ptr(&gw);
    unsafe {
        layer::gtk_layer_init_for_window(ptr);
        layer::gtk_layer_set_namespace(ptr, c"coucou".as_ptr());
        layer::gtk_layer_set_layer(ptr, layer::LAYER_OVERLAY);
        // Top edge only: the compositor centres the surface horizontally.
        layer::gtk_layer_set_anchor(ptr, layer::EDGE_TOP, 1);
        // -1: sit right against the screen edge, over any top panel, the way
        // the Mac island sits in the notch.
        layer::gtk_layer_set_exclusive_zone(ptr, -1);
        layer::gtk_layer_set_keyboard_mode(ptr, layer::KEYBOARD_NONE);
    }
    // WebKitGTK in a freshly mapped layer surface never paints its first frame
    // (seen on COSMIC, and reproduced with a bare GTK window + WebKitGTK, no
    // Tauri involved): the surface stays empty. Unmapping and mapping it once,
    // right after the first map, gets it drawing for good.
    let remapped = std::cell::Cell::new(false);
    gw.connect_map_event(move |w, _| {
        apply_input_region(w, *INPUT_REGION.lock().unwrap());
        if !remapped.replace(true) {
            let w = w.clone();
            gtk::glib::idle_add_local_once(move || {
                w.hide();
                w.show_all();
                apply_input_region(&w, *INPUT_REGION.lock().unwrap());
            });
        }
        gtk::glib::Propagation::Proceed
    });
    LAYER_SURFACE.store(true, Ordering::Relaxed);
    crate::log::line("island is a layer-shell overlay");
}

/// Temporarily allow keyboard focus so a text field inside the island can be
/// typed in.
pub fn set_activating(win: &WebviewWindow, activating: bool) {
    let Ok(gw) = win.gtk_window() else { return };
    // The island is created `focusable: false` (tauri.linux.conf.json), so GTK
    // refuses focus until we say otherwise — on a layer surface too.
    gw.set_accept_focus(activating);
    if LAYER_SURFACE.load(Ordering::Relaxed) {
        let mode = if activating { layer::KEYBOARD_ON_DEMAND } else { layer::KEYBOARD_NONE };
        unsafe { layer::gtk_layer_set_keyboard_mode(gtk_window_ptr(&gw), mode) };
    }
}

/// Only this rectangle (window-logical pixels) takes the mouse; `None` means
/// the whole window does. Everything outside goes to the window underneath.
pub fn set_input_region(win: &WebviewWindow, rect: Region) {
    *INPUT_REGION.lock().unwrap() = rect;
    let Ok(gw) = win.gtk_window() else { return };
    apply_input_region(&gw, rect);
}

fn apply_input_region(gw: &impl IsA<gtk::Widget>, rect: Region) {
    match rect {
        None => gw.input_shape_combine_region(None),
        Some((x, y, w, h)) => {
            let Some(gdk_window) = gw.window() else { return };
            let region = gtk::cairo::Region::create_rectangle(&gtk::cairo::RectangleInt::new(
                x.floor() as i32,
                y.floor() as i32,
                w.ceil().max(0.0) as i32,
                h.ceil().max(0.0) as i32,
            ));
            gdk_window.input_shape_combine_region(&region, 0, 0);
        }
    }
}

// ── Terminal ──────────────────────────────────────────────────────────────────

/// `:1.42` or `org.kde.konsole-1234`: a D-Bus service name, nothing else.
fn is_dbus_service(s: &str) -> bool {
    !s.is_empty()
        && s.len() < 64
        && s.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b':' | b'.' | b'-' | b'_'))
}

/// `/Sessions/3` → `3`.
fn object_index<'a>(path: &'a str, kind: &str) -> Option<&'a str> {
    let n = path.strip_prefix(kind)?;
    (!n.is_empty() && n.len() < 10 && n.bytes().all(|b| b.is_ascii_digit())).then_some(n)
}

/// One `gdbus call` on the session bus; its stdout on success.
fn gdbus(dest: &str, path: &str, method: &str, args: &[&str]) -> Option<String> {
    let out = Command::new("gdbus")
        .args(["call", "--session", "--dest", dest, "--object-path", path, "--method", method])
        .args(args)
        .output()
        .ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Switches Konsole to the tab the session runs in and raises its window.
///
/// Wayland lets no app raise a window, but KWin runs scripts that can: the
/// window is picked by Konsole's process id and, when one Konsole owns several
/// windows, by the tab's title. Without KWin (or `gdbus`) the tab still
/// switches and false is returned only if Konsole itself did not answer.
pub fn focus_terminal(service: &str, session: &str, window: &str) -> bool {
    let (Some(id), Some(_)) =
        (object_index(session, "/Sessions/"), object_index(window, "/Windows/"))
    else {
        return false;
    };
    if !is_dbus_service(service) {
        return false;
    }
    let title = gdbus(service, session, "org.kde.konsole.Session.title", &["1"])
        .and_then(|t| t.trim().strip_prefix("('")?.strip_suffix("',)").map(str::to_string))
        .unwrap_or_default();
    if gdbus(service, window, "org.kde.konsole.Window.setCurrentSession", &[id]).is_none() {
        return false;
    }
    let pid = gdbus(
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus.GetConnectionUnixProcessID",
        &[service],
    )
    .and_then(|o| o.split_whitespace().nth(1)?.trim_end_matches(',').parse::<u32>().ok());
    if let Some(pid) = pid {
        raise_window_of(pid, &title);
    }
    true
}

/// Asks KWin to activate the window of process `pid` whose caption starts with
/// `title` (any window of the process if none does). The title goes in as a JSON
/// string, which is also a valid JS one.
fn raise_window_of(pid: u32, title: &str) {
    let script = format!(
        "const ws = workspace.windowList().filter(w => w.pid === {pid});\n\
         const w = ws.find(w => w.caption.startsWith({title})) || ws[0];\n\
         if (w) workspace.activeWindow = w;\n",
        title = serde_json::to_string(title).unwrap_or_else(|_| "\"\"".into()),
    );
    let path = std::env::temp_dir().join(format!("coucou-focus-{}.js", std::process::id()));
    if std::fs::write(&path, script).is_err() {
        return;
    }
    let name = format!("coucou-focus-{}", std::process::id());
    let path_str = path.to_string_lossy();
    if let Some(id) = gdbus(
        "org.kde.KWin",
        "/Scripting",
        "org.kde.kwin.Scripting.loadScript",
        &[&path_str, &name],
    )
    .and_then(|o| {
        o.split(|c: char| !c.is_ascii_digit()).find(|n| !n.is_empty()).map(str::to_string)
    }) {
        gdbus("org.kde.KWin", &format!("/Scripting/Script{id}"), "org.kde.kwin.Script.run", &[]);
        gdbus("org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting.unloadScript", &[&name]);
    }
    let _ = std::fs::remove_file(path);
}

// ── Displays ──────────────────────────────────────────────────────────────────

/// Top-left corner of the primary display, in pixels.
///
/// Wayland has no primary display and GDK just lists the first one, which is
/// rarely the one the user calls the main screen. Compositors do tell XWayland
/// though (KWin from its "primary" priority, Mutter likewise), so ask RandR.
/// `None` where there is no `xrandr` or no X server: the caller falls back to
/// GDK's order. Cached for a few seconds, the display poll asks twice a second.
// Known limit: positions are compared 1:1 with tao's, so a fractional-scale primary may not match.
pub fn primary_monitor_origin() -> Option<(i32, i32)> {
    use std::time::{Duration, Instant};
    static CACHE: Mutex<Option<(Instant, Option<(i32, i32)>)>> = Mutex::new(None);
    let mut cache = CACHE.lock().unwrap();
    if let Some((at, found)) = *cache {
        if at.elapsed() < Duration::from_secs(5) {
            return found;
        }
    }
    let found = Command::new("xrandr")
        .arg("--listmonitors")
        .stderr(Stdio::null())
        .output()
        .ok()
        .and_then(|o| parse_primary_origin(&String::from_utf8_lossy(&o.stdout)));
    *cache = Some((Instant::now(), found));
    found
}

/// `" 0: +*DP-1 2560/597x1440/336+1920+0  DP-1"` → `(1920, 0)`.
fn parse_primary_origin(listing: &str) -> Option<(i32, i32)> {
    let line = listing.lines().find(|l| l.contains("+*"))?;
    let mut at = line.split_whitespace().nth(2)?.split('+').skip(1);
    Some((at.next()?.parse().ok()?, at.next()?.parse().ok()?))
}

/// Index of the monitor the layer surface was last pinned to (none yet).
static PINNED_MONITOR: AtomicUsize = AtomicUsize::new(usize::MAX);

/// Pins the layer surface to the monitor with this index. tao lists monitors in
/// GDK's order, so the index means the same thing on both sides. Without this
/// the compositor picks the output, and it is rarely the one the user wants.
/// A no-op for an ordinary window, which `set_position` already places.
pub fn place_on_monitor(win: &WebviewWindow, index: usize) {
    if !LAYER_SURFACE.load(Ordering::Relaxed)
        || PINNED_MONITOR.swap(index, Ordering::Relaxed) == index
    {
        return;
    }
    let Ok(gw) = win.gtk_window() else { return };
    let Some(monitor) = gtk::gdk::Display::default().and_then(|d| d.monitor(index as i32)) else {
        return;
    };
    unsafe { layer::gtk_layer_set_monitor(gtk_window_ptr(&gw), monitor.to_glib_none().0) };
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Needs a running Konsole with this test started inside it:
    /// `cargo test --lib -- --ignored focus_own_konsole_tab`.
    #[test]
    #[ignore]
    fn focus_own_konsole_tab() {
        let get = |k| std::env::var(k).expect(k);
        assert!(focus_terminal(
            &get("KONSOLE_DBUS_SERVICE"),
            &get("KONSOLE_DBUS_SESSION"),
            &get("KONSOLE_DBUS_WINDOW"),
        ));
    }

    #[test]
    fn only_konsole_shaped_names_reach_the_bus() {
        assert!(is_dbus_service(":1.42") && is_dbus_service("org.kde.konsole-1234"));
        assert!(
            !is_dbus_service("")
                && !is_dbus_service("a b")
                && !is_dbus_service("x;y")
                && !is_dbus_service("--help ")
        );
        assert_eq!(object_index("/Sessions/3", "/Sessions/"), Some("3"));
        assert_eq!(object_index("/Windows/12", "/Windows/"), Some("12"));
        assert_eq!(object_index("/Sessions/3/x", "/Sessions/"), None);
        assert_eq!(object_index("/Windows/1", "/Sessions/"), None);
        assert_eq!(object_index("/Sessions/", "/Sessions/"), None);
    }

    #[test]
    fn the_primary_display_is_the_one_marked_with_a_star() {
        let out = "Monitors: 2\n 0: +*DP-1 2560/597x1440/336+1920+0  DP-1\n 1: +HDMI-A-1 1920/521x1080/293+0+360  HDMI-A-1\n";
        assert_eq!(parse_primary_origin(out), Some((1920, 0)));
        assert_eq!(parse_primary_origin(" 0: +DP-1 1920/1x1080/1+0+0  DP-1\n"), None);
        let left = " 0: +*DP-2 1920/1x1080/1+-1920+0  DP-2\n";
        assert_eq!(parse_primary_origin(left), Some((-1920, 0)));
    }

    #[test]
    fn only_a_private_directory_of_ours_can_hold_the_relay_socket() {
        let base = std::env::temp_dir().join(format!("coucou-rt-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let dir = base.join("runtime");
        std::fs::create_dir_all(&dir).unwrap();
        let set = |mode| std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(mode)).unwrap();

        set(0o700);
        assert!(is_private_dir(&dir));

        // Readable or reachable by group or others: no.
        for open in [0o750, 0o705, 0o755, 0o777, 0o1777] {
            set(open);
            assert!(!is_private_dir(&dir), "{open:o} must be refused");
        }

        // A symlink to a private directory: no, the link itself is what we got.
        set(0o700);
        let link = base.join("link");
        std::os::unix::fs::symlink(&dir, &link).unwrap();
        assert!(!is_private_dir(&link));

        // Missing: no.
        assert!(!is_private_dir(&base.join("missing")));

        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn private_dirs_are_closed_to_everyone_else() {
        use std::os::unix::fs::MetadataExt;
        let dir = std::env::temp_dir().join(format!("coucou-priv-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755)).unwrap();
        ensure_private_dir(&dir).unwrap();
        assert_eq!(std::fs::metadata(&dir).unwrap().mode() & 0o777, 0o700);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
