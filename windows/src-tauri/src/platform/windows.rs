// Windows: Win32 for the island window and the cursor, %APPDATA% for files.

use std::collections::HashMap;
use std::os::windows::io::RawHandle;
use std::os::windows::process::CommandExt;
use std::path::PathBuf;
use std::process::Command;

use tauri::{AppHandle, Manager, WebviewWindow};

use ::windows::core::{BOOL, PWSTR};
use ::windows::Win32::Foundation::{CloseHandle, HANDLE, HLOCAL, HWND, LPARAM, LocalFree, POINT};
use ::windows::Win32::Security::Authorization::ConvertSidToStringSidW;
use ::windows::Win32::Security::{GetTokenInformation, TokenUser, TOKEN_QUERY, TOKEN_USER};
use ::windows::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W, TH32CS_SNAPPROCESS,
};
use ::windows::Win32::System::Ole::RevokeDragDrop;
use ::windows::Win32::System::Pipes::GetNamedPipeClientProcessId;
use ::windows::Win32::System::SystemInformation::GetLocalTime;
use ::windows::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};
use ::windows::Win32::UI::Input::KeyboardAndMouse::{
    GetAsyncKeyState, GetKeyboardLayoutList, MapVirtualKeyExW, ToUnicodeEx, HKL, MAPVK_VK_TO_VSC,
    VK_CONTROL, VK_LBUTTON, VK_MENU, VK_SHIFT,
};
use ::windows::Win32::UI::WindowsAndMessaging::{
    EnumChildWindows, EnumWindows, GetClassNameW, GetCursorPos, GetWindow, GetWindowLongPtrW,
    GetWindowTextW, GetWindowThreadProcessId, IsIconic, IsWindowVisible, SetForegroundWindow,
    SetWindowLongPtrW, ShowWindow, GWL_EXSTYLE, GW_OWNER, SW_RESTORE, WS_EX_NOACTIVATE,
    WS_EX_TOOLWINDOW,
};

use super::LocalTime;
use crate::session_window::{self, Proc};

/// File name of the Claude Code relay.
pub const HOOK_EXE: &str = "coucou-hook.exe";

/// Environment variable holding the home directory.
pub const HOME_VAR: &str = "USERPROFILE";

/// Keeps spawned helpers from flashing a console window.
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

// ── Files ─────────────────────────────────────────────────────────────────────

/// %APPDATA%\Coucou — preferences.
pub fn config_dir() -> PathBuf {
    let base = std::env::var_os("APPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    base.join("Coucou")
}

/// %LOCALAPPDATA%\Coucou — where coucou-hook.exe, the inbox and the log live.
pub fn local_dir() -> PathBuf {
    let base = std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    base.join("Coucou")
}

/// Where a saved image goes, best first: Pictures (also where OneDrive moves
/// it), then Downloads and the profile folder. The caller takes the first one
/// that exists. Read from the environment rather than the Known Folders API: a
/// relocated Pictures folder falls back to Downloads, which is fine for a PNG.
pub fn picture_dirs() -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    let home = std::env::var_os("USERPROFILE").map(PathBuf::from);
    if let Some(home) = &home {
        dirs.push(home.join("Pictures"));
    }
    if let Some(onedrive) = std::env::var_os("OneDrive").map(PathBuf::from) {
        dirs.push(onedrive.join("Pictures"));
    }
    if let Some(home) = home {
        dirs.push(home.join("Downloads"));
        dirs.push(home);
    }
    dirs
}

/// %APPDATA% and %LOCALAPPDATA% are already private to the user.
pub fn ensure_private_dir(dir: &std::path::Path) -> std::io::Result<()> {
    std::fs::create_dir_all(dir)
}

/// Environment the webview must inherit, set before any thread or process
/// starts: an intact WebView2 runtime when the registered one is broken
/// (webview2_fix.rs).
pub fn prepare_environment() {
    crate::webview2_fix::repair_runtime_path();
}

pub fn local_time() -> LocalTime {
    let t = unsafe { GetLocalTime() };
    LocalTime {
        year: t.wYear.into(),
        month: t.wMonth.into(),
        day: t.wDay.into(),
        hour: t.wHour.into(),
        minute: t.wMinute.into(),
        second: t.wSecond.into(),
    }
}

// ── Processes ─────────────────────────────────────────────────────────────────

/// Spawned helpers must never flash a console window.
pub fn no_console(cmd: &mut Command) -> &mut Command {
    // Nor inherit the WebView2 folder pinned for Coucou alone: every spawn goes
    // through here or through keep_out_of (webview2_fix.rs).
    crate::webview2_fix::keep_out_of(cmd).creation_flags(CREATE_NO_WINDOW)
}

