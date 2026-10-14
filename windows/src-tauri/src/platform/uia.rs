// The tab a session runs in, inside a terminal window that has tabs.
//
// A Windows Terminal window is one window with many tabs, so "the window of the
// session" is not enough to bring the right terminal forward. UI Automation
// lists the tabs of a window (TabItem controls), says which is selected, names
// each by a runtime ID that holds for as long as the tab lives, and selects one.
//
// `capture` runs when a prompt is submitted: that is when the terminal of the
// session is the window in front, and its selected tab is the session's. `select`
// runs when "Open terminal" is clicked. Both are slow enough (tens to hundreds of
// milliseconds on a window with many tabs) to stay off the UI thread.

use windows::Win32::Foundation::HWND;
use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED, SAFEARRAY};
use windows::Win32::System::Ole::{SafeArrayDestroy, SafeArrayGetElement, SafeArrayGetLBound, SafeArrayGetUBound};
use windows::Win32::System::Variant::{VARIANT, VARIANT_0_0, VARIANT_0_0_0, VT_I4};
use windows::Win32::UI::Accessibility::{
    CUIAutomation, IUIAutomation, IUIAutomationElement, IUIAutomationSelectionItemPattern, TreeScope_Descendants,
    UIA_ControlTypePropertyId, UIA_SelectionItemPatternId, UIA_TabItemControlTypeId,
};

use crate::session_window::{self, TabRef};

/// One tab as UI Automation shows it.
struct Tab {
    runtime_id: Vec<i32>,
    title: String,
    selected: bool,
    element: IUIAutomationElement,
}

/// A 32-bit integer as the VARIANT a property condition compares with.
fn variant_i32(value: i32) -> VARIANT {
    let mut variant = VARIANT::default();
    variant.Anonymous.Anonymous = std::mem::ManuallyDrop::new(VARIANT_0_0 {
        vt: VT_I4,
        Anonymous: VARIANT_0_0_0 { lVal: value },
        ..Default::default()
    });
    variant
}

/// A thread that talks to UI Automation needs COM. Already initialised, in
/// either apartment, is fine.
fn init_com() {
    let _ = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
}

unsafe fn runtime_id(element: &IUIAutomationElement) -> Vec<i32> {
    let Ok(array) = element.GetRuntimeId() else { return Vec::new() };
    let array: *mut SAFEARRAY = array;
    if array.is_null() {
        return Vec::new();
    }
    let mut out = Vec::new();
    if let (Ok(low), Ok(high)) = (SafeArrayGetLBound(array, 1), SafeArrayGetUBound(array, 1)) {
        for i in low..=high {
            let mut value = 0i32;
            if SafeArrayGetElement(array, &i, &mut value as *mut i32 as *mut _).is_ok() {
                out.push(value);
            }
        }
    }
    let _ = SafeArrayDestroy(array);
    out
}

/// The tabs of a window, in the order they are shown.
fn tabs(hwnd: isize) -> windows::core::Result<Vec<Tab>> {
    init_com();
    unsafe {
        let automation: IUIAutomation = CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER)?;
        let root = automation.ElementFromHandle(HWND(hwnd as *mut _))?;
        let is_tab = automation.CreatePropertyCondition(UIA_ControlTypePropertyId, &variant_i32(UIA_TabItemControlTypeId.0))?;
        let found = root.FindAll(TreeScope_Descendants, &is_tab)?;
        let mut out = Vec::new();
        for i in 0..found.Length()? {
            let element = found.GetElement(i)?;
            let selected = element
                .GetCurrentPatternAs::<IUIAutomationSelectionItemPattern>(UIA_SelectionItemPatternId)
                .and_then(|pattern| pattern.CurrentIsSelected())
                .map(|b| b.as_bool())
                .unwrap_or(false);
            out.push(Tab {
                runtime_id: runtime_id(&element),
                title: element.CurrentName().map(|n| n.to_string()).unwrap_or_default(),
                selected,
                element,
            });
        }
        Ok(out)
    }
}

/// The selected tab of `hwnd`, if it is a window with tabs.
pub fn capture(hwnd: isize) -> Option<TabRef> {
    let selected = tabs(hwnd).ok()?.into_iter().find(|t| t.selected)?;
    Some(TabRef { hwnd, runtime_id: selected.runtime_id, title: selected.title })
}

/// Makes the remembered tab the selected one. False when the window has no
/// such tab any more (or none can be told from the others).
pub fn select(tab: &TabRef) -> bool {
    let Ok(list) = tabs(tab.hwnd) else { return false };
    let names: Vec<(Vec<i32>, String)> = list.iter().map(|t| (t.runtime_id.clone(), t.title.clone())).collect();
    let Some(i) = session_window::pick_tab(&names, tab) else { return false };
    unsafe {
        list[i]
            .element
            .GetCurrentPatternAs::<IUIAutomationSelectionItemPattern>(UIA_SelectionItemPatternId)
            .and_then(|pattern| pattern.Select())
            .is_ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Needs a Windows Terminal window open. Lists its tabs and selects the one
    /// that is already selected, so nothing visibly changes.
    #[test]
    #[ignore = "needs a Windows Terminal window"]
    fn the_tabs_of_a_real_windows_terminal_are_listed_and_one_is_selected() {
        let hwnd = crate::platform::windows_terminal_windows().into_iter().next().expect("no Windows Terminal window");
        let list = tabs(hwnd).unwrap();
        for t in &list {
            println!("{} {:?} {:?}", if t.selected { "*" } else { " " }, t.runtime_id, t.title);
        }
        assert!(!list.is_empty());
        let current = capture(hwnd).expect("a tab is selected");
        println!("captured: {current:?}");
        assert!(select(&current));
        assert_eq!(capture(hwnd).map(|t| t.runtime_id), Some(current.runtime_id));
    }
}
