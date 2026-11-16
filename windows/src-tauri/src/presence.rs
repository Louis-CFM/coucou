// System User Presence Monitor (#1055 & Mochi Companion).
// Uses Windows Win32 GetLastInputInfo to detect when the user steps away from keyboard/mouse
// (10-15+ minutes) and returns, notifying the webview so Mochi greets them warmly in the small notch.

use serde::{Deserialize, Serialize};
use std::time::Instant;
use tauri::{AppHandle, Emitter};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PresenceEvent {
    pub status: String, // "away" | "returned"
    pub away_minutes: u64,
    pub user_name: Option<String>,
}

#[cfg(windows)]
pub fn system_idle_ms() -> u64 {
    use ::windows::Win32::System::SystemInformation::GetTickCount;
    use ::windows::Win32::UI::Input::KeyboardAndMouse::{GetLastInputInfo, LASTINPUTINFO};

    let mut lii = LASTINPUTINFO {
        cbSize: std::mem::size_of::<LASTINPUTINFO>() as u32,
        dwTime: 0,
    };
    if unsafe { GetLastInputInfo(&mut lii).as_bool() } {
        let now = unsafe { GetTickCount() };
        now.saturating_sub(lii.dwTime) as u64
    } else {
        0
    }
}

#[cfg(not(windows))]
pub fn system_idle_ms() -> u64 {
    0
}

/// Dynamic absence threshold: reads from Settings.absence_interval (default 180s = 3 minutes).
fn away_threshold_ms() -> u64 {
    let secs = crate::settings::load().absence_interval;
    if secs >= 60.0 {
        (secs * 1000.0) as u64
    } else {
        180 * 1000 // 3 minutes baseline fallback
    }
}

pub fn start(app: &AppHandle) {
    let handle = app.clone();
    std::thread::Builder::new()
        .name("coucou-presence".into())
        .spawn(move || {
            run_presence_loop(handle);
        })
        .ok();
}

fn run_presence_loop(app: AppHandle) {
    let mut is_away = false;
    let mut away_start = Instant::now();

    loop {
        std::thread::sleep(std::time::Duration::from_millis(2000));

        let idle_ms = system_idle_ms();
        let threshold = away_threshold_ms();

        if !is_away {
            if idle_ms >= threshold {
                is_away = true;
                away_start = Instant::now().checked_sub(std::time::Duration::from_millis(idle_ms)).unwrap_or_else(Instant::now);
                let _ = app.emit(
                    "user-presence",
                    PresenceEvent {
                        status: "away".into(),
                        away_minutes: (idle_ms / 60000).max(1),
                        user_name: crate::identity::first_name().map(String::from),
                    },
                );
            }
        } else {
            // User was away and has now performed input (mouse moved or key pressed)
            if idle_ms < 1500 {
                is_away = false;
                let away_minutes = (away_start.elapsed().as_secs() / 60).max(1);
                let _ = app.emit(
                    "user-presence",
                    PresenceEvent {
                        status: "returned".into(),
                        away_minutes,
                        user_name: crate::identity::first_name().map(String::from),
                    },
                );
            }
        }
    }
}

#[tauri::command]
pub fn get_system_presence() -> Result<PresenceEvent, String> {
    let idle_ms = system_idle_ms();
    let threshold = away_threshold_ms();
    let is_away = idle_ms >= threshold;
    Ok(PresenceEvent {
        status: if is_away { "away".into() } else { "active".into() },
        away_minutes: idle_ms / 60000,
        user_name: crate::identity::first_name().map(String::from),
    })
}
