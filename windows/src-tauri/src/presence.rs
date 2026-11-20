// System User Presence Monitor (#1055 & Mochi Companion).
// Uses Windows Win32 GetLastInputInfo to detect when the user steps away from keyboard/mouse
// (10-15+ minutes) and returns, notifying the webview so Mochi greets them warmly in the small notch.

use serde::{Deserialize, Serialize};
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum LockStatus {
    UnlockedConfirmed,
    LockedConfirmed,
    Unknown,
}

impl LockStatus {
    /// Safe decision rule: returns true if greetings must be suppressed.
    /// Both LockedConfirmed and Unknown suppress personalized greetings.
    pub fn suppresses_greetings(&self) -> bool {
        match self {
            LockStatus::UnlockedConfirmed => false,
            LockStatus::LockedConfirmed | LockStatus::Unknown => true,
        }
    }
}

#[cfg(windows)]
pub fn query_workstation_lock_status() -> LockStatus {
    extern "system" {
        fn OpenInputDesktop(dw_flags: u32, f_inherit: i32, dw_desired_access: u32) -> isize;
        fn CloseDesktop(h_desktop: isize) -> i32;
        fn GetLastError() -> u32;
    }
    unsafe {
        // DESKTOP_SWITCHDESKTOP access right is 0x0100
        let hdesk = OpenInputDesktop(0, 0, 0x0100);
        if hdesk != 0 {
            CloseDesktop(hdesk);
            LockStatus::UnlockedConfirmed
        } else {
            let err = GetLastError();
            // ERROR_ACCESS_DENIED (5) confirms secure desktop / lock screen active
            if err == 5 {
                LockStatus::LockedConfirmed
            } else {
                LockStatus::Unknown
            }
        }
    }
}

#[cfg(not(windows))]
pub fn query_workstation_lock_status() -> LockStatus {
    LockStatus::UnlockedConfirmed
}