pub fn open_url(url: &str) {
    let _ = no_console(Command::new("rundll32.exe").args(["url.dll,FileProtocolHandler", url]))
        .spawn();
}

pub fn reveal_folder(path: &str) {
    let _ = crate::webview2_fix::keep_out_of(&mut Command::new("explorer")).arg(path).spawn();
}

/// Our own `where`: walks %PATH% against %PATHEXT%, no shell involved.
/// Rust quotes arguments correctly for `.cmd`/`.bat` targets since 1.77, so
/// spawning `code.cmd` directly is safe.
pub fn find_on_path(stem: &str) -> Option<PathBuf> {
    let exts = std::env::var("PATHEXT").unwrap_or_else(|_| ".COM;.EXE;.BAT;.CMD".into());
    let dirs = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&dirs) {
        for ext in exts.split(';').filter(|e| !e.is_empty()) {
            let candidate = dir.join(format!("{stem}{}", ext.to_lowercase()));
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    None
}

/// Where the Codex CLI may be, best first: %PATH% (codex.exe or npm's
/// codex.cmd), then npm's global folder and the Volta / Bun / pnpm ones.
/// Rust quotes the one fixed argument safely for a `.cmd` (see find_on_path).
pub fn codex_candidates() -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = find_on_path("codex").into_iter().collect();
    let var = |k: &str| std::env::var_os(k).map(PathBuf::from).filter(|p| p.is_absolute());
    if let Some(appdata) = var("APPDATA") {
        out.push(appdata.join("npm").join("codex.cmd"));
    }
    if let Some(local) = var("LOCALAPPDATA") {
        out.push(local.join("Volta").join("bin").join("codex.exe"));
        out.push(local.join("pnpm").join("codex.cmd"));
    }
    if let Some(home) = var("USERPROFILE") {
        out.push(home.join(".bun").join("bin").join("codex.exe"));
        out.push(home.join(".local").join("bin").join("codex.exe"));
    }
    out.retain(|p| p.is_file());
    out
}

// ── Who we are ────────────────────────────────────────────────────────────────
//
// Named pipes share one machine-wide namespace, so the SID in the name is what
// keeps two accounts on the same machine from ever meeting on `coucou-*`.
// coucou-hook computes the same string (hook/src/win.rs) and additionally checks
// that the process serving the pipe really is us.

/// The SID of the account this process runs as, as `S-1-5-21-…`.
pub fn current_user_sid() -> Option<String> {
    unsafe {
        let mut token = HANDLE::default();
        OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token).ok()?;

        // First call sizes the buffer, second fills it.
        let mut needed = 0u32;
        let _ = GetTokenInformation(token, TokenUser, None, 0, &mut needed);
        if needed == 0 {
            let _ = CloseHandle(token);
            return None;
        }
        let mut buf = vec![0u8; needed as usize];
        let ok = GetTokenInformation(
            token,
            TokenUser,
            Some(buf.as_mut_ptr().cast()),
            needed,
            &mut needed,
        )
        .is_ok();
        let _ = CloseHandle(token);
        if !ok {
            return None;
        }

        let user = &*(buf.as_ptr() as *const TOKEN_USER);
        let mut text = PWSTR::null();
        ConvertSidToStringSidW(user.User.Sid, &mut text).ok()?;
        let sid = text.to_string().ok();
        let _ = LocalFree(Some(HLOCAL(text.0 as *mut _)));
        sid
    }
}

// The display name only feeds Mochi's greeting (identity.rs). The calls are
// declared here by hand, with their documented C signatures, so they need no
// extra `windows` crate features.
#[link(name = "secur32")]
extern "system" {
    fn GetUserNameExW(name_format: i32, name_buffer: *mut u16, size: *mut u32) -> u8;
}

#[link(name = "netapi32")]
extern "system" {
    fn NetUserGetInfo(server: *const u16, user: *const u16, level: u32, buffer: *mut *mut u8) -> u32;
    fn NetApiBufferFree(buffer: *mut core::ffi::c_void) -> u32;
}

/// EXTENDED_NAME_FORMAT::NameDisplay.
const NAME_DISPLAY: i32 = 3;

/// The account's display name ("Louis Raille"): the directory's for a domain
/// or Entra account, else the local account's "Full name", else nothing.
pub fn user_full_name() -> Option<String> {
    directory_display_name().or_else(local_full_name).filter(|n| !n.trim().is_empty())
}

