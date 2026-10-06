// Pick the Windows Terminal tab an agent session runs in.
//
// Focusing the terminal window is not enough when several sessions share one
// Windows Terminal window: its tabs are not separate windows. coucou-hook
// reports a process attached to the session's console. Its console title is
// what Windows Terminal shows as the tab name, so the title is briefly swapped
// for a unique marker, the tab carrying that marker is found through UI
// Automation and selected, and the original title is put back. When the
// marker never shows (a renamed tab, a profile that ignores app titles), the
// tab whose name is exactly the original title is used — only if it is the
// only one. Everything runs on its own thread after the window is focused.

use std::hash::{BuildHasher, Hasher};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use windows::core::{Interface, BOOL, HSTRING, PWSTR};
use windows::Win32::Foundation::{CloseHandle, HWND};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED,
};
use windows::Win32::System::Console::{
    AttachConsole, FreeConsole, GetConsoleTitleW, GetConsoleWindow, GetStdHandle, SetConsoleCtrlHandler,
    SetConsoleTitleW, SetStdHandle, STD_ERROR_HANDLE, STD_INPUT_HANDLE, STD_OUTPUT_HANDLE,
};
use windows::Win32::System::Threading::{
    OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
};
use windows::Win32::System::Variant::VARIANT;
use windows::Win32::UI::Accessibility::{
    CUIAutomation, CUIAutomation8, IUIAutomation, IUIAutomation2, IUIAutomationCondition, IUIAutomationElement,
    IUIAutomationSelectionItemPattern, TreeScope_Descendants, UIA_ControlTypePropertyId,
    UIA_SelectionItemPatternId, UIA_TabItemControlTypeId,
};
use windows::Win32::UI::WindowsAndMessaging::{GetAncestor, GetWindowThreadProcessId, GA_ROOTOWNER};

use crate::log;

/// How long the marker may take to reach the tab name.
const MARKER_WAIT: Duration = Duration::from_millis(800);
const POLL: Duration = Duration::from_millis(50);
/// Hard cap for the whole tab selection.
const CAP: Duration = Duration::from_millis(1500);

/// Attaching to a console is process-wide: one at a time.
static CONSOLE: Mutex<()> = Mutex::new(());

/// The tab whose name carries the marker.
pub fn marker_tab(names: &[String], marker: &str) -> Option<usize> {
    if marker.is_empty() {
        return None;
    }
    names.iter().position(|name| name.contains(marker))
}

/// The tab named exactly `title`, if no other tab has that name.
pub fn unique_title_tab(names: &[String], title: &str) -> Option<usize> {
    if title.is_empty() {
        return None;
    }
    let mut hits = names.iter().enumerate().filter(|(_, name)| name.as_str() == title);
    let (first, _) = hits.next()?;
    hits.next().is_none().then_some(first)
}

pub fn is_terminal_exe(path: &str) -> bool {
    path.rsplit(['\\', '/']).next().is_some_and(|name| name.eq_ignore_ascii_case("WindowsTerminal.exe"))
}

/// Selects the session's tab on a background thread; returns at once.
pub fn select_in_background(hwnd: i64, console_pid: u32) {
    if console_pid == 0 || !is_terminal_window(hwnd) {
        return;
    }
    let _ = std::thread::Builder::new().name("coucou-tab".into()).spawn(move || {
        let started = Instant::now();
        let selected = select(hwnd, console_pid, started + CAP);
        log::line(format!("terminal tab selected={selected:?} in {:?}", started.elapsed()));
    });
}

/// How the tab was recognised.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Via {
    Marker,
    Title,
}

/// How the tab of `console_pid`'s console in window `hwnd` was found, when it
/// was found and selected.
pub fn select(hwnd: i64, console_pid: u32, deadline: Instant) -> Option<Via> {
    let (selected, via) = with_tab(hwnd, console_pid, deadline, |tab| unsafe {
        tab.GetCurrentPatternAs::<IUIAutomationSelectionItemPattern>(UIA_SelectionItemPatternId)
            .and_then(|pattern| pattern.Select())
            .is_ok()
    })?;
    selected.then_some(via)
}

