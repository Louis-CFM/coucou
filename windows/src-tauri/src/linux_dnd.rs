// Files dropped on the island under KWin.
//
// KWin hands a Wayland drag's data to an X11 client only while an X11 window is
// the active one (src/xwayland/selection.cpp), and during a drag it activates
// the window under the pointer only if that window accepts focus. The island
// never takes focus, so every drop arrived with no files and was refused.
//
// So when a drag first touches the island, it starts accepting focus and its
// input region shrinks to one corner pixel for a moment: KWin, which only asks
// for focus when the drag target changes, picks the island again and this time
// activates it. Focus is refused again shortly after the drag leaves, unless a
// text field in the island asked for it in the meantime.

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use gtk::glib;
use gtk::prelude::*;
use tauri::{AppHandle, WebviewWindow};

use crate::island::{self, PollGate};

/// While set, the input region is a single corner pixel so KWin re-picks the drop target.
pub static REPICK: AtomicBool = AtomicBool::new(false);
/// Set while a text field in the island holds keyboard focus.
pub static TEXT_FOCUS: AtomicBool = AtomicBool::new(false);

const REPICK_MS: u64 = 80;
const RELEASE_MS: u64 = 1500;

pub fn attach(app: &AppHandle, win: &WebviewWindow, gate: Arc<PollGate>) {
    let Ok(gtk_win) = win.gtk_window() else { return };
    let Some(webview) = island::island_webview(win) else {
        crate::log::line("no WebKitWebView found — dropped files will not arrive");
        return;
    };
    let release: Rc<RefCell<Option<glib::SourceId>>> = Rc::new(RefCell::new(None));

    {
        let gtk_win = gtk_win.clone();
        let app = app.clone();
        let release = release.clone();
        webview.connect_drag_motion(move |_, _, _, _, _| {
            if let Some(id) = release.borrow_mut().take() {
                id.remove();
            }
            if !gtk_win.accepts_focus() {
                gtk_win.set_accept_focus(true);
                REPICK.store(true, Ordering::Relaxed);
                island::update_input_region(&app, &gate);
                let app = app.clone();
                let gate = gate.clone();
                glib::timeout_add_local_once(Duration::from_millis(REPICK_MS), move || {
                    REPICK.store(false, Ordering::Relaxed);
                    island::update_input_region(&app, &gate);
                });
            }
            false
        });
    }

    webview.connect_drag_leave(move |_, _, _| {
        if let Some(id) = release.borrow_mut().take() {
            id.remove();
        }
        let gtk_win = gtk_win.clone();
        let slot = release.clone();
        let id = glib::timeout_add_local_once(Duration::from_millis(RELEASE_MS), move || {
            slot.borrow_mut().take();
            if !TEXT_FOCUS.load(Ordering::Relaxed) {
                gtk_win.set_accept_focus(false);
            }
        });
        *release.borrow_mut() = Some(id);
    });
}
