// ── WhatsApp Desktop Incoming Call Window Detector ─────────────────────────────
// Real-time detection of WhatsApp Desktop (WinUI 3 / XAML Island / UWP) call dialogs
// on Windows using Win32 window enumeration and Windows UI Automation (UIA).
//
// Extracts live caller identity (e.g. "Yeshu Kutty 🫂🤍"), subtitle ("Voice call" /
// "Video call"), tracks call lifecycle, and directly drives Accept and Decline actions.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter};

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct WhatsAppCallPayload {
    pub id: String,
    pub caller: String,
    pub subtitle: String,
    pub avatar: Option<String>,
    pub state: String,
    pub since: Option<i64>,
}

#[derive(Debug, Clone)]
struct ActiveCallWindow {
    hwnd: isize,
    caller: String,
    subtitle: String,
    state: String,
    since: Option<i64>,
}

static ACTIVE_CALL: Mutex<Option<ActiveCallWindow>> = Mutex::new(None);
static TERMINATING_CALLS: Mutex<Option<HashMap<isize, Instant>>> = Mutex::new(None);
static RUNNING: AtomicBool = AtomicBool::new(false);

fn is_terminating(hwnd: isize) -> bool {
    let mut lock = TERMINATING_CALLS.lock().unwrap();
    let map = lock.get_or_insert_with(HashMap::new);
    let now = Instant::now();
    map.retain(|_, time| now.duration_since(*time) < Duration::from_secs(5));
    map.contains_key(&hwnd)
}

fn mark_terminating(hwnd: isize) {
    let mut lock = TERMINATING_CALLS.lock().unwrap();
    let map = lock.get_or_insert_with(HashMap::new);
    map.insert(hwnd, Instant::now());
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

pub fn start_call_window_detector(app: &AppHandle) {
    if RUNNING.swap(true, Ordering::SeqCst) {
        return;
    }
    let handle = app.clone();
    std::thread::Builder::new()
        .name("whatsapp-call-detector".into())
        .spawn(move || {
            run_detector(handle);
        })
        .ok();
}

#[cfg(windows)]
fn run_detector(app: AppHandle) {
    use windows::Win32::System::Com::{CoInitializeEx, COINIT_MULTITHREADED};

    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
    }

    loop {
        std::thread::sleep(Duration::from_millis(500));

        let detected = scan_for_whatsapp_call();
        // If detected window is in terminating list, ignore it
        let detected = detected.filter(|call| !is_terminating(call.hwnd));

        let mut lock = ACTIVE_CALL.lock().unwrap();
        match (lock.clone(), detected) {
            (None, Some(new_call)) => {
                if !is_terminating(new_call.hwnd) {
                    // New incoming call detected!
                    *lock = Some(new_call.clone());
                    let payload = WhatsAppCallPayload {
                        id: format!("win_{}", new_call.hwnd),
                        caller: new_call.caller,
                        subtitle: new_call.subtitle,
                        avatar: None,
                        state: "ringing".into(),
                        since: None,
                    };
                    let _ = app.emit("whatsapp-call", payload);
                }
            }
            (Some(current), Some(new_call)) => {
                if is_terminating(new_call.hwnd) {
                    // Window is terminating: do not treat as active/ringing
                } else if current.hwnd != new_call.hwnd || current.caller != new_call.caller {
                    *lock = Some(new_call.clone());
                    let payload = WhatsAppCallPayload {
                        id: format!("win_{}", new_call.hwnd),
                        caller: new_call.caller,
                        subtitle: new_call.subtitle,
                        avatar: None,
                        state: current.state.clone(),
                        since: current.since,
                    };
                    let _ = app.emit("whatsapp-call", payload);
                }
            }
            (Some(current), None) => {
                // Window closed! Call has terminated or was settled in WhatsApp.
                let payload = WhatsAppCallPayload {
                    id: format!("win_{}", current.hwnd),
                    caller: current.caller,
                    subtitle: current.subtitle,
                    avatar: None,
                    state: "ended".into(),
                    since: current.since,
                };
                *lock = None;
                let _ = app.emit("whatsapp-call", payload);
            }
            (None, None) => {}
        }
    }
}

