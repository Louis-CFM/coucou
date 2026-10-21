//! Out of the way of fullscreen video.
//!
//! While a fullscreen app runs — a video, a game, a presentation — the island,
//! Mochi on the desktop and the resting dictation pill hide, and come back as they were
//! when it ends. A dictation the user starts still shows its pill: they asked
//! for it. Windows says when something is fullscreen
//! (SHQueryUserNotificationState); one cheap call every second and a half.

use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use tauri::{AppHandle, Manager};

/// A fullscreen app is in front.
static FULLSCREEN: AtomicBool = AtomicBool::new(false);
/// Mochi was on the desktop when fullscreen began, so he comes back after.
static MOCHI_WAS_SHOWN: AtomicBool = AtomicBool::new(false);

const EVERY: Duration = Duration::from_millis(1500);

/// Whether a fullscreen app is in front, as last seen.
pub fn active() -> bool {
    FULLSCREEN.load(Ordering::Relaxed)
}

/// What Windows' notification state means here: someone is watching or
/// presenting something fullscreen.
#[cfg_attr(not(windows), allow(dead_code))]
fn is_fullscreen_state(state: i32) -> bool {
    // QUNS_BUSY (2), QUNS_RUNNING_D3D_FULL_SCREEN (3), QUNS_PRESENTATION_MODE (4).
    matches!(state, 2 | 3 | 4)
}

#[cfg(windows)]
fn query() -> bool {
    use windows::Win32::UI::Shell::SHQueryUserNotificationState;
    unsafe { SHQueryUserNotificationState() }.map(|s| is_fullscreen_state(s.0)).unwrap_or(false)
}

#[cfg(not(windows))]
fn query() -> bool {
    false
}

pub fn spawn(app: AppHandle) {
    std::thread::spawn(move || loop {
        std::thread::sleep(EVERY);
        let now = query();
        if now != FULLSCREEN.swap(now, Ordering::Relaxed) {
            crate::log::line(format!("fullscreen: {}", if now { "on, hiding" } else { "off, back" }));
            apply(&app, now);
        }
    });
}

fn apply(app: &AppHandle, fullscreen: bool) {
    let handle = app.clone();
    let _ = app.run_on_main_thread(move || {
        if let Some(island) = handle.get_webview_window(crate::island::WINDOW_LABEL) {
            if fullscreen {
                let _ = island.hide();
            } else {
                let _ = island.show();
                let _ = island.set_always_on_top(true);
            }
        }
        if let Some(mochi) = handle.get_webview_window(crate::desktop::LABEL) {
            if fullscreen {
                MOCHI_WAS_SHOWN.store(mochi.is_visible().unwrap_or(false), Ordering::Relaxed);
                let _ = mochi.hide();
            } else if MOCHI_WAS_SHOWN.swap(false, Ordering::Relaxed) {
                let _ = mochi.show();
            }
        }
    });
    // The pill decides for itself: it re-reads `active()` when it updates.
    crate::flow::pill::update(app, |_| {});
}

#[cfg(test)]
mod tests {
    use super::is_fullscreen_state;

    #[test]
    fn only_fullscreen_states_hide() {
        // QUNS_NOT_PRESENT, QUNS_ACCEPTS_NOTIFICATIONS, QUNS_QUIET_TIME, QUNS_APP.
        for state in [1, 5, 6, 7] {
            assert!(!is_fullscreen_state(state), "{state}");
        }
        for state in [2, 3, 4] {
            assert!(is_fullscreen_state(state), "{state}");
        }
    }
}
