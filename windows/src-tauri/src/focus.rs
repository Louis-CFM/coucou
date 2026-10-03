// Bringing an existing terminal window to the front.
//
// The relay reports the processes above it (`terminal_pids`, nearest first).
// One of them owns the window the session runs in: WindowsTerminal.exe for a WSL
// or PowerShell tab, Code.exe for VS Code's integrated terminal, a conhost for a
// bare console. "Open terminal" brings that window forward. Without one, any
// terminal window will do; only when there is none does it open a new one.
//
// A session in the Claude desktop app's Code tab has no terminal at all: the app
// starts Claude Code itself, so the app is among those processes, and its own
// window is the one to bring forward (`claude_desktop`).

use windows::core::{BOOL, PWSTR};
use windows::Win32::Foundation::{CloseHandle, HWND, LPARAM, RECT};
use windows::Win32::System::Threading::{
    OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP, VK_MENU,
};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetClassNameW, GetForegroundWindow, GetWindow, GetWindowLongW, GetWindowRect,
    GetWindowTextLengthW, GetWindowThreadProcessId, IsIconic, IsWindowVisible,
    SetForegroundWindow, ShowWindow, GWL_EXSTYLE, GW_OWNER, SW_RESTORE, SW_SHOW, WS_EX_TOOLWINDOW,
};

/// Windows Terminal, then the classic console.
const TERMINAL_CLASSES: &[&str] = &["CASCADIA_HOSTING_WINDOW_CLASS", "ConsoleWindowClass"];

struct Candidate {
    hwnd: HWND,
    pid: u32,
    class: String,
}

/// Every window a user would call "a window", front to back (EnumWindows walks
/// the z-order), so the first match is the one they used last.
fn app_windows() -> Vec<Candidate> {
    unsafe extern "system" fn collect(hwnd: HWND, lparam: LPARAM) -> BOOL {
        let out = &mut *(lparam.0 as *mut Vec<Candidate>);
        let visible = IsWindowVisible(hwnd).as_bool();
        let owned = GetWindow(hwnd, GW_OWNER).map(|o| !o.is_invalid()).unwrap_or(false);
        let tool = GetWindowLongW(hwnd, GWL_EXSTYLE) as u32 & WS_EX_TOOLWINDOW.0 != 0;
        if visible && !owned && !tool && GetWindowTextLengthW(hwnd) > 0 {
            let mut pid = 0u32;
            GetWindowThreadProcessId(hwnd, Some(&mut pid));
            let mut buf = [0u16; 64];
            let len = GetClassNameW(hwnd, &mut buf).max(0) as usize;
            out.push(Candidate { hwnd, pid, class: String::from_utf16_lossy(&buf[..len]) });
        }
        BOOL(1)
    }
    let mut out: Vec<Candidate> = Vec::new();
    unsafe {
        let _ = EnumWindows(Some(collect), LPARAM(&mut out as *mut _ as isize));
    }
    out
}

/// The session's own window if one of its ancestors has one, else any terminal
/// window. Brings it forward and says whether there was one: a window Windows
/// would not let us raise still flashes in the taskbar, and opening a second
/// terminal on top of that would only add to the confusion.
pub fn existing_terminal(pids: &[u32]) -> bool {
    let windows = app_windows();
    let ours = pids
        .iter()
        .find_map(|pid| windows.iter().find(|w| w.pid == *pid));
    let any = || {
        TERMINAL_CLASSES
            .iter()
            .find_map(|class| windows.iter().find(|w| w.class == *class))
    };
    let Some(w) = ours.or_else(any) else { return false };
    if !bring_forward(w.hwnd) {
        crate::log::line(format!("could not bring the {} window forward", w.class));
    }
    true
}