fn directory_display_name() -> Option<String> {
    let mut buf = [0u16; 256];
    let mut size = buf.len() as u32;
    // On success `size` is the length copied, without the terminating null.
    let ok = unsafe { GetUserNameExW(NAME_DISPLAY, buf.as_mut_ptr(), &mut size) } != 0;
    if !ok || size as usize > buf.len() {
        return None;
    }
    String::from_utf16(&buf[..size as usize]).ok()
}

fn local_full_name() -> Option<String> {
    let user = std::env::var("USERNAME").ok().filter(|u| !u.is_empty())?;
    let wide: Vec<u16> = user.encode_utf16().chain(std::iter::once(0)).collect();
    let mut info: *mut u8 = std::ptr::null_mut();
    // Level 10 is USER_INFO_10 { name, comment, usr_comment, full_name }, four
    // wide-string pointers; any user may read it about themselves.
    let status = unsafe { NetUserGetInfo(std::ptr::null(), wide.as_ptr(), 10, &mut info) };
    if status != 0 || info.is_null() {
        return None;
    }
    unsafe {
        let full = *(info as *const *const u16).add(3);
        let text = if full.is_null() {
            None
        } else {
            let mut len = 0usize;
            while len < 256 && *full.add(len) != 0 {
                len += 1;
            }
            String::from_utf16(std::slice::from_raw_parts(full, len)).ok()
        };
        NetApiBufferFree(info.cast());
        text
    }
}

// ── Cursor ────────────────────────────────────────────────────────────────────

/// The 60 Hz poll reads the cursor and flips click-through from it.
pub const CURSOR_POLL: bool = true;

/// Cursor position in physical screen pixels.
pub fn cursor_physical() -> Option<(f64, f64)> {
    let mut p = POINT::default();
    unsafe { GetCursorPos(&mut p).ok()? };
    Some((p.x as f64, p.y as f64))
}

/// True while the left mouse button is held — the only signal we get that a
/// drag might be in flight before it reaches the window.
pub fn left_button_down() -> bool {
    unsafe { (GetAsyncKeyState(VK_LBUTTON.0 as i32) as u16 & 0x8000) != 0 }
}

// ── Island window ─────────────────────────────────────────────────────────────

fn hwnd_of(win: &WebviewWindow) -> Option<HWND> {
    let raw = win.hwnd().ok()?.0 as isize;
    if raw == 0 {
        return None;
    }
    Some(HWND(raw as *mut _))
}

/// Keeps the settings window from showing the "no drop" cursor.
///
/// wry installs its drop target by walking the webview's child windows **once**,
/// when the webview is created. WebView2 creates `Chrome_RenderWidgetHostHWND`
/// later and registers its own target on it; being the innermost window, that one
/// wins, and since the page has no HTML5 drop handler it refuses everything.
/// Revoking it makes OLE fall through to wry's target. The island is the other
/// way round: it takes drops through WebView2's own target (see webview_drop.rs),
/// so its windows are left alone.
///
/// Cheap and idempotent, so it is simply re-run whenever a drag might be starting.
pub fn unblock_webview_drops(app: &AppHandle) {
    let Some(win) = app.get_webview_window("settings") else { return };
    let Some(hwnd) = hwnd_of(&win) else { return };
    unsafe {
        let _ = EnumChildWindows(Some(hwnd), Some(revoke_render_widget), LPARAM(0));
    }
}

unsafe extern "system" fn revoke_render_widget(hwnd: HWND, _: LPARAM) -> BOOL {
    let mut name = [0u16; 64];
    let len = unsafe { GetClassNameW(hwnd, &mut name) };
    if len > 0 {
        let class = String::from_utf16_lossy(&name[..len as usize]);
        if class == "Chrome_RenderWidgetHostHWND" {
            let _ = unsafe { RevokeDragDrop(hwnd) };
        }
    }
    true.into()
}

/// WS_EX_NOACTIVATE keeps clicks from stealing focus; WS_EX_TOOLWINDOW keeps the
/// island out of Alt-Tab.
pub fn make_non_activating(win: &WebviewWindow) {
    let Some(hwnd) = hwnd_of(win) else { return };
    unsafe {
        let ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        let want = ex | WS_EX_NOACTIVATE.0 as isize | WS_EX_TOOLWINDOW.0 as isize;
        SetWindowLongPtrW(hwnd, GWL_EXSTYLE, want);
    }
}