fn is_terminal_window(hwnd: i64) -> bool {
    let mut pid = 0u32;
    unsafe { GetWindowThreadProcessId(HWND(hwnd as isize as *mut _), Some(&mut pid)) };
    pid != 0 && image_path(pid).is_some_and(|path| is_terminal_exe(&path))
}

pub fn image_path(pid: u32) -> Option<String> {
    unsafe {
        let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let mut buf = vec![0u16; 1024];
        let mut len = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(handle, PROCESS_NAME_WIN32, PWSTR(buf.as_mut_ptr()), &mut len).is_ok();
        let _ = CloseHandle(handle);
        ok.then(|| String::from_utf16_lossy(&buf[..len as usize]))
    }
}

/// Finds the tab of `console_pid`'s console in window `hwnd` and hands it to
/// `act` once the console title is back to what it was.
fn with_tab<R>(
    hwnd: i64,
    console_pid: u32,
    deadline: Instant,
    act: impl FnOnce(&IUIAutomationElement) -> R,
) -> Option<(R, Via)> {
    let _com = Com::init();
    let uia = automation()?;
    let root = unsafe { uia.ElementFromHandle(HWND(hwnd as isize as *mut _)) }.ok()?;
    let condition = unsafe {
        uia.CreatePropertyCondition(UIA_ControlTypePropertyId, &VARIANT::from(UIA_TabItemControlTypeId.0))
    }
    .ok()?;
    let lock = CONSOLE.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let original = on_console(console_pid, hwnd, read_title)??;
    let marker = format!("coucou-tab-{:016x}", random());
    let mut found = None;
    {
        let mark = Marked { pid: console_pid, hwnd, original: &original, marker: &marker };
        if on_console(console_pid, hwnd, || set_title(&marker)) == Some(true) {
            let until = (Instant::now() + MARKER_WAIT).min(deadline);
            loop {
                let (tabs, names) = tabs(&root, &condition);
                if let Some(i) = marker_tab(&names, &marker) {
                    found = tabs.into_iter().nth(i).map(|tab| (tab, Via::Marker));
                    break;
                }
                if Instant::now() + POLL >= until {
                    break;
                }
                std::thread::sleep(POLL);
            }
        }
        drop(mark);
    }
    drop(lock);
    if found.is_none() && Instant::now() < deadline {
        let (tabs, names) = tabs(&root, &condition);
        found = unique_title_tab(&names, &original).and_then(|i| tabs.into_iter().nth(i)).map(|tab| (tab, Via::Title));
    }
    found.map(|(tab, via)| (act(&tab), via))
}

/// Puts the original title back when dropped, unless the program changed the
/// title in the meantime.
struct Marked<'a> {
    pid: u32,
    hwnd: i64,
    original: &'a str,
    marker: &'a str,
}

impl Drop for Marked<'_> {
    fn drop(&mut self) {
        let _ = on_console(self.pid, self.hwnd, || {
            if read_title().as_deref() == Some(self.marker) {
                set_title(self.original);
            }
        });
    }
}

struct Com(bool);

impl Com {
    fn init() -> Self {
        Self(unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }.is_ok())
    }
}

impl Drop for Com {
    fn drop(&mut self) {
        if self.0 {
            unsafe { CoUninitialize() };
        }
    }
}

fn automation() -> Option<IUIAutomation> {
    unsafe {
        if let Ok(uia) = CoCreateInstance::<_, IUIAutomation2>(&CUIAutomation8, None, CLSCTX_INPROC_SERVER) {
            let _ = uia.SetConnectionTimeout(500);
            let _ = uia.SetTransactionTimeout(500);
            return uia.cast().ok();
        }
        CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER).ok()
    }
}

