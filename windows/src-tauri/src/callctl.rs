// Answering and ending iPhone calls from the island, through Phone Link.
//
// Windows has no API for one app to answer another app's call: Phone Link owns
// the Bluetooth call. What it does have is UI Automation, the interface screen
// readers use. This finds Phone Link's own Accept / Decline / End call buttons
// (in its call notification, or its call window) and presses them, exactly as
// a click would. It needs that notification or window to exist: with Phone
// Link's banners off there is nothing to press, and the island falls back to
// bringing Phone Link forward.
//
// Experimental by nature: a Phone Link update that renames its buttons breaks
// it, and the island then falls back the same way.

use windows::core::BSTR;
use windows::Win32::System::Variant::VARIANT;
use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED};
use windows::Win32::UI::Accessibility::{
    CUIAutomation, IUIAutomation, IUIAutomationElement, IUIAutomationInvokePattern, TreeScope_Children,
    TreeScope_Descendants, UIA_ButtonControlTypeId, UIA_ControlTypePropertyId, UIA_InvokePatternId,
};

/// Button names, lower-case, per language Phone Link ships in the most.
const ANSWER: [&str; 6] = ["accept", "answer", "accept call", "répondre", "aceptar", "उठाएँ"];
const END: [&str; 9] = ["decline", "reject", "end call", "hang up", "end", "refuser", "raccrocher", "rechazar", "colgar"];

/// Whether a top-level window can hold a call's buttons: a notification, or
/// Phone Link's own window.
pub fn call_surface(window_name: &str, process: &str) -> bool {
    let n = window_name.to_lowercase();
    let p = process.to_lowercase();
    n == "new notification" || n.contains("phone link") || n.contains("incoming call")
        || p.contains("phoneexperiencehost") || p.contains("yourphone")
}

/// Whether a button is the one wanted.
pub fn is_button(name: &str, answer: bool) -> bool {
    let n = name.trim().to_lowercase();
    let list: &[&str] = if answer { &ANSWER } else { &END };
    list.iter().any(|w| n == *w || n.starts_with(&format!("{w} ")))
}

fn process_name(pid: u32) -> String {
    use windows::Win32::Foundation::CloseHandle;
    use windows::Win32::System::Threading::{OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION};
    unsafe {
        let Ok(h) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else { return String::new() };
        let mut buf = [0u16; 512];
        let mut len = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(h, PROCESS_NAME_WIN32, windows::core::PWSTR(buf.as_mut_ptr()), &mut len).is_ok();
        let _ = CloseHandle(h);
        if ok { String::from_utf16_lossy(&buf[..len as usize]) } else { String::new() }
    }
}

fn press(answer: bool) -> windows::core::Result<bool> {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        let uia: IUIAutomation = CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER)?;
        let root = uia.GetRootElement()?;
        let buttons = uia.CreatePropertyCondition(UIA_ControlTypePropertyId, &VARIANT::from(UIA_ButtonControlTypeId.0))?;
        let all = uia.CreateTrueCondition()?;
        // Only the windows that can hold a call: searching the whole desktop takes seconds.
        let tops = root.FindAll(TreeScope_Children, &all)?;
        for i in 0..tops.Length()? {
            let top: IUIAutomationElement = tops.GetElement(i)?;
            let name = top.CurrentName().map(|b: BSTR| b.to_string()).unwrap_or_default();
            let pid = top.CurrentProcessId().unwrap_or(0) as u32;
            if !call_surface(&name, &process_name(pid)) {
                continue;
            }
            let found = top.FindAll(TreeScope_Descendants, &buttons)?;
            for j in 0..found.Length()? {
                let b = found.GetElement(j)?;
                let label = b.CurrentName().map(|s| s.to_string()).unwrap_or_default();
                if is_button(&label, answer) {
                    let invoke: IUIAutomationInvokePattern = b.GetCurrentPatternAs(UIA_InvokePatternId)?;
                    invoke.Invoke()?;
                    crate::log::line(format!("calls: pressed {}", if answer { "answer" } else { "end" }));
                    return Ok(true);
                }
            }
        }
        crate::log::line("calls: no Phone Link call button on screen");
        Ok(false)
    }
}

/// The island's ✓ / ✕ on a call: true when Phone Link's button was pressed.
#[tauri::command]
pub async fn call_action(answer: bool) -> bool {
    tauri::async_runtime::spawn_blocking(move || press(answer).unwrap_or(false)).await.unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_call_windows_are_searched() {
        assert!(call_surface("New notification", "C:\\Windows\\ShellExperienceHost.exe"));
        assert!(call_surface("Phone Link", ""));
        assert!(call_surface("", "C:\\Program Files\\WindowsApps\\Microsoft.YourPhone\\PhoneExperienceHost.exe"));
        assert!(!call_surface("Visual Studio Code", "Code.exe"));
    }

    #[test]
    fn buttons_are_matched_by_their_label() {
        assert!(is_button("Accept", true));
        assert!(is_button("Answer call", true));
        assert!(is_button("Decline", false));
        assert!(is_button("End call", false));
        assert!(!is_button("Decline", true));
        assert!(!is_button("Accepted terms", true));
    }
}