/// Temporarily allow activation so a text field inside the island can be typed in.
pub fn set_activating(win: &WebviewWindow, activating: bool) {
    let Some(hwnd) = hwnd_of(win) else { return };
    unsafe {
        let ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        let want = if activating {
            ex & !(WS_EX_NOACTIVATE.0 as isize)
        } else {
            ex | WS_EX_NOACTIVATE.0 as isize
        };
        SetWindowLongPtrW(hwnd, GWL_EXSTYLE, want);
    }
}

/// Click-through here is the poll's WS_EX_TRANSPARENT toggle, not a region.
pub fn set_input_region(_win: &WebviewWindow, _rect: Option<(f64, f64, f64, f64)>) {}

/// The cursor poll already parks itself with the island (island.rs): nothing to do.
pub fn set_pointer_watch(_active: bool) {}

/// `set_position` already places a Win32 window on the right display.
pub fn pin_to_monitor(_win: &WebviewWindow, _x: i32, _y: i32) {}

// ── Session windows ("Open terminal") ─────────────────────────────────────────
//
// See session_window.rs: the relay's ancestors lead to the terminal or editor
// window a Claude Code session runs in.

/// The process on the other end of a relay connection.
pub fn pipe_client_pid(handle: RawHandle) -> Option<u32> {
    let mut pid = 0u32;
    unsafe { GetNamedPipeClientProcessId(HANDLE(handle), &mut pid).ok()? };
    (pid != 0).then_some(pid)
}

/// Every process, by ID: its parent and its executable's name.
fn process_table() -> HashMap<u32, Proc> {
    let mut out = HashMap::new();
    unsafe {
        let Ok(snapshot) = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) else { return out };
        let mut entry = PROCESSENTRY32W {
            dwSize: std::mem::size_of::<PROCESSENTRY32W>() as u32,
            ..Default::default()
        };
        let mut more = Process32FirstW(snapshot, &mut entry).is_ok();
        while more {
            let len = entry.szExeFile.iter().position(|c| *c == 0).unwrap_or(entry.szExeFile.len());
            out.insert(
                entry.th32ProcessID,
                Proc {
                    parent: entry.th32ParentProcessID,
                    exe: String::from_utf16_lossy(&entry.szExeFile[..len]),
                },
            );
            more = Process32NextW(snapshot, &mut entry).is_ok();
        }
        let _ = CloseHandle(snapshot);
    }
    out
}

/// The ancestors of a process, nearest first, below the desktop shell.
pub fn process_ancestors(pid: u32) -> Vec<u32> {
    session_window::ancestors(&process_table(), pid)
}

/// Visible top-level windows that are nobody's dialog and have a title:
/// (handle, process ID, title).
fn top_windows() -> Vec<(isize, u32, String)> {
    unsafe extern "system" fn collect(hwnd: HWND, lparam: LPARAM) -> BOOL {
        let list = unsafe { &mut *(lparam.0 as *mut Vec<(isize, u32, String)>) };
        unsafe {
            if !IsWindowVisible(hwnd).as_bool() || GetWindow(hwnd, GW_OWNER).is_ok() {
                return true.into();
            }
            let mut pid = 0u32;
            GetWindowThreadProcessId(hwnd, Some(&mut pid as *mut u32));
            let mut text = [0u16; 512];
            let len = GetWindowTextW(hwnd, &mut text);
            if len > 0 {
                list.push((hwnd.0 as isize, pid, String::from_utf16_lossy(&text[..len as usize])));
            }
        }
        true.into()
    }
    let mut list: Vec<(isize, u32, String)> = Vec::new();
    unsafe {
        let _ = EnumWindows(Some(collect), LPARAM(&mut list as *mut _ as isize));
    }
    list
}

/// The first of `pids` that owns a window.
pub fn first_with_window(pids: &[u32]) -> Option<u32> {
    let windows = top_windows();
    pids.iter().copied().find(|pid| windows.iter().any(|(_, owner, _)| owner == pid))
}

/// What a session remembers: the ancestor that owns a window, or nothing.
pub fn window_owners(ancestors: &[u32]) -> Vec<u32> {
    first_with_window(ancestors).into_iter().collect()
}

fn bring_forward(raw: isize) -> bool {
    let hwnd = HWND(raw as *mut _);
    unsafe {
        if IsIconic(hwnd).as_bool() {
            let _ = ShowWindow(hwnd, SW_RESTORE);
        }
        // Allowed: the click on the island that asked for this was the last input.
        SetForegroundWindow(hwnd).as_bool()
    }
}

/// Brings `pid`'s window forward — the one titled after `folder` if there are several.
pub fn focus_process_window(pid: u32, folder: &str) -> bool {
    let candidates: Vec<(isize, String)> = top_windows()
        .into_iter()
        .filter(|(_, owner, _)| *owner == pid)
        .map(|(hwnd, _, title)| (hwnd, title))
        .collect();
    session_window::pick_window(&candidates, folder).is_some_and(|hwnd| bring_forward(*hwnd))
}

