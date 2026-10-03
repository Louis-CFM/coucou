// Linux: XDG directories for files, xdg-open for links and folders, and
// gtk-layer-shell for the island window.
//
// Wayland gives an app no global cursor position and no say over where its
// window goes, so the island works differently from Windows:
//   * it is a layer-shell surface anchored to the top edge, above everything,
//     on compositors that support it (COSMIC, KDE, wlroots — not GNOME);
//   * where layer-shell is missing, prepare_backend drops to X11 (XWayland
//     included) and avoid_panels makes the island a dock, because that is the
//     only combination where the window manager puts it at the top edge;
//   * click-through is the window's input region, set to the island shape, so
//     the compositor itself sends every other click to whatever is underneath;
//   * the cursor comes from the page's own mouse events, which only fire over
//     the island — Mochi's eyes follow the pointer there, not across the screen.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

use gtk::glib::translate::ToGlibPtr;
use gtk::prelude::*;
use tauri::{AppHandle, WebviewWindow};

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

/// Environment the webview must inherit, set before any thread or process
/// starts.
///
/// Inside an AppImage, WebKit uses the GStreamer bundled with it, and GStreamer
/// keeps its plugin registry in ~/.cache/gstreamer-1.0 by default — the same
/// file the system's GStreamer uses. The AppImage is mounted somewhere new on
/// every launch, so each launch would rewrite the system's registry with
/// plugin paths that vanish once Coucou quits. Give ours its own file.
pub fn prepare_environment() {
    if std::env::var_os("APPIMAGE").is_none() || std::env::var_os("GST_REGISTRY").is_some() {
        prepare_backend();
        return;
    }
    let cache = xdg("XDG_CACHE_HOME", ".cache").join("coucou");
    if std::fs::create_dir_all(&cache).is_ok() {
        std::env::set_var("GST_REGISTRY", cache.join("gstreamer-registry.bin"));
    }
    prepare_backend();
}

/// Picks the GDK backend before GTK is initialised, so the island lands where it
/// was asked to land.
///
/// On Wayland an app has no say over where its window goes, and there is no
/// layer-shell on GNOME, so the island became an ordinary always-on-top window
/// and the compositor centred it — vertically in the middle of the screen, and
/// kept re-placing it on every configure. layer-shell is the reason for the
/// top-edge placement, so it is asked for first:
///
///   * layer-shell available (KDE, wlroots/COSMIC/Sway/Hyprland): Wayland, and
///     the compositor anchors the surface to the top edge;
///   * no layer-shell but an X server reachable (GNOME, or any X11 session):
///     X11, where the window manager does honour `set_position`, so the
///     explicit placement in island::apply_geometry is what counts;
///   * neither: leave GDK to decide, rather than lock ourselves out of a
///     working display.
///
/// A `GDK_BACKEND` already in the environment is *not* taken as the user's
/// choice here: GNOME sessions export `GDK_BACKEND=wayland` for every app they
/// start, and honouring it is exactly what left the island in the middle.
/// `COUCOU_GDK_BACKEND` is the per-app override, and `COUCOU_LAYER_SHELL=0`
/// leaves the backend alone entirely.
fn prepare_backend() {
    if std::env::var("COUCOU_LAYER_SHELL").as_deref() == Ok("0") {
        return;
    }
    if let Ok(forced) = std::env::var("COUCOU_GDK_BACKEND") {
        if !forced.is_empty() {
            crate::log::line(format!("backend: {forced} (COUCOU_GDK_BACKEND)"));
            std::env::set_var("GDK_BACKEND", forced);
        }
        return;
    }
    if unsafe { layer::gtk_layer_is_supported() } != 0 {
        std::env::set_var("GDK_BACKEND", "wayland");
        crate::log::line("backend: wayland (layer-shell overlay)");
    } else if has_x_display() {
        // Overrides the session's GDK_BACKEND=wayland: the window manager moves
        // the island for us, where a Wayland compositor would not.
        std::env::set_var("GDK_BACKEND", "x11");
        crate::log::line("backend: x11 (no layer-shell; XWayland keeps placement)");
    } else {
        crate::log::line("backend: default (no layer-shell, no X display)");
    }
}

/// True when this process can reach an X server: `DISPLAY` set, and either
/// X11 or XWayland underneath it. GDK picks the Wayland backend whenever
/// `WAYLAND_DISPLAY` is present, which on a GNOME session is a compositor that
/// will neither give us a layer surface nor let us move the window.
fn has_x_display() -> bool {
    if !std::env::var_os("DISPLAY").is_some_and(|d| !d.is_empty()) {
        return false;
    }
    // An X server reachable through XWayland still speaks X11 to us, which is
    // all the position calls need.
    !x11_socket().is_empty() && std::path::Path::new(&x11_socket()).exists()
}