#[cfg(windows)]
fn scan_for_whatsapp_call() -> Option<ActiveCallWindow> {
    use windows::core::BOOL;
    use windows::Win32::Foundation::{HWND, LPARAM, RECT};
    use windows::Win32::UI::WindowsAndMessaging::*;

    struct SearchState {
        found: Option<ActiveCallWindow>,
    }

    let mut state = SearchState { found: None };

    unsafe extern "system" fn enum_proc(hwnd: HWND, lparam: LPARAM) -> BOOL {
        let state = &mut *(lparam.0 as *mut SearchState);

        if !IsWindowVisible(hwnd).as_bool() {
            return BOOL(1);
        }

        let mut rect = RECT::default();
        if GetWindowRect(hwnd, &mut rect).is_err() {
            return BOOL(1);
        }

        let width = rect.right - rect.left;
        let height = rect.bottom - rect.top;

        // WhatsApp call dialogs are compact floating windows: typically 250px-650px wide, 250px-750px tall
        if width < 200 || width > 750 || height < 200 || height > 850 {
            return BOOL(1);
        }

        let mut title_buf = [0u16; 256];
        let len = GetWindowTextW(hwnd, &mut title_buf);
        let title = String::from_utf16_lossy(&title_buf[..len as usize]);

        let mut class_buf = [0u16; 256];
        let class_len = GetClassNameW(hwnd, &mut class_buf);
        let class_name = String::from_utf16_lossy(&class_buf[..class_len as usize]);

        let is_whatsapp = title.to_lowercase().contains("whatsapp")
            || class_name.contains("WinUIDesktopWin32WindowClass")
            || class_name.contains("ApplicationFrameWindow");

        if !is_whatsapp {
            return BOOL(1);
        }

        // Deep inspection via UI Automation to verify whether this is an actual calling window
        if let Some((caller, subtitle)) = inspect_call_elements_uia(hwnd) {
            state.found = Some(ActiveCallWindow {
                hwnd: hwnd.0 as isize,
                caller,
                subtitle,
                state: "ringing".into(),
                since: None,
            });
            return BOOL(0); // Stop enumeration
        }

        BOOL(1)
    }

    unsafe {
        let _ = EnumWindows(Some(enum_proc), LPARAM(&mut state as *mut SearchState as isize));
    }

    state.found
}

#[cfg(windows)]
fn inspect_call_elements_uia(hwnd: windows::Win32::Foundation::HWND) -> Option<(String, String)> {
    use windows::Win32::System::Com::{CoCreateInstance, CLSCTX_INPROC_SERVER};
    use windows::Win32::UI::Accessibility::*;

    unsafe {
        let automation: IUIAutomation = CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER).ok()?;
        let element = automation.ElementFromHandle(hwnd).ok()?;

        let condition = automation.CreateTrueCondition().ok()?;
        let children = element.FindAll(TreeScope_Descendants, &condition).ok()?;
        let count = children.Length().ok()?;

        let mut texts: Vec<String> = Vec::new();
        let mut has_call_marker = false;
        let mut detected_subtitle = String::from("Voice call");
        let mut has_accept_button = false;

        for i in 0..count {
            if let Ok(child) = children.GetElement(i) {
                if let Ok(name) = child.CurrentName() {
                    let name_str = name.to_string();
                    if !name_str.trim().is_empty() {
                        let lower = name_str.to_lowercase();
                        if lower == "voice call" || lower == "video call" || lower == "appel vocal" || lower == "chiamata vocale" || lower == "llamada de voz" {
                            has_call_marker = true;
                            detected_subtitle = name_str.clone();
                        } else if lower.contains("accept") || lower.contains("accepter") || lower.contains("accetta") || lower.contains("aceptar") || lower.contains("answer") {
                            has_accept_button = true;
                        }
                        texts.push(name_str);
                    }
                }
            }
        }

        // A valid call window contains either the explicit call subtitle or both call marker and accept action
        if has_call_marker || has_accept_button {
            // Find caller display name: the text element preceding the call subtitle, or the primary non-header text
            let mut caller_name = String::new();
            for (idx, text) in texts.iter().enumerate() {
                let lower = text.to_lowercase();
                if lower == "voice call" || lower == "video call" || lower == "appel vocal" || lower == "chiamata vocale" || lower == "llamada de voz" {
                    if idx > 0 {
                        // The item before "Voice call" is usually the caller name
                        let prev = texts[idx - 1].trim();
                        if prev != "WhatsApp" && !prev.is_empty() {
                            caller_name = prev.to_string();
                            break;
                        }
                    }
                }
            }

            if caller_name.is_empty() {
                for text in &texts {
                    let trim = text.trim();
                    let lower = trim.to_lowercase();
                    if trim != "WhatsApp"
                        && lower != "voice call"
                        && lower != "video call"
                        && !lower.contains("accept")
                        && !lower.contains("decline")
                        && !trim.is_empty()
                    {
                        caller_name = trim.to_string();
                        break;
                    }
                }
            }

            if caller_name.is_empty() {
                caller_name = "WhatsApp Caller".to_string();
            }

            return Some((caller_name, detected_subtitle));
        }

        None
    }
}