fn tabs(root: &IUIAutomationElement, condition: &IUIAutomationCondition) -> (Vec<IUIAutomationElement>, Vec<String>) {
    let mut tabs = Vec::new();
    let mut names = Vec::new();
    unsafe {
        if let Ok(found) = root.FindAll(TreeScope_Descendants, condition) {
            for i in 0..found.Length().unwrap_or(0) {
                if let Ok(tab) = found.GetElement(i) {
                    names.push(tab.CurrentName().map(|name| name.to_string()).unwrap_or_default());
                    tabs.push(tab);
                }
            }
        }
    }
    (tabs, names)
}

unsafe extern "system" fn swallow_ctrl(_: u32) -> BOOL {
    BOOL(1)
}

/// Runs `f` attached to `pid`'s console, only if that console still belongs
/// to window `hwnd`; detaches again before returning. A Ctrl+C typed into the
/// tab meanwhile is swallowed instead of ending Coucou.
fn on_console<R>(pid: u32, hwnd: i64, f: impl FnOnce() -> R) -> Option<R> {
    unsafe {
        let std = [STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE].map(|id| (id, GetStdHandle(id)));
        let out = attached(pid, hwnd, f);
        for (id, handle) in std {
            if let Ok(handle) = handle {
                let _ = SetStdHandle(id, handle);
            }
        }
        out
    }
}

unsafe fn attached<R>(pid: u32, hwnd: i64, f: impl FnOnce() -> R) -> Option<R> {
    unsafe {
        let _ = FreeConsole();
        let _ = SetConsoleCtrlHandler(Some(swallow_ctrl), true);
        let mut out = None;
        if AttachConsole(pid).is_ok() {
            let console = GetConsoleWindow();
            if !console.is_invalid() && GetAncestor(console, GA_ROOTOWNER).0 as i64 == hwnd {
                out = Some(f());
            }
            let _ = FreeConsole();
        }
        let _ = SetConsoleCtrlHandler(Some(swallow_ctrl), false);
        out
    }
}

fn read_title() -> Option<String> {
    let mut buf = vec![0u16; 32 * 1024];
    let n = unsafe { GetConsoleTitleW(&mut buf) } as usize;
    (n > 0).then(|| String::from_utf16_lossy(&buf[..n.min(buf.len())]))
}

fn set_title(title: &str) -> bool {
    unsafe { SetConsoleTitleW(&HSTRING::from(title)) }.is_ok()
}