pub fn is_workstation_locked() -> bool {
    query_workstation_lock_status().suppresses_greetings()
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PresenceState {
    ActiveUnlocked,
    IdleUnlocked,
    Locked,
}

#[derive(Debug, Clone)]
pub struct PresenceStateMachine {
    pub state: PresenceState,
    pub away_start_ms: u64,
    pub last_return_event_ms: u64,
    pub min_return_debounce_ms: u64,
}

impl Default for PresenceStateMachine {
    fn default() -> Self {
        Self::new()
    }
}

impl PresenceStateMachine {
    pub fn new() -> Self {
        Self {
            state: PresenceState::ActiveUnlocked,
            away_start_ms: 0,
            last_return_event_ms: 0,
            min_return_debounce_ms: 3000,
        }
    }

    /// Evaluates one sensor tick against the current workstation state.
    /// Returns Some((status, away_minutes)) if a transition emits an event.
    pub fn tick(
        &mut self,
        locked: bool,
        idle_ms: u64,
        threshold_ms: u64,
        now_ms: u64,
    ) -> Option<(&'static str, u64)> {
        // 1. Workstation is locked (Win+L / Secure Desktop / Logon / UAC)
        if locked {
            if self.state != PresenceState::Locked {
                let away_start = now_ms.saturating_sub(idle_ms);
                self.away_start_ms = away_start;
                self.state = PresenceState::Locked;
                return Some(("away", (idle_ms / 60000).max(1)));
            }
            // CRITICAL: NEVER emit "returned" while locked, even if input occurs on lock screen!
            return None;
        }

        // 2. Workstation is unlocked
        match self.state {
            PresenceState::Locked => {
                // Transitioned from locked to unlocked
                let elapsed_ms = now_ms.saturating_sub(self.away_start_ms);
                let away_minutes = (elapsed_ms / 60000).max(1);
                self.state = PresenceState::ActiveUnlocked;
                if now_ms.saturating_sub(self.last_return_event_ms) >= self.min_return_debounce_ms {
                    self.last_return_event_ms = now_ms;
                    Some(("returned", away_minutes))
                } else {
                    None
                }
            }
            PresenceState::IdleUnlocked => {
                // User was idle, now performed input
                if idle_ms < 1500 {
                    let elapsed_ms = now_ms.saturating_sub(self.away_start_ms);
                    let away_minutes = (elapsed_ms / 60000).max(1);
                    self.state = PresenceState::ActiveUnlocked;
                    if now_ms.saturating_sub(self.last_return_event_ms) >= self.min_return_debounce_ms {
                        self.last_return_event_ms = now_ms;
                        Some(("returned", away_minutes))
                    } else {
                        None
                    }
                } else {
                    None
                }
            }
            PresenceState::ActiveUnlocked => {
                if idle_ms >= threshold_ms {
                    self.away_start_ms = now_ms.saturating_sub(idle_ms);
                    self.state = PresenceState::IdleUnlocked;
                    Some(("away", (idle_ms / 60000).max(1)))
                } else {
                    None
                }
            }
        }
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
    let mut machine = PresenceStateMachine::new();

    loop {
        std::thread::sleep(std::time::Duration::from_millis(2000));

        let locked = is_workstation_locked();
        let idle_ms = system_idle_ms();
        let threshold = away_threshold_ms();
        let now_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64;

        if let Some((status, away_minutes)) = machine.tick(locked, idle_ms, threshold, now_ms) {
            let user_name = if status == "returned" {
                crate::identity::refresh().detected_greeting_name
            } else {
                crate::identity::first_name()
            };

            let _ = app.emit(
                "user-presence",
                PresenceEvent {
                    status: status.into(),
                    away_minutes,
                    user_name,
                },
            );
        }
    }
}

#[tauri::command]
pub fn get_system_presence() -> Result<PresenceEvent, String> {
    let locked = is_workstation_locked();
    let idle_ms = system_idle_ms();
    let threshold = away_threshold_ms();
    let is_away = locked || idle_ms >= threshold;
    Ok(PresenceEvent {
        status: if is_away { "away".into() } else { "active".into() },
        away_minutes: idle_ms / 60000,
        user_name: crate::identity::first_name().map(String::from),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_lock_status_semantics() {
        assert_eq!(LockStatus::UnlockedConfirmed.suppresses_greetings(), false);
        assert_eq!(LockStatus::LockedConfirmed.suppresses_greetings(), true);
        assert_eq!(LockStatus::Unknown.suppresses_greetings(), true);
    }

    #[test]
    fn test_is_workstation_locked_does_not_panic() {
        // When running in test environment on desktop, should safely return bool
        let status = query_workstation_lock_status();
        let locked = is_workstation_locked();
        assert_eq!(locked, status.suppresses_greetings());
    }

    #[test]
    fn test_away_threshold_bounds() {
        let ms = away_threshold_ms();
        assert!(ms >= 60_000);
    }

    #[test]
    fn test_locked_state_suppresses_return_even_with_input() {
        let mut sm = PresenceStateMachine::new();
        // 1. Lock screen engages at t = 100_000
        let evt1 = sm.tick(true, 0, 180_000, 100_000);
        assert_eq!(evt1, Some(("away", 1)));
        assert_eq!(sm.state, PresenceState::Locked);

        // 2. Someone moves mouse / types password on lock screen: idle_ms drops to 0, but locked is true!
        let evt2 = sm.tick(true, 0, 180_000, 110_000);
        // CRITICAL: MUST BE None! Zero greeting leak on locked desktop!
        assert_eq!(evt2, None);
        assert_eq!(sm.state, PresenceState::Locked);
    }

    #[test]
    fn test_unlock_transition_emits_returned_once() {
        let mut sm = PresenceStateMachine::new();
        // Lock screen engages
        sm.tick(true, 0, 180_000, 100_000);

        // User unlocks at t = 220_000 (2 minutes later)
        let evt = sm.tick(false, 0, 180_000, 220_000);
        assert_eq!(evt, Some(("returned", 2)));
        assert_eq!(sm.state, PresenceState::ActiveUnlocked);

        // Subsequent ticks while user is active should emit nothing
        let evt_subsequent = sm.tick(false, 500, 180_000, 222_000);
        assert_eq!(evt_subsequent, None);
    }

    #[test]
    fn test_idle_to_returned_transition() {
        let mut sm = PresenceStateMachine::new();
        // User goes idle beyond threshold at t = 300_000 (idle for 185s, so away started at t = 115_000)
        let evt_away = sm.tick(false, 185_000, 180_000, 300_000);
        assert_eq!(evt_away, Some(("away", 3)));
        assert_eq!(sm.state, PresenceState::IdleUnlocked);

        // User moves mouse (<1500ms idle) at t = 480_000 (total absence: 480_000 - 115_000 = 365s = 6 mins)
        let evt_return = sm.tick(false, 200, 180_000, 480_000);
        assert_eq!(evt_return, Some(("returned", 6)));
        assert_eq!(sm.state, PresenceState::ActiveUnlocked);
    }

    #[test]
    fn test_debounce_suppresses_rapid_bouncing() {
        let mut sm = PresenceStateMachine::new();
        sm.tick(true, 0, 180_000, 100_000);
        // Unlock 1
        let evt1 = sm.tick(false, 0, 180_000, 110_000);
        assert_eq!(evt1, Some(("returned", 1)));

        // Rapid re-lock and unlock within 1 second
        sm.tick(true, 0, 180_000, 110_500);
        let evt2 = sm.tick(false, 0, 180_000, 111_000);
        // Suppressed by debounce!
        assert_eq!(evt2, None);
    }
}
