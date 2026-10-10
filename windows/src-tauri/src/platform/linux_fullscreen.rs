// The island steps aside for a fullscreen window.
//
// Without layer-shell the island is a dock window, and a dock stays above a
// fullscreen video or game: a pill floating over the picture. So while the
// window on top at the island's spot is fullscreen, the island is hidden, and
// it comes back when that window leaves fullscreen, is covered by another
// window, is hidden, or is on another workspace. Focus does not matter: a video
// that is fullscreen on one screen stays fullscreen while you work on another.
// (X11, or XWayland for X11 clients: a native Wayland client's fullscreen
// state is not visible from here. A layer-shell compositor puts the island in
// its own layer and is left alone.) COUCOU_FULLSCREEN_HIDE=0 keeps the island
// showing over fullscreen windows.

use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use tauri::{AppHandle, Manager};
use x11rb::connection::Connection;
use x11rb::protocol::xproto::{AtomEnum, ChangeWindowAttributesAux, ConnectionExt, EventMask, Window};
use x11rb::protocol::Event;
use x11rb::rust_connection::RustConnection;

type Fallible<T> = Result<T, Box<dyn std::error::Error>>;

/// Events are gathered for this long before the picture is looked at again, so
/// dragging a window does not make a dozen looks a second.
const SETTLE: Duration = Duration::from_millis(60);

/// Starts watching, once, from the thread that sets the island up.
pub fn watch_fullscreen(app: AppHandle) {
    if std::env::var("COUCOU_FULLSCREEN_HIDE").is_ok_and(|v| v == "0") {
        return;
    }
    if super::layer_surface_in_use() || std::env::var_os("DISPLAY").is_none() {
        return;
    }
    let spawned = std::thread::Builder::new().name("coucou-fullscreen".into()).spawn(move || {
        if let Err(err) = run(&app) {
            crate::log::line(format!("fullscreen watch: {err}"));
        }
    });
    if let Err(err) = spawned {
        crate::log::line(format!("fullscreen watch: no thread: {err}"));
    }
}

struct Atoms {
    stacking: u32,
    active: u32,
    current_desktop: u32,
    wm_desktop: u32,
    state: u32,
    window_type: u32,
    fullscreen: u32,
    hidden: u32,
    /// Window types that are never "the window on top": panels, menus, bubbles.
    skipped_types: Vec<u32>,
}

fn atom(conn: &RustConnection, name: &str) -> Fallible<u32> {
    Ok(conn.intern_atom(false, name.as_bytes())?.reply()?.atom)
}

fn atoms(conn: &RustConnection) -> Fallible<Atoms> {
    let mut skipped_types = Vec::new();
    for name in [
        "DOCK", "DESKTOP", "NOTIFICATION", "TOOLTIP", "DND", "DROPDOWN_MENU", "POPUP_MENU", "COMBO",
    ] {
        skipped_types.push(atom(conn, &format!("_NET_WM_WINDOW_TYPE_{name}"))?);
    }
    Ok(Atoms {
        stacking: atom(conn, "_NET_CLIENT_LIST_STACKING")?,
        active: atom(conn, "_NET_ACTIVE_WINDOW")?,
        current_desktop: atom(conn, "_NET_CURRENT_DESKTOP")?,
        wm_desktop: atom(conn, "_NET_WM_DESKTOP")?,
        state: atom(conn, "_NET_WM_STATE")?,
        window_type: atom(conn, "_NET_WM_WINDOW_TYPE")?,
        fullscreen: atom(conn, "_NET_WM_STATE_FULLSCREEN")?,
        hidden: atom(conn, "_NET_WM_STATE_HIDDEN")?,
        skipped_types,
    })
}

fn values(conn: &RustConnection, window: Window, prop: u32, kind: AtomEnum, max: u32) -> Vec<u32> {
    conn.get_property(false, window, prop, kind, 0, max)
        .ok()
        .and_then(|c| c.reply().ok())
        .and_then(|r| r.value32().map(|v| v.collect()))
        .unwrap_or_default()
}

