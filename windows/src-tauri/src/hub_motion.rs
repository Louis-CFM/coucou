// The Coucou window opens and closes with Windows 11's own motion:
// it rises out of its taskbar button and folds back down into it, the system's
// minimise / restore animation. Nothing is drawn by the page, and Windows' own
// "Animation effects" setting turns it off like for any other window.
//
// Closing still ends with the window hidden, as before: minimised first, so
// the fold plays, then hidden once it has, which takes the button off the
// taskbar. Opening reverses it: shown minimised, which puts the button back,
// then restored from there. Elsewhere (Linux), plain hide and show.

use tauri::WebviewWindow;

/// Shows the window, focused.
pub fn open(win: &WebviewWindow) {
    #[cfg(windows)]
    if native::open(win) {
        return;
    }
    let _ = win.unminimize();
    let _ = win.show();
    let _ = win.set_focus();
}

/// Hides the window.
pub fn close(win: &WebviewWindow) {
    #[cfg(windows)]
    if native::close(win) {
        return;
    }
    let _ = win.hide();
}

#[cfg(windows)]
mod native {
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::Duration;

    use tauri::WebviewWindow;
    use windows::Win32::Foundation::HWND;
    use windows::Win32::UI::WindowsAndMessaging::{
        IsIconic, IsWindowVisible, ShowWindow, SW_HIDE, SW_MINIMIZE, SW_RESTORE, SW_SHOWMINNOACTIVE,
    };

    /// Lets the taskbar add the button before the window rises from it: restored
    /// at once, Windows has no button to start the motion from.
    const BUTTON_MS: u64 = 60;
    /// Past the fold (about 250 ms on Windows 11) before the window is hidden.
    const FOLD_MS: u64 = 400;

    /// Bumped by every open and close: a hide still waiting for its fold to end
    /// is dropped when the window was opened again in the meantime.
    static MOTION: AtomicU64 = AtomicU64::new(0);

    fn raw_hwnd(win: &WebviewWindow) -> Option<isize> {
        let raw = win.hwnd().ok()?.0 as isize;
        (raw != 0).then_some(raw)
    }

    fn hwnd(raw: isize) -> HWND {
        HWND(raw as *mut _)
    }

    pub fn open(win: &WebviewWindow) -> bool {
        let Some(raw) = raw_hwnd(win) else { return false };
        let motion = MOTION.fetch_add(1, Ordering::SeqCst) + 1;
        let hidden = unsafe { !IsWindowVisible(hwnd(raw)).as_bool() };
        if !hidden && unsafe { !IsIconic(hwnd(raw)).as_bool() } {
            let _ = win.set_focus();
            return true;
        }
        if hidden {
            // Back on the taskbar, folded: the button the window rises from.
            unsafe {
                let _ = ShowWindow(hwnd(raw), SW_SHOWMINNOACTIVE);
            }
        }
        let win = win.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(if hidden { BUTTON_MS } else { 0 }));
            let this = win.clone();
            let _ = win.run_on_main_thread(move || {
                if MOTION.load(Ordering::SeqCst) != motion {
                    return;
                }
                unsafe {
                    let _ = ShowWindow(hwnd(raw), SW_RESTORE);
                }
                let _ = this.set_focus();
            });
        });
        true
    }

    pub fn close(win: &WebviewWindow) -> bool {
        let Some(raw) = raw_hwnd(win) else { return false };
        let motion = MOTION.fetch_add(1, Ordering::SeqCst) + 1;
        unsafe {
            let _ = ShowWindow(hwnd(raw), SW_MINIMIZE);
        }
        let win = win.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(FOLD_MS));
            let _ = win.run_on_main_thread(move || {
                if MOTION.load(Ordering::SeqCst) != motion {
                    return;
                }
                unsafe {
                    if IsIconic(hwnd(raw)).as_bool() {
                        let _ = ShowWindow(hwnd(raw), SW_HIDE);
                    }
                }
            });
        });
        true
    }
}