/// `DISPLAY` as a socket path: `:0` → `/tmp/.X11-unix/X0`. Empty when the value
/// is not the simple host:socket form this app can use.
fn x11_socket() -> String {
    x11_socket_for(&std::env::var("DISPLAY").unwrap_or_default())
}

fn x11_socket_for(display: &str) -> String {
    let Some((host, rest)) = display.rsplit_once(':') else {
        return String::new();
    };
    let number = rest.split('.').next().unwrap_or_default();
    if number.is_empty() || !number.bytes().all(|b| b.is_ascii_digit()) {
        return String::new();
    }
    if !host.is_empty() && host != "unix" {
        // A remote or TCP display: no local socket to stat.
        return String::new();
    }
    format!("/tmp/.X11-unix/X{number}")
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

/// How many logical pixels of the screen's top edge the panels cover, so the
/// island can sit just under them instead of over them.
///
/// On GNOME the top edge holds the clock and the date. An island drawn over it
/// hides both, so it goes below the bar rather than on it.
///
/// The number comes from the window manager's own work area (the `_NET_WORKAREA`
/// property, surfaced by GDK as `Monitor::workarea`): the rectangle left over
/// once the panels are subtracted. Asking beats hardcoding a figure that is
/// right on one machine and wrong on the next — 32 is GNOME's default, but it
/// follows whatever the user configured, and it is 0 on a desktop with no panel.
///
/// Always 0 on a layer surface: there the compositor anchors the island to the
/// top edge itself, and an offset would defeat that.
///
/// The caller wants physical pixels; this is logical, so it is scaled by the
/// caller rather than guessing at it here.
pub fn top_panel_height(win: &WebviewWindow) -> f64 {
    if LAYER_SURFACE.load(Ordering::Relaxed) {
        return 0.0;
    }
    let Ok(gw) = win.gtk_window() else { return 0.0 };
    let display = gw.display();
    // The monitor the island actually lives on, not just the primary one.
    // `window()` is the GdkWindow behind the GtkWindow; None before the window
    // is realized, in which case the primary monitor is the right answer.
    let monitor = gw
        .window()
        .and_then(|gdk_window| display.monitor_at_window(&gdk_window))
        .or_else(|| display.primary_monitor());
    let Some(monitor) = monitor else { return 0.0 };
    let workarea = monitor.workarea();
    // The work area starts where the panel ends. Negative would mean a bar on
    // another edge only; clamp so a strange value can never push it off-screen.
    workarea.y().max(0) as f64
}

/// Asks the window manager to keep the island out of the panels, so the
/// placement in `island::apply_geometry` is the placement we get.
///
/// Only meaningful on the X11 path; a layer surface is anchored to the edge by
/// the compositor and has no work area at all. Safe to call on every
/// `apply_geometry`, which is why the set_resizable dance next to it is too.
///
/// Deliberately *not* a dock. A dock is the one type placed against the screen
/// edge rather than inside the work area, which was how the island used to reach
/// y = 0 — on top of GNOME's clock and date. It now sits under the panel
/// instead, so the hint buys nothing and costs something: window managers that
/// honour dock struts (XFCE, MATE, Cinnamon, i3, openbox) reserve vertical space
/// for a dock window, which would shrink the usable desktop by the height of the
/// island. Not a trade worth making for an empty win.
pub fn avoid_panels(_win: &WebviewWindow) {}

/// Turns the island into an overlay surface on the top edge that never takes
/// the keyboard. Must run before the window is first shown: a layer surface
/// cannot be made out of a window the compositor already knows.
///
/// Without layer-shell (GNOME, X11, or COUCOU_LAYER_SHELL=0) the window stays
/// an ordinary always-on-top window that refuses focus; where it lands is then
/// up to the window manager.
pub fn make_non_activating(win: &WebviewWindow) {
    let Ok(gw) = win.gtk_window() else { return };
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
        // No dock hint here: see `avoid_panels`. The island is placed under the
        // panel by hand, and a dock window would make window managers that honour
        // struts reserve space for it.
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

#[cfg(test)]
mod tests {
    use super::*;

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

    #[test]
    fn a_display_becomes_the_socket_we_can_stat() {
        // The shapes a session actually hands us, Wayland ones included.
        assert_eq!(x11_socket_for(":0"), "/tmp/.X11-unix/X0");
        assert_eq!(x11_socket_for(":0.0"), "/tmp/.X11-unix/X0");
        assert_eq!(x11_socket_for(":1"), "/tmp/.X11-unix/X1");
        assert_eq!(x11_socket_for("unix:0"), "/tmp/.X11-unix/X0");
    }

    #[test]
    fn a_display_we_cannot_reach_locally_is_never_claimed() {
        // Picking x11 for a display we cannot connect to would give the app no
        // window at all, which is worse than the misplacement we are fixing.
        for display in ["", ":", "wayland-0", "hostname:0", ":abc", ":-1", ":0:1"] {
            assert_eq!(x11_socket_for(display), "", "{display:?} must not resolve");
        }
    }
}