/// Whether the window on top at (`x`, `y`) is fullscreen. Looked at top to
/// bottom: the first window that is showing there decides.
fn fullscreen_on_top(conn: &RustConnection, root: Window, a: &Atoms, clients: &[Window], x: i32, y: i32) -> bool {
    let desktop = values(conn, root, a.current_desktop, AtomEnum::CARDINAL, 1).first().copied();
    for &window in clients.iter().rev() {
        if values(conn, window, a.window_type, AtomEnum::ATOM, 8).iter().any(|t| a.skipped_types.contains(t)) {
            continue;
        }
        let state = values(conn, window, a.state, AtomEnum::ATOM, 64);
        if state.contains(&a.hidden) {
            continue;
        }
        // On another workspace (0xFFFFFFFF: on all of them).
        if let (Some(on), Some(now)) = (values(conn, window, a.wm_desktop, AtomEnum::CARDINAL, 1).first().copied(), desktop) {
            if on != u32::MAX && on != now {
                continue;
            }
        }
        let (Some(geo), Some(origin)) = (
            conn.get_geometry(window).ok().and_then(|c| c.reply().ok()),
            conn.translate_coordinates(window, root, 0, 0).ok().and_then(|c| c.reply().ok()),
        ) else {
            continue;
        };
        let (wx, wy) = (origin.dst_x as i32, origin.dst_y as i32);
        if x >= wx && x < wx + geo.width as i32 && y >= wy && y < wy + geo.height as i32 {
            return state.contains(&a.fullscreen);
        }
    }
    false
}

fn run(app: &AppHandle) -> Fallible<()> {
    let (conn, screen) = x11rb::connect(None)?;
    let root = conn.setup().roots.get(screen).ok_or("no screen")?.root;
    let a = atoms(&conn)?;

    let watch = |window: Window, mask: EventMask| {
        let _ = conn.change_window_attributes(window, &ChangeWindowAttributesAux::new().event_mask(mask));
    };
    watch(root, EventMask::PROPERTY_CHANGE);
    let _ = conn.flush();

    let hidden = AtomicBool::new(false);
    let mut watched: HashSet<Window> = HashSet::new();
    let look = |watched: &mut HashSet<Window>| {
        let clients = values(&conn, root, a.stacking, AtomEnum::WINDOW, 4096);
        // Every window is listened to: its fullscreen state, and where it is.
        for &w in &clients {
            if watched.insert(w) {
                watch(w, EventMask::PROPERTY_CHANGE | EventMask::STRUCTURE_NOTIFY);
            }
        }
        let _ = conn.flush();
        watched.retain(|w| clients.contains(w));

        let Some(island) = app.get_webview_window(crate::island::WINDOW_LABEL) else { return };
        // Where the island is: the top centre of its window.
        let covered = match (island.outer_position(), island.outer_size()) {
            (Ok(p), Ok(s)) => fullscreen_on_top(&conn, root, &a, &clients, p.x + s.width as i32 / 2, p.y + 2),
            _ => false,
        };
        if covered && !hidden.swap(true, Ordering::Relaxed) {
            let _ = island.hide();
        } else if !covered && hidden.swap(false, Ordering::Relaxed) {
            let _ = island.show();
        }
    };

    look(&mut watched);
    loop {
        let mut relevant = false;
        let mut consider = |event: Event| match event {
            Event::PropertyNotify(e) => {
                relevant |= [a.stacking, a.active, a.current_desktop, a.wm_desktop, a.state].contains(&e.atom)
            }
            Event::ConfigureNotify(_) | Event::MapNotify(_) | Event::UnmapNotify(_) | Event::DestroyNotify(_) => {
                relevant = true
            }
            _ => {}
        };
        consider(conn.wait_for_event()?);
        // Let a burst of events settle, then look once.
        std::thread::sleep(SETTLE);
        while let Some(event) = conn.poll_for_event()? {
            consider(event);
        }
        if relevant {
            look(&mut watched);
        }
    }
}