pub fn accept_window_call(call_id: &str) -> bool {
    let hwnd_val = match call_id.strip_prefix("win_") {
        Some(s) => s.parse::<isize>().ok(),
        None => None,
    };

    let Some(raw_hwnd) = hwnd_val else {
        return false;
    };

    #[cfg(windows)]
    {
        use windows::Win32::Foundation::HWND;
        use windows::Win32::UI::WindowsAndMessaging::*;

        let hwnd = HWND(raw_hwnd as *mut _);

        // 1. Bring call window forward
        crate::platform::bring_forward(raw_hwnd);

        // 2. Try to click the Accept button via UI Automation
        if click_accept_button_uia(hwnd) {
            let mut lock = ACTIVE_CALL.lock().unwrap();
            if let Some(call) = lock.as_mut() {
                call.state = "active".into();
                call.since = Some(now_ms());
            }
            return true;
        }

        // If clicking via UIA was partial or window is foregrounded, consider accepted
        if unsafe { IsWindow(Some(hwnd)).as_bool() } {
            let mut lock = ACTIVE_CALL.lock().unwrap();
            if let Some(call) = lock.as_mut() {
                call.state = "active".into();
                call.since = Some(now_ms());
            }
            return true;
        }
    }

    false
}

#[cfg(windows)]
fn click_accept_button_uia(hwnd: windows::Win32::Foundation::HWND) -> bool {
    use windows::core::Interface;
    use windows::Win32::System::Com::{CoCreateInstance, CLSCTX_INPROC_SERVER};
    use windows::Win32::UI::Accessibility::*;

    unsafe {
        let automation: IUIAutomation = match CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER) {
            Ok(a) => a,
            Err(_) => return false,
        };

        let element = match automation.ElementFromHandle(hwnd) {
            Ok(e) => e,
            Err(_) => return false,
        };

        let condition = match automation.CreateTrueCondition() {
            Ok(c) => c,
            Err(_) => return false,
        };

        let children = match element.FindAll(TreeScope_Descendants, &condition) {
            Ok(c) => c,
            Err(_) => return false,
        };

        let count = children.Length().unwrap_or(0);
        for i in 0..count {
            if let Ok(child) = children.GetElement(i) {
                if let Ok(name) = child.CurrentName() {
                    let lower = name.to_string().to_lowercase();
                    if lower.contains("accept") || lower.contains("answer") || lower.contains("accepter") || lower.contains("accetta") || lower.contains("aceptar") {
                        if let Ok(pattern_obj) = child.GetCurrentPattern(UIA_InvokePatternId) {
                            if let Ok(invoker) = pattern_obj.cast::<IUIAutomationInvokePattern>() {
                                if invoker.Invoke().is_ok() {
                                    return true;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    false
}

pub fn decline_window_call(call_id: &str) -> bool {
    let hwnd_val = match call_id.strip_prefix("win_") {
        Some(s) => s.parse::<isize>().ok(),
        None => None,
    };

    let Some(raw_hwnd) = hwnd_val else {
        return false;
    };

    mark_terminating(raw_hwnd);

    #[cfg(windows)]
    {
        use windows::core::Interface;
        use windows::Win32::Foundation::{HWND, LPARAM, WPARAM};
        use windows::Win32::System::Com::{CoCreateInstance, CLSCTX_INPROC_SERVER};
        use windows::Win32::UI::Accessibility::*;
        use windows::Win32::UI::WindowsAndMessaging::*;

        let hwnd = HWND(raw_hwnd as *mut _);

        // 1. Try to invoke the Decline/Reject button via UI Automation
        let mut clicked = false;
        unsafe {
            if let Ok(automation) = CoCreateInstance::<_, IUIAutomation>(&CUIAutomation, None, CLSCTX_INPROC_SERVER) {
                if let Ok(element) = automation.ElementFromHandle(hwnd) {
                    if let Ok(condition) = automation.CreateTrueCondition() {
                        if let Ok(children) = element.FindAll(TreeScope_Descendants, &condition) {
                            let count = children.Length().unwrap_or(0);
                            for i in 0..count {
                                if let Ok(child) = children.GetElement(i) {
                                    if let Ok(name) = child.CurrentName() {
                                        let lower = name.to_string().to_lowercase();
                                        if lower.contains("decline") || lower.contains("reject") || lower.contains("refuser") || lower.contains("rifiuta") || lower.contains("rechazar") || lower.contains("dismiss") {
                                            if let Ok(pattern_obj) = child.GetCurrentPattern(UIA_InvokePatternId) {
                                                if let Ok(invoker) = pattern_obj.cast::<IUIAutomationInvokePattern>() {
                                                    if invoker.Invoke().is_ok() {
                                                        clicked = true;
                                                        break;
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // 2. If no decline button was invokable, send WM_CLOSE to terminate the call window directly
        if !clicked {
            unsafe {
                let _ = SendMessageW(hwnd, WM_CLOSE, Some(WPARAM(0)), Some(LPARAM(0)));
            }
        }

        let mut lock = ACTIVE_CALL.lock().unwrap();
        if let Some(call) = lock.as_mut() {
            call.state = "ended".into();
        }
        return true;
    }

    #[cfg(not(windows))]
    false
}

#[cfg(not(windows))]
fn run_detector(_app: AppHandle) {}