/// Brings forward the window a session remembered (`window_owners`).
pub fn focus_session_window(owners: &[u32], folder: &str) -> bool {
    owners.first().is_some_and(|pid| focus_process_window(*pid, folder))
}

/// Brings forward the window of a running app, by executable name.
fn focus_app(exe: &str) -> bool {
    let pids: Vec<u32> = process_table()
        .into_iter()
        .filter(|(_, p)| p.exe.eq_ignore_ascii_case(exe))
        .map(|(pid, _)| pid)
        .collect();
    top_windows()
        .into_iter()
        .find(|(_, owner, _)| pids.contains(owner))
        .is_some_and(|(hwnd, _, _)| bring_forward(hwnd))
}

/// The Claude desktop app: brought forward when it runs (Claude Code's own
/// `claude.exe` has no window of its own, so it is never the one picked),
/// started from where its installer puts it otherwise.
pub fn open_claude_desktop() -> bool {
    if focus_app("claude.exe") {
        return true;
    }
    let Some(base) = std::env::var_os("LOCALAPPDATA") else { return false };
    let exe = PathBuf::from(base).join("AnthropicClaude").join("claude.exe");
    exe.is_file() && crate::webview2_fix::keep_out_of(&mut Command::new(exe)).spawn().is_ok()
}

// ── Global shortcuts ──────────────────────────────────────────────────────────

/// RegisterHotKey works in every Windows session.
pub fn global_shortcuts_blocked() -> Option<&'static str> {
    None
}

/// The character Ctrl+Alt(+Shift)+`vk` types on one of the installed keyboard
/// layouts, if any. Windows reads Ctrl+Alt as AltGr, so registering such a
/// combination as a global shortcut would stop the user typing that character
/// (AltGr+E is € on most European layouts, AltGr+A is ą in Polish).
pub fn ctrl_alt_types(vk: u16, shift: bool) -> Option<String> {
    let mut layouts = [HKL::default(); 32];
    let count = unsafe { GetKeyboardLayoutList(Some(&mut layouts[..])) };
    let count = usize::try_from(count).unwrap_or(0).min(layouts.len());

    let mut state = [0u8; 256];
    state[VK_CONTROL.0 as usize] = 0x80;
    state[VK_MENU.0 as usize] = 0x80;
    if shift {
        state[VK_SHIFT.0 as usize] = 0x80;
    }
    for &layout in &layouts[..count] {
        let scan = unsafe { MapVirtualKeyExW(u32::from(vk), MAPVK_VK_TO_VSC, Some(layout)) };
        let mut buf = [0u16; 8];
        // Flag 0x4: leave the keyboard state alone, so a dead key met here
        // doesn't change what the user types next (Windows 10 1607 and later).
        let n = unsafe { ToUnicodeEx(u32::from(vk), scan, &state, &mut buf, 0x4, Some(layout)) };
        let typed = match n {
            // A dead key (´ ^ ¨…) is still something the user types with it.
            n if n < 0 => String::from_utf16_lossy(&buf[..1]),
            0 => continue,
            n => String::from_utf16_lossy(&buf[..(n as usize).min(buf.len())]),
        };
        if typed.chars().any(|c| !c.is_control()) {
            return Some(typed);
        }
    }
    None
}

// ── Desktop Mochi window ──────────────────────────────────────────────────────

/// Windows places a window wherever it is asked, and the cursor poll is there.
pub fn desktop_mode() -> super::DesktopMode {
    super::DesktopMode::Poll
}

/// Same window styles as the island: never takes focus, never in Alt-Tab (it
/// is created without a taskbar button).
pub fn prepare_desktop_window(win: &WebviewWindow, _mode: super::DesktopMode) -> bool {
    make_non_activating(win);
    true
}

/// The cursor poll toggles WS_EX_TRANSPARENT from the body hit test instead.
pub fn set_desktop_shape(_win: &WebviewWindow, _shape: super::MouseShape) {}

/// Layer-shell only (Linux).
pub fn set_layer_margins(_win: &WebviewWindow, _x: f64, _y: f64) {}

/// Layer-shell only (Linux).
pub fn set_layer_overlay(_win: &WebviewWindow, _on: bool) {}

/// Layer-shell only (Linux): the logical size of the display the island is on.
pub fn layer_display(_island: &WebviewWindow, _mochi: &WebviewWindow) -> Option<(f64, f64)> {
    None
}