fn random() -> u64 {
    let mut hasher = std::collections::hash_map::RandomState::new().build_hasher();
    hasher.write_u128(std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_nanos());
    hasher.finish()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn the_marker_names_the_tab() {
        let tabs = names(&["kimi", "coucou-tab-00ff", "kimi"]);
        assert_eq!(marker_tab(&tabs, "coucou-tab-00ff"), Some(1));
        assert_eq!(marker_tab(&names(&["x - coucou-tab-1 - y"]), "coucou-tab-1"), Some(0));
        assert_eq!(marker_tab(&tabs, "coucou-tab-abcd"), None);
        assert_eq!(marker_tab(&tabs, ""), None);
    }

    #[test]
    fn a_unique_title_is_the_fallback() {
        let tabs = names(&["pwsh", "did you finish?", "/review"]);
        assert_eq!(unique_title_tab(&tabs, "did you finish?"), Some(1));
        assert_eq!(unique_title_tab(&tabs, "did you"), None);
        assert_eq!(unique_title_tab(&tabs, ""), None);
    }

    #[test]
    fn duplicate_titles_select_nothing() {
        let tabs = names(&["kimi", "pwsh", "kimi"]);
        assert_eq!(unique_title_tab(&tabs, "kimi"), None);
        assert_eq!(marker_tab(&tabs, "coucou-tab-1"), None);
    }

    #[test]
    fn only_windows_terminal_is_handled() {
        assert!(is_terminal_exe(r"C:\Program Files\WindowsApps\Microsoft.WindowsTerminal_1\WindowsTerminal.exe"));
        assert!(is_terminal_exe("windowsterminal.exe"));
        assert!(!is_terminal_exe(r"C:\Windows\System32\conhost.exe"));
        assert!(!is_terminal_exe(r"C:\x\NotWindowsTerminal.exe"));
    }

    #[test]
    fn nothing_happens_without_a_window_or_console() {
        assert_eq!(select(0x7fff_fff0, 4, Instant::now() + CAP), None);
        select_in_background(0x7fff_fff0, 4);
    }

    fn kimi_pids() -> Vec<u32> {
        let out = std::process::Command::new("tasklist")
            .args(["/FI", "IMAGENAME eq kimi.exe", "/FO", "CSV", "/NH"])
            .output()
            .unwrap();
        String::from_utf8_lossy(&out.stdout)
            .lines()
            .filter_map(|line| line.split("\",\"").nth(1)?.parse().ok())
            .collect()
    }

    fn console_root(pid: u32) -> Option<i64> {
        let _lock = CONSOLE.lock().unwrap();
        unsafe {
            let _ = FreeConsole();
            AttachConsole(pid).ok()?;
            let console = GetConsoleWindow();
            let root = (!console.is_invalid()).then(|| GetAncestor(console, GA_ROOTOWNER).0 as i64);
            let _ = FreeConsole();
            root
        }
    }

    fn title_of(pid: u32, hwnd: i64) -> Option<String> {
        let _lock = CONSOLE.lock().unwrap();
        on_console(pid, hwnd, read_title).flatten()
    }

    fn is_selected(tab: &IUIAutomationElement) -> bool {
        unsafe {
            tab.GetCurrentPatternAs::<IUIAutomationSelectionItemPattern>(UIA_SelectionItemPatternId)
                .and_then(|p| p.CurrentIsSelected())
                .is_ok_and(|b| b.as_bool())
        }
    }

    /// Live check against Kimi CLI tabs in one Windows Terminal window. Run with
    /// output redirected to a file (the test detaches its own console):
    /// `cargo test -p coucou tab::tests::live -- --ignored --nocapture > out.txt 2>&1`.
    #[test]
    #[ignore]
    fn live_selects_another_kimi_tab_and_back() {
        let _com = Com::init();
        let pids = kimi_pids();
        let roots: Vec<(u32, i64)> = pids.iter().filter_map(|&p| Some((p, console_root(p)?))).collect();
        println!("kimi consoles: {roots:?}");
        let hwnd = roots
            .iter()
            .map(|(_, h)| *h)
            .filter(|h| is_terminal_window(*h))
            .max_by_key(|h| roots.iter().filter(|(_, x)| x == h).count())
            .expect("a Windows Terminal window with kimi.exe tabs");
        let in_window: Vec<u32> = roots.iter().filter(|(_, h)| *h == hwnd).map(|(p, _)| *p).collect();
        let before: Vec<Option<String>> = in_window.iter().map(|&p| title_of(p, hwnd)).collect();
        println!("window {hwnd:#x} pids {in_window:?} titles {before:?}");

        let uia = automation().unwrap();
        let root = unsafe { uia.ElementFromHandle(HWND(hwnd as isize as *mut _)) }.unwrap();
        let condition = unsafe {
            uia.CreatePropertyCondition(UIA_ControlTypePropertyId, &VARIANT::from(UIA_TabItemControlTypeId.0))
        }
        .unwrap();
        let (tabs0, names0) = tabs(&root, &condition);
        let first = tabs0.iter().position(is_selected).expect("a selected tab");
        println!("tabs {names0:?}, selected #{first}");

        let deadline = || Instant::now() + CAP;
        let target = in_window
            .iter()
            .copied()
            .find(|&p| with_tab(hwnd, p, deadline(), is_selected).is_some_and(|(s, _)| !s))
            .expect("a kimi tab that is not selected");
        let started = Instant::now();
        let via = select(hwnd, target, deadline());
        println!("selected pid {target} via {via:?} in {:?}", started.elapsed());
        assert_eq!(via, Some(Via::Marker), "select pid {target} through the marker");
        std::thread::sleep(Duration::from_millis(300));
        assert_eq!(with_tab(hwnd, target, deadline(), is_selected), Some((true, Via::Marker)), "tab of pid {target} is selected");
        assert!(!is_selected(&tabs0[first]), "original tab is no longer selected");

        unsafe {
            tabs0[first]
                .GetCurrentPatternAs::<IUIAutomationSelectionItemPattern>(UIA_SelectionItemPatternId)
                .unwrap()
                .Select()
                .unwrap();
        }
        std::thread::sleep(Duration::from_millis(300));
        assert!(is_selected(&tabs0[first]), "original tab selected again");

        std::thread::sleep(Duration::from_millis(300));
        let after: Vec<Option<String>> = in_window.iter().map(|&p| title_of(p, hwnd)).collect();
        println!("titles after {after:?}");
        assert_eq!(before, after, "titles restored");
        assert!(after.iter().flatten().all(|t| !t.contains("coucou-tab-")));
        let (_, names1) = tabs(&root, &condition);
        println!("tabs after {names1:?}");
        assert!(names1.iter().all(|n| !n.contains("coucou-tab-")));
    }

    /// Live check for console pids reported by coucou-hook (any agent):
    /// `COUCOU_TAB_PIDS=1234,5678 cargo test -p coucou tab::tests::live_pids -- --ignored --nocapture > out.txt 2>&1`.
    /// Each pid's tab is selected from another selected tab, then the original
    /// tab is selected again and every title must be unchanged.
    #[test]
    #[ignore]
    fn live_pids_select_their_tabs_and_back() {
        let _com = Com::init();
        let pids: Vec<u32> = std::env::var("COUCOU_TAB_PIDS")
            .expect("COUCOU_TAB_PIDS")
            .split(',')
            .filter_map(|p| p.trim().parse().ok())
            .collect();
        let uia = automation().unwrap();
        let condition = unsafe {
            uia.CreatePropertyCondition(UIA_ControlTypePropertyId, &VARIANT::from(UIA_TabItemControlTypeId.0))
        }
        .unwrap();
        let deadline = || Instant::now() + CAP;
        for pid in pids {
            let hwnd = console_root(pid).expect("pid has a console");
            assert!(is_terminal_window(hwnd), "pid {pid} is in a Windows Terminal window");
            let root = unsafe { uia.ElementFromHandle(HWND(hwnd as isize as *mut _)) }.unwrap();
            let (tabs0, names0) = tabs(&root, &condition);
            let first = tabs0.iter().position(is_selected).expect("a selected tab");
            let title = title_of(pid, hwnd);
            assert_eq!(with_tab(hwnd, pid, deadline(), is_selected).map(|(s, _)| s), Some(false), "pid {pid} tab not selected yet");
            let started = Instant::now();
            let via = select(hwnd, pid, deadline());
            std::thread::sleep(Duration::from_millis(300));
            let now = with_tab(hwnd, pid, deadline(), is_selected);
            println!("pid {pid} window {hwnd:#x} title {title:?} via {via:?} in {:?} selected {now:?} (was #{first} of {})", started.elapsed(), names0.len());
            assert_eq!(via, Some(Via::Marker));
            assert_eq!(now, Some((true, Via::Marker)));
            assert!(!is_selected(&tabs0[first]));
            unsafe {
                tabs0[first]
                    .GetCurrentPatternAs::<IUIAutomationSelectionItemPattern>(UIA_SelectionItemPatternId)
                    .unwrap()
                    .Select()
                    .unwrap();
            }
            std::thread::sleep(Duration::from_millis(300));
            assert!(is_selected(&tabs0[first]), "original tab selected again");
            assert_eq!(title_of(pid, hwnd), title, "title restored");
            let (_, names1) = tabs(&root, &condition);
            assert!(names1.iter().all(|n| !n.contains("coucou-tab-")));
        }
    }
}