/// The Claude desktop app's window, when the session runs in its Code tab: the
/// app is then one of the session's ancestors. Brought forward even from the
/// tray, where closing the app only hides its window. Says whether there was
/// one; a session started anywhere else has no such ancestor.
pub fn claude_desktop(pids: &[u32]) -> bool {
    let Some(hwnd) = pids.iter().filter(|pid| is_claude_app(**pid)).find_map(|pid| main_window(*pid)) else {
        return false;
    };
    unsafe {
        if !IsWindowVisible(hwnd).as_bool() {
            let _ = ShowWindow(hwnd, SW_SHOW);
        }
    }
    if !bring_forward(hwnd) {
        crate::log::line("could not bring the Claude app forward");
    }
    true
}

/// Whether `pid` runs a `claude.exe`. Claude Code's own CLI is called that too,
/// but it has no window: `main_window` tells the app from it.
fn is_claude_app(pid: u32) -> bool {
    unsafe {
        let Ok(process) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else { return false };
        let mut buf = [0u16; 1024];
        let mut len = buf.len() as u32;
        let named = QueryFullProcessImageNameW(process, PROCESS_NAME_WIN32, PWSTR(buf.as_mut_ptr()), &mut len).is_ok();
        let _ = CloseHandle(process);
        named && String::from_utf16_lossy(&buf[..len as usize]).to_ascii_lowercase().ends_with("\\claude.exe")
    }
}

/// The app's main window: an Electron frame with a title, not owned by another
/// window. The visible one if there is one; else the largest of the hidden ones,
/// which is the main window put away in the tray rather than a popup.
fn main_window(pid: u32) -> Option<HWND> {
    struct Found {
        pid: u32,
        windows: Vec<(HWND, bool, i64)>,
    }
    unsafe extern "system" fn collect(hwnd: HWND, lparam: LPARAM) -> BOOL {
        let found = &mut *(lparam.0 as *mut Found);
        let mut pid = 0u32;
        GetWindowThreadProcessId(hwnd, Some(&mut pid));
        let owned = GetWindow(hwnd, GW_OWNER).map(|o| !o.is_invalid()).unwrap_or(false);
        if pid == found.pid && !owned && GetWindowTextLengthW(hwnd) > 0 {
            let mut buf = [0u16; 64];
            let len = GetClassNameW(hwnd, &mut buf).max(0) as usize;
            if String::from_utf16_lossy(&buf[..len]) == "Chrome_WidgetWin_1" {
                let mut r = RECT::default();
                let _ = GetWindowRect(hwnd, &mut r);
                let area = (r.right - r.left) as i64 * (r.bottom - r.top) as i64;
                found.windows.push((hwnd, IsWindowVisible(hwnd).as_bool(), area));
            }
        }
        BOOL(1)
    }
    let mut found = Found { pid, windows: Vec::new() };
    unsafe {
        let _ = EnumWindows(Some(collect), LPARAM(&mut found as *mut _ as isize));
    }
    found
        .windows
        .iter()
        .find(|w| w.1)
        .or_else(|| found.windows.iter().max_by_key(|w| w.2))
        .map(|w| w.0)
}

fn bring_forward(hwnd: HWND) -> bool {
    unsafe {
        if IsIconic(hwnd).as_bool() {
            let _ = ShowWindow(hwnd, SW_RESTORE);
        }
        if SetForegroundWindow(hwnd).as_bool() && GetForegroundWindow() == hwnd {
            return true;
        }
        // The island never takes focus, so Windows may refuse to let us hand it
        // to someone else. A synthetic Alt press counts as "the user just typed",
        // which lifts the foreground lock for the next call.
        let key = |flags| INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 {
                ki: KEYBDINPUT { wVk: VK_MENU, dwFlags: flags, ..Default::default() },
            },
        };
        let inputs = [key(Default::default()), key(KEYEVENTF_KEYUP)];
        SendInput(&inputs, std::mem::size_of::<INPUT>() as i32);
        let _ = SetForegroundWindow(hwnd);
        GetForegroundWindow() == hwnd
    }
}
