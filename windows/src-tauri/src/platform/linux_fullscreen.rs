// The island steps aside for a fullscreen window.
//
// Without layer-shell the island is a dock window, and a dock stays above a
// fullscreen video or game: a pill floating over the picture. So while the
// focused window is fullscreen on the island's own display, the island is
// hidden, and it comes back when that window leaves fullscreen or loses focus.
// (X11, or XWayland for X11 clients: a native Wayland client's fullscreen
// state is not visible from here. A layer-shell compositor puts the island in
// its own layer and is left alone.) COUCOU_FULLSCREEN_HIDE=0 keeps the island
// showing over fullscreen windows.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use tauri::{AppHandle, Manager};
use x11rb::connection::Connection;
use x11rb::protocol::xproto::{AtomEnum, ChangeWindowAttributesAux, ConnectionExt, EventMask, Window};
use x11rb::protocol::Event;
use x11rb::rust_connection::RustConnection;

type Fallible<T> = Result<T, Box<dyn std::error::Error>>;

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
    active: u32,
    state: u32,
    fullscreen: u32,
}

fn atom(conn: &RustConnection, name: &str) -> Fallible<u32> {
    Ok(conn.intern_atom(false, name.as_bytes())?.reply()?.atom)
}

fn active_window(conn: &RustConnection, root: Window, atoms: &Atoms) -> Option<Window> {
    let reply = conn.get_property(false, root, atoms.active, AtomEnum::WINDOW, 0, 1).ok()?.reply().ok()?;
    let window = reply.value32()?.next().filter(|w| *w != 0);
    window
}

/// Whether `window` is fullscreen and covers the point (`x`, `y`) of the screen.
fn fullscreen_over(conn: &RustConnection, root: Window, atoms: &Atoms, window: Window, x: i32, y: i32) -> bool {
    let Some(reply) = conn
        .get_property(false, window, atoms.state, AtomEnum::ATOM, 0, 64)
        .ok()
        .and_then(|c| c.reply().ok())
    else {
        return false;
    };
    if !reply.value32().is_some_and(|mut v| v.any(|a| a == atoms.fullscreen)) {
        return false;
    }
    let (Some(geo), Some(origin)) = (
        conn.get_geometry(window).ok().and_then(|c| c.reply().ok()),
        conn.translate_coordinates(window, root, 0, 0).ok().and_then(|c| c.reply().ok()),
    ) else {
        return false;
    };
    let (wx, wy) = (origin.dst_x as i32, origin.dst_y as i32);
    x >= wx && x < wx + geo.width as i32 && y >= wy && y < wy + geo.height as i32
}

fn run(app: &AppHandle) -> Fallible<()> {
    let (conn, screen) = x11rb::connect(None)?;
    let root = conn.setup().roots.get(screen).ok_or("no screen")?.root;
    let atoms = Atoms {
        active: atom(&conn, "_NET_ACTIVE_WINDOW")?,
        state: atom(&conn, "_NET_WM_STATE")?,
        fullscreen: atom(&conn, "_NET_WM_STATE_FULLSCREEN")?,
    };
    let watch = |window: Window| {
        let aux = ChangeWindowAttributesAux::new().event_mask(EventMask::PROPERTY_CHANGE);
        let _ = conn.change_window_attributes(window, &aux);
        let _ = conn.flush();
    };
    watch(root);

    let hidden = Arc::new(AtomicBool::new(false));
    let mut watched: Option<Window> = None;
    let evaluate = |watched: &mut Option<Window>| {
        let active = active_window(&conn, root, &atoms);
        if active != *watched {
            if let Some(window) = active {
                watch(window);
            }
            *watched = active;
        }
        let Some(island) = app.get_webview_window(crate::island::WINDOW_LABEL) else { return };
        // Where the island is: the top centre of its window.
        let spot = match (island.outer_position(), island.outer_size()) {
            (Ok(p), Ok(s)) => Some((p.x + s.width as i32 / 2, p.y + 2)),
            _ => None,
        };
        let covered = match (active, spot) {
            (Some(window), Some((x, y))) => fullscreen_over(&conn, root, &atoms, window, x, y),
            _ => false,
        };
        if covered && !hidden.swap(true, Ordering::Relaxed) {
            let _ = island.hide();
        } else if !covered && hidden.swap(false, Ordering::Relaxed) {
            let _ = island.show();
        }
    };

    evaluate(&mut watched);
    loop {
        match conn.wait_for_event()? {
            Event::PropertyNotify(e) if e.atom == atoms.active || e.atom == atoms.state => evaluate(&mut watched),
            _ => {}
        }
    }
}
