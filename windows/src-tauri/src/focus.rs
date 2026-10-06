// Bring the window an agent session started from back to the front.
//
// coucou-hook reports the session's top-level window as (hwnd, pid). Handles
// are recycled, so the handle is only trusted while it still exists and still
// belongs to that same process; otherwise the caller falls back to opening the
// folder.

use windows::Win32::Foundation::HWND;
use windows::Win32::System::Threading::{AttachThreadInput, GetCurrentProcessId, GetCurrentThreadId};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP, VK_MENU,
};
use windows::Win32::UI::WindowsAndMessaging::{
    BringWindowToTop, GetForegroundWindow, GetWindowThreadProcessId, IsIconic, IsWindow, IsWindowVisible,
    SetForegroundWindow, ShowWindow, SW_RESTORE, SW_SHOW,
};

/// What the handle looks like right now, read from the system.
pub struct Observed {
    pub exists: bool,
    pub pid: u32,
}

/// The handle may be focused only if it still exists, still belongs to the
/// process the relay saw, and is not one of ours.
pub fn is_trusted(hwnd: i64, expected_pid: u32, observed: &Observed, own_pid: u32) -> bool {
    hwnd != 0
        && expected_pid != 0
        && expected_pid != own_pid
        && observed.exists
        && observed.pid == expected_pid
}

fn observe(hwnd: HWND) -> Observed {
    unsafe {
        let exists = IsWindow(Some(hwnd)).as_bool();
        let mut pid = 0u32;
        if exists {
            GetWindowThreadProcessId(hwnd, Some(&mut pid));
        }
        Observed { exists, pid }
    }
}

/// True when the window was validated and asked to come to the front.
pub fn focus(hwnd: i64, pid: u32) -> bool {
    let handle = HWND(hwnd as isize as *mut _);
    let own = unsafe { GetCurrentProcessId() };
    if !is_trusted(hwnd, pid, &observe(handle), own) {
        return false;
    }
    unsafe {
        // A tray app (Kimi Code, ChatGPT, Hermes) hides its main window rather
        // than minimising it: show it first, then restore if it was minimised.
        if !IsWindowVisible(handle).as_bool() {
            let _ = ShowWindow(handle, SW_SHOW);
        }
        if IsIconic(handle).as_bool() {
            let _ = ShowWindow(handle, SW_RESTORE);
        } else {
            let _ = ShowWindow(handle, SW_SHOW);
        }
        if SetForegroundWindow(handle).as_bool() {
            return true;
        }
        // The island is non-activating, so the click that got us here may not
        // have given us foreground rights. A synthetic Alt press counts as
        // input and lifts the lock; attaching to the foreground thread covers
        // the remaining cases.
        let alt = |flags| INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 {
                ki: KEYBDINPUT { wVk: VK_MENU, dwFlags: flags, ..Default::default() },
            },
        };
        let _ = SendInput(
            &[alt(Default::default()), alt(KEYEVENTF_KEYUP)],
            std::mem::size_of::<INPUT>() as i32,
        );
        if SetForegroundWindow(handle).as_bool() {
            return true;
        }
        let foreground = GetForegroundWindow();
        let theirs = GetWindowThreadProcessId(foreground, None);
        let mine = GetCurrentThreadId();
        let attached = theirs != 0 && theirs != mine && AttachThreadInput(mine, theirs, true).as_bool();
        let _ = BringWindowToTop(handle);
        let ok = SetForegroundWindow(handle).as_bool();
        if attached {
            let _ = AttachThreadInput(mine, theirs, false);
        }
        ok || GetForegroundWindow() == handle
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const OWN: u32 = 500;

    #[test]
    fn a_live_window_of_the_same_process_is_trusted() {
        assert!(is_trusted(0x1234, 42, &Observed { exists: true, pid: 42 }, OWN));
    }

    #[test]
    fn a_closed_or_recycled_handle_is_refused() {
        assert!(!is_trusted(0x1234, 42, &Observed { exists: false, pid: 0 }, OWN));
        assert!(!is_trusted(0x1234, 42, &Observed { exists: true, pid: 43 }, OWN));
    }

    #[test]
    fn empty_values_and_our_own_windows_are_refused() {
        assert!(!is_trusted(0, 42, &Observed { exists: true, pid: 42 }, OWN));
        assert!(!is_trusted(0x1234, 0, &Observed { exists: true, pid: 0 }, OWN));
        assert!(!is_trusted(0x1234, OWN, &Observed { exists: true, pid: OWN }, OWN));
    }

    #[test]
    fn a_handle_that_never_existed_is_refused_end_to_end() {
        assert!(!focus(0x7fff_fff0, 42));
    }
}
