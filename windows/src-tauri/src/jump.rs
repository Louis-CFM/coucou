// "Jump to terminal": focuses the console window running a session instead of
// just opening its folder, mirroring the macOS jump-to-tab.
//
// macOS can ask Terminal/iTerm for the tab behind a tty; Windows offers no such
// API. The heuristic that works surprisingly often: shells show the working
// directory in the title bar (PowerShell, CMD and Windows Terminal all do by
// default), so the first visible top-level window whose title contains the
// project folder name is almost always the right terminal. Anything else is
// left alone and the caller falls back to opening the folder.

use windows::Win32::Foundation::{BOOL, HWND, LPARAM};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetWindowTextW, IsWindowVisible, SetForegroundWindow, ShowWindow, SW_RESTORE,
};

struct Search {
    needle: String,
    found: Option<HWND>,
}

unsafe extern "system" fn enum_proc(hwnd: HWND, lparam: LPARAM) -> BOOL {
    let search = unsafe { &mut *(lparam.0 as *mut Search) };
    if search.found.is_some() {
        return false.into();
    }
    if unsafe { IsWindowVisible(hwnd) }.as_bool() {
        let mut buf = [0u16; 512];
        let len = unsafe { GetWindowTextW(hwnd, &mut buf) };
        if len > 0 {
            let title = String::from_utf16_lossy(&buf[..len as usize]).to_lowercase();
            if !title.is_empty() && title.contains(&search.needle) {
                search.found = Some(hwnd);
                return false.into();
            }
        }
    }
    true.into()
}

/// Brings the first visible window whose title contains `folder` to the front.
/// Returns false when nothing matches and the caller should fall back.
pub fn focus_window_for_folder(folder: &str) -> bool {
    let needle = folder.to_lowercase();
    if needle.is_empty() {
        return false;
    }
    let mut search = Search { needle, found: None };
    unsafe {
        let _ = EnumWindows(
            Some(enum_proc),
            LPARAM(&mut search as *mut Search as isize),
        );
    }
    match search.found {
        Some(hwnd) => unsafe {
            let _ = ShowWindow(hwnd, SW_RESTORE);
            SetForegroundWindow(hwnd).as_bool()
        },
        None => false,
    }
}
