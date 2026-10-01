// "Open terminal": bring the VS Code window that already has the project open
// to the front, instead of `code <path>` — which opens a fresh window whenever
// the path isn't exactly the folder that window has open (a subfolder, or no
// session cwd at all).
//
// VS Code titles look like "file.ts - coucou - Visual Studio Code", so the
// window is found by the folder name. The session cwd can be a subfolder of
// the workspace, so every folder on the path is tried, deepest first.

use windows::core::BOOL;
use windows::Win32::Foundation::{HWND, LPARAM};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    keybd_event, KEYBD_EVENT_FLAGS, KEYEVENTF_KEYUP, VK_MENU,
};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetWindowTextLengthW, GetWindowTextW, IsIconic, IsWindowVisible,
    SetForegroundWindow, ShowWindow, SW_RESTORE,
};

const SUFFIX: &str = "visual studio code";

unsafe extern "system" fn collect(hwnd: HWND, lparam: LPARAM) -> BOOL {
    let out = &mut *(lparam.0 as *mut Vec<(HWND, String)>);
    if !IsWindowVisible(hwnd).as_bool() {
        return true.into();
    }
    let len = GetWindowTextLengthW(hwnd);
    if len <= 0 {
        return true.into();
    }
    let mut buf = vec![0u16; len as usize + 1];
    let n = GetWindowTextW(hwnd, &mut buf);
    let title = String::from_utf16_lossy(&buf[..n.max(0) as usize]).to_lowercase();
    if title.contains(SUFFIX) {
        out.push((hwnd, title));
    }
    true.into()
}

fn vscode_windows() -> Vec<(HWND, String)> {
    let mut found: Vec<(HWND, String)> = Vec::new();
    unsafe {
        let _ = EnumWindows(Some(collect), LPARAM(&mut found as *mut _ as isize));
    }
    found
}

/// True when the title names this folder as the workspace: "… - name - Visual
/// Studio Code" or "name - Visual Studio Code".
fn title_names(title: &str, folder: &str) -> bool {
    title.contains(&format!(" - {folder} - ")) || title.starts_with(&format!("{folder} - "))
}

fn bring_to_front(hwnd: HWND) -> bool {
    unsafe {
        if IsIconic(hwnd).as_bool() {
            let _ = ShowWindow(hwnd, SW_RESTORE);
        }
        // Windows only lets the foreground app hand the foreground over. A
        // synthetic Alt tap is the documented-in-practice way for a background
        // tray app to be allowed to do it once.
        keybd_event(VK_MENU.0 as u8, 0, KEYBD_EVENT_FLAGS(0), 0);
        keybd_event(VK_MENU.0 as u8, 0, KEYEVENTF_KEYUP, 0);
        SetForegroundWindow(hwnd).as_bool()
    }
}

/// Focuses the VS Code window for `path`. With no path, any VS Code window.
/// Returns false when there is none to focus, so the caller can launch one.
pub fn focus(path: Option<&str>) -> bool {
    let windows = vscode_windows();
    if windows.is_empty() {
        return false;
    }
    match path {
        Some(p) => {
            let folders: Vec<String> = std::path::Path::new(p)
                .components()
                .filter_map(|c| match c {
                    std::path::Component::Normal(s) => Some(s.to_string_lossy().to_lowercase()),
                    _ => None,
                })
                .collect();
            for folder in folders.iter().rev() {
                if let Some((hwnd, _)) = windows.iter().find(|(_, t)| title_names(t, folder)) {
                    return bring_to_front(*hwnd);
                }
            }
            false
        }
        None => bring_to_front(windows[0].0),
    }
}
