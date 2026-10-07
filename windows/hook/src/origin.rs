//! Which top-level window started this agent session.
//!
//! The relay walks its own parent chain (relay → agent CLI → shell → terminal or
//! editor) and picks the first ancestor that owns a visible, unowned top-level
//! window. Desktop agent apps (ChatGPT/Codex, Kimi Code, Hermes, Claude) are
//! recognised by exe name: their main window is chosen even while hidden in the
//! tray or minimised. Codex CLI hooks run in a detached app-server daemon with no
//! window ancestry; for those the window of a running `codex` TUI (else the top
//! Windows Terminal window) is used. Only the window handle, its process id and,
//! when a console identified the window, the id of a process attached to that
//! console (so Coucou can pick the terminal tab) leave this module — never a
//! title. Every failure means "no origin": the event is forwarded without it.

use windows::core::BOOL;
use windows::Win32::Foundation::{CloseHandle, FILETIME, HWND, LPARAM, RECT};
use windows::Win32::System::Console::{GetConsoleProcessList, GetConsoleWindow};
use windows::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
    TH32CS_SNAPPROCESS,
};
use windows::Win32::System::Threading::{
    GetCurrentProcessId, GetProcessTimes, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetAncestor, GetWindow, GA_ROOTOWNER, GetWindowLongW, GetWindowRect, GetWindowTextW, GetWindowThreadProcessId,
    IsWindowVisible, GWL_EXSTYLE, GW_OWNER, WS_EX_TOOLWINDOW,
};

/// How far up the parent chain we look before giving up.
const MAX_DEPTH: usize = 12;

/// Ancestors that are never the session's window: the shell, system hosts,
/// and Coucou itself. Reaching one ends the search.
const STOP_EXES: &[&str] = &[
    "explorer.exe",
    "svchost.exe",
    "services.exe",
    "wininit.exe",
    "winlogon.exe",
    "csrss.exe",
    "sihost.exe",
    "runtimebroker.exe",
    "coucou.exe",
];

#[derive(Debug, Clone)]
pub struct Proc {
    pub pid: u32,
    pub parent: u32,
    pub exe: String,
}

#[derive(Debug, Clone, Default)]
pub struct Win {
    pub hwnd: i64,
    pub pid: u32,
    /// The title mentions the session's folder (computed locally, never sent).
    pub folder_match: bool,
    pub visible: bool,
    /// Lowercased title, used locally to recognise an app's main window.
    pub title: String,
    /// Window rectangle area in pixels (hidden windows keep their size).
    pub area: i64,
}

/// Desktop agent apps whose main window may be hidden (tray) or minimised, and
/// the title prefixes of that main window. `siblings`: when the ancestor itself
/// owns no such window, another process of the same exe may (Electron apps keep
/// one browser process; Claude is left out because `claude.exe` is also the
/// Claude Code CLI).
const APPS: &[(&str, &[&str], bool)] = &[
    ("chatgpt.exe", &["chatgpt", "codex"], true),
    ("kimi code.exe", &["kimi"], true),
    ("hermes.exe", &["hermes"], true),
    ("claude.exe", &["claude"], false),
];

fn app(exe: &str) -> Option<(&'static [&'static str], bool)> {
    let exe = exe.to_ascii_lowercase();
    APPS.iter().find(|(name, _, _)| *name == exe).map(|(_, titles, siblings)| (*titles, *siblings))
}

/// The main window of a desktop app among `candidates`: titled like the app,
/// visible first, then the largest.
fn app_window<'a>(candidates: impl Iterator<Item = &'a Win>, titles: &[&str]) -> Option<&'a Win> {
    candidates
        .filter(|w| titles.iter().any(|t| w.title.starts_with(t)))
        .max_by_key(|w| (w.visible, w.area))
}

/// The parent chain starting at `start`, nearest first. `born_before(parent,
/// child)` guards against a recycled parent pid: a "parent" created after its
/// child is someone else, and the chain stops there.
pub fn ancestors<'a>(
    start: u32,
    procs: &'a [Proc],
    born_before: impl Fn(u32, u32) -> bool,
) -> Vec<&'a Proc> {
    let mut chain: Vec<&Proc> = Vec::new();
    let mut pid = start;
    while chain.len() < MAX_DEPTH && pid > 4 {
        let Some(proc) = procs.iter().find(|p| p.pid == pid) else { break };
        if chain.iter().any(|seen| seen.pid == pid) {
            break;
        }
        if let Some(child) = chain.last() {
            if !born_before(pid, child.pid) {
                break;
            }
        }
        chain.push(proc);
        pid = proc.parent;
    }
    chain
}

/// The first ancestor owning a qualifying window wins. A desktop agent app
/// (see [`APPS`]) gives its main window even when hidden or minimised. Any
/// other process needs a visible window; among several (one VS Code or Windows
/// Terminal process can own many) a title naming the session folder beats
/// Z-order, otherwise the topmost is used.
pub fn select(chain: &[&Proc], procs: &[Proc], wins: &[Win]) -> Option<(i64, u32)> {
    for proc in chain {
        if STOP_EXES.contains(&proc.exe.to_ascii_lowercase().as_str()) {
            return None;
        }
        if let Some((titles, siblings)) = app(&proc.exe) {
            let same_exe = |pid: u32| {
                procs.iter().any(|p| p.pid == pid && p.exe.eq_ignore_ascii_case(&proc.exe))
            };
            let found = app_window(wins.iter().filter(|w| w.pid == proc.pid), titles).or_else(|| {
                siblings.then(|| app_window(wins.iter().filter(|w| same_exe(w.pid)), titles)).flatten()
            });
            if let Some(win) = found {
                return Some((win.hwnd, win.pid));
            }
            continue;
        }
        if let Some(win) = visible_window(proc.pid, wins) {
            return Some((win.hwnd, win.pid));
        }
    }
    None
}

fn visible_window(pid: u32, wins: &[Win]) -> Option<&Win> {
    let mut owned = wins.iter().filter(|w| w.pid == pid && w.visible);
    let first = owned.clone().next();
    owned.find(|w| w.folder_match).or(first)
}

/// Shells a `codex` TUI is typed into.
const SHELLS: &[&str] = &["pwsh.exe", "powershell.exe", "cmd.exe", "bash.exe", "nu.exe", "node.exe"];

/// Codex CLI hooks run in a detached `codex.exe app-server` daemon: there is
/// no window in the relay's ancestry. The session's window is the one hosting
/// a `codex` TUI (a `codex.exe` started from a shell); a TUI window whose title
/// names the session folder wins, otherwise the newest TUI. With no TUI
/// window, the topmost Windows Terminal window is the best guess. Never a
/// desktop app or an editor window reached through an app-server.
pub fn codex_cli_fallback(
    chain: &[&Proc],
    procs: &[Proc],
    wins: &[Win],
    born_before: impl Fn(u32, u32) -> bool,
    created: impl Fn(u32) -> Option<u64>,
) -> Option<(i64, u32)> {
    let is = |p: &Proc, exe: &str| p.exe.eq_ignore_ascii_case(exe);
    if !chain.iter().any(|p| is(p, "codex.exe")) {
        return None;
    }
    let mut best: Option<(bool, u64, &Win)> = None;
    for tui in procs.iter().filter(|p| is(p, "codex.exe") && !chain.iter().any(|c| c.pid == p.pid)) {
        let Some(parent) = procs.iter().find(|p| p.pid == tui.parent) else { continue };
        if !SHELLS.iter().any(|s| is(parent, s)) {
            continue;
        }
        let line = ancestors(tui.pid, procs, &born_before);
        if line.iter().any(|p| app(&p.exe).is_some()) {
            continue;
        }
        let Some(win) = line.iter().skip(1).find_map(|p| {
            if STOP_EXES.contains(&p.exe.to_ascii_lowercase().as_str()) {
                return Some(None);
            }
            visible_window(p.pid, wins).map(Some)
        }).flatten() else { continue };
        let rank = (win.folder_match, created(tui.pid).unwrap_or(0));
        if best.is_none_or(|(m, c, _)| rank > (m, c)) {
            best = Some((rank.0, rank.1, win));
        }
    }
    if let Some((_, _, win)) = best {
        return Some((win.hwnd, win.pid));
    }
    wins.iter()
        .filter(|w| w.visible)
        .find(|w| procs.iter().any(|p| p.pid == w.pid && is(p, "WindowsTerminal.exe")))
        .map(|w| (w.hwnd, w.pid))
}

/// The relay runs under Codex's shared `app-server` daemon: a `codex.exe`
/// whose parent is another `codex.exe` (the TUI that happened to start it) or
/// is gone. Its console belongs to that first TUI, not to the session's.
/// `codex exec` (parent: a shell) and the desktop app (parent: ChatGPT.exe)
/// are not daemons.
pub fn under_codex_daemon(chain: &[&Proc]) -> bool {
    let is_codex = |p: &&Proc| p.exe.eq_ignore_ascii_case("codex.exe");
    chain.iter().enumerate().skip(1).any(|(i, p)| {
        is_codex(p) && chain.get(i + 1).is_none_or(is_codex)
    })
}

/// The `codex` TUI (a `codex.exe` started from a shell, not inside a desktop
/// app) that most likely owns a daemon-run session: one whose working folder
/// is the session's `cwd`, then the newest. Several TUIs in the same folder
/// cannot be told apart; the newest wins.
pub fn codex_tui(
    procs: &[Proc],
    cwd: &str,
    born_before: impl Fn(u32, u32) -> bool,
    created: impl Fn(u32) -> Option<u64>,
    cwd_of: impl Fn(u32) -> Option<String>,
) -> Option<u32> {
    let is = |p: &Proc, exe: &str| p.exe.eq_ignore_ascii_case(exe);
    let want = normalize_dir(cwd);
    procs
        .iter()
        .filter(|tui| is(tui, "codex.exe"))
        .filter(|tui| {
            procs.iter().any(|p| p.pid == tui.parent && SHELLS.iter().any(|s| is(p, s)))
                && !ancestors(tui.pid, procs, &born_before).iter().any(|p| app(&p.exe).is_some())
        })
        .map(|tui| {
            let same_dir = !want.is_empty() && cwd_of(tui.pid).is_some_and(|d| normalize_dir(&d) == want);
            ((same_dir, created(tui.pid).unwrap_or(0)), tui.pid)
        })
        .max()
        .map(|(_, pid)| pid)
}

fn normalize_dir(dir: &str) -> String {
    dir.trim_start_matches(r"\\?\").replace('/', "\\").trim_end_matches('\\').to_lowercase()
}

/// Launchers that share a console only for a moment; another attached
/// ancestor (the agent CLI, the shell) outlives them.
const TRANSIENT_EXES: &[&str] = &["cmd.exe", "conhost.exe", "openconsole.exe"];

/// The process to report for a console: the nearest ancestor (the relay
/// itself excluded) among the processes `attached` to it, preferring one that
/// is not a short-lived launcher.
pub fn pick_console_process(chain: &[&Proc], attached: &[u32]) -> Option<u32> {
    let mut shared = chain.iter().skip(1).filter(|p| attached.contains(&p.pid));
    let first = shared.clone().next();
    shared
        .find(|p| !TRANSIENT_EXES.contains(&p.exe.to_ascii_lowercase().as_str()))
        .or(first)
        .map(|p| p.pid)
}

/// [`pick_console_process`] over the console this process is attached to now.
fn console_process(chain: &[&Proc]) -> Option<u32> {
    let mut list = [0u32; 256];
    let n = unsafe { GetConsoleProcessList(&mut list) } as usize;
    if n == 0 || n > list.len() {
        return None;
    }
    pick_console_process(chain, &list[..n])
}

/// `(hwnd, pid, console_pid)` of the window this relay was ultimately started
/// from; `console_pid` is set only when a console identified the window.
pub fn find(cwd: &str) -> Option<(i64, u32, Option<u32>)> {
    let procs = snapshot()?;
    let me = unsafe { GetCurrentProcessId() };
    let born_before = |parent: u32, child: u32| match (created(parent), created(child)) {
        (Some(p), Some(c)) => p <= c,
        _ => true,
    };
    let chain = ancestors(me, &procs, born_before);
    let folder = folder_name(cwd);
    let wins = windows(&folder);
    if let Some((hwnd, pid)) = console_window() {
        return Some((hwnd, pid, console_process(&chain)));
    }
    if under_codex_daemon(&chain) {
        if let Some(found) = codex_tui(&procs, cwd, born_before, created, process_cwd)
            .and_then(attached_console_window)
        {
            return Some(found);
        }
    }
    ancestor_console_window(&chain).or_else(|| {
        select(&chain, &procs, &wins)
            .or_else(|| codex_cli_fallback(&chain, &procs, &wins, born_before, created))
            .map(|(hwnd, pid)| (hwnd, pid, None))
    })
}

/// Diagnostic: with `COUCOU_ORIGIN_OUT` set, append the origin found and the
/// relay's process chain (exe names only) to that file.
pub fn trace(agent: &str, event: &str, found: Option<(i64, u32, Option<u32>)>) {
    use std::io::Write;
    let Some(path) = std::env::var_os("COUCOU_ORIGIN_OUT") else { return };
    let procs = snapshot().unwrap_or_default();
    let me = unsafe { GetCurrentProcessId() };
    let chain: Vec<String> = ancestors(me, &procs, |_, _| true)
        .iter()
        .map(|p| format!("{}:{}", p.exe, p.pid))
        .collect();
    let line = format!("agent={agent} event={event} origin={found:?} chain={}\n", chain.join(">"));
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = file.write_all(line.as_bytes());
    }
}

/// Tried before the walk. A classic console window belongs to conhost.exe,
/// which is the shell's child rather than an ancestor — so the walk cannot see
/// it — and one Windows Terminal process may own several windows, where the
/// console's owner names the right one. The console we
/// inherited is that window. Under a ConPTY host (Windows Terminal as the
/// default terminal) it is a pseudo window owned by the terminal's window, so
/// the root owner is what gets focused. A classic console is its own root.
fn console_window() -> Option<(i64, u32)> {
    unsafe {
        let console = GetConsoleWindow();
        if console.is_invalid() {
            return None;
        }
        let hwnd = GetAncestor(console, GA_ROOTOWNER);
        if hwnd.is_invalid() || !IsWindowVisible(hwnd).as_bool() {
            return None;
        }
        let mut pid = 0u32;
        GetWindowThreadProcessId(hwnd, Some(&mut pid));
        (pid != 0).then_some((hwnd.0 as i64, pid))
    }
}

/// Some agents (Kimi CLI) start hooks through `cmd /c` with no console, so
/// [`console_window`] finds nothing and the walk cannot see the terminal (the
/// shell's conhost/ConPTY is not an ancestor). The nearest ancestor that does
/// own a console still points at the right terminal window: attach to its
/// console just long enough to read the window, then detach. Stops at the
/// same processes as the walk; a desktop agent app without a console is left
/// to [`select`]. The console's process is the one attached to, or a
/// longer-lived ancestor sharing its console.
fn ancestor_console_window(chain: &[&Proc]) -> Option<(i64, u32, Option<u32>)> {
    use windows::Win32::System::Console::{AttachConsole, FreeConsole};
    unsafe {
        // Kimi starts hooks with CREATE_NO_WINDOW and Claude Code through a
        // hidden PowerShell: we sit on a hidden console of our own (no visible
        // terminal, or [`console_window`] would have found it), and
        // AttachConsole refuses while any console is attached. Our
        // stdin/stdout are pipes, so dropping it costs nothing.
        let _ = FreeConsole();
        for proc in chain.iter().skip(1) {
            let exe = proc.exe.to_ascii_lowercase();
            if STOP_EXES.contains(&exe.as_str()) {
                return None;
            }
            // `claude.exe` is both the desktop app and the Claude Code CLI:
            // only the CLI has a console.
            if AttachConsole(proc.pid).is_err() {
                if app(&exe).is_some() {
                    return None;
                }
                continue;
            }
            let found = console_window()
                .map(|(hwnd, pid)| (hwnd, pid, Some(console_process(chain).unwrap_or(proc.pid))));
            let _ = FreeConsole();
            if found.is_some() {
                return found;
            }
        }
        None
    }
}

/// The terminal window of `pid`'s console, with `pid` as its console process.
fn attached_console_window(pid: u32) -> Option<(i64, u32, Option<u32>)> {
    use windows::Win32::System::Console::{AttachConsole, FreeConsole};
    unsafe {
        let _ = FreeConsole();
        AttachConsole(pid).ok()?;
        let found = console_window().map(|(hwnd, wpid)| (hwnd, wpid, Some(pid)));
        let _ = FreeConsole();
        found
    }
}

/// The current directory of another process, read from its PEB
/// (`RTL_USER_PROCESS_PARAMETERS.CurrentDirectory`, 64-bit layout).
fn process_cwd(pid: u32) -> Option<String> {
    use windows::Wdk::System::Threading::{NtQueryInformationProcess, ProcessBasicInformation};
    use windows::Win32::System::Diagnostics::Debug::ReadProcessMemory;
    use windows::Win32::System::Threading::{PROCESS_QUERY_INFORMATION, PROCESS_VM_READ};
    #[repr(C)]
    #[derive(Default)]
    struct BasicInfo {
        exit_status: i32,
        peb: usize,
        rest: [usize; 4],
    }
    if cfg!(not(target_pointer_width = "64")) {
        return None;
    }
    unsafe {
        let process = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, false, pid).ok()?;
        let read = |at: usize, buf: &mut [u8]| {
            ReadProcessMemory(process, at as _, buf.as_mut_ptr() as _, buf.len(), None).is_ok()
        };
        let mut info = BasicInfo::default();
        let mut word = [0u8; 8];
        let mut text = vec![0u8; 0];
        let ok = NtQueryInformationProcess(
            process,
            ProcessBasicInformation,
            &mut info as *mut _ as _,
            std::mem::size_of::<BasicInfo>() as u32,
            std::ptr::null_mut(),
        )
        .is_ok()
            && read(info.peb + 0x20, &mut word)
            && {
                // CurrentDirectory.DosPath: UNICODE_STRING at +0x38.
                let params = usize::from_le_bytes(word);
                let mut header = [0u8; 16];
                read(params + 0x38, &mut header) && {
                    let len = u16::from_le_bytes([header[0], header[1]]) as usize;
                    let buffer = usize::from_le_bytes(header[8..16].try_into().unwrap());
                    text = vec![0u8; len.min(4096)];
                    read(buffer, &mut text)
                }
            };
        let _ = CloseHandle(process);
        let wide: Vec<u16> = text.chunks_exact(2).map(|c| u16::from_le_bytes([c[0], c[1]])).collect();
        (ok && !wide.is_empty()).then(|| String::from_utf16_lossy(&wide))
    }
}

fn folder_name(cwd: &str) -> String {
    cwd.trim_end_matches(['\\', '/'])
        .rsplit(['\\', '/'])
        .next()
        .unwrap_or("")
        .to_lowercase()
}

fn snapshot() -> Option<Vec<Proc>> {
    unsafe {
        let snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0).ok()?;
        let mut entry = PROCESSENTRY32W {
            dwSize: std::mem::size_of::<PROCESSENTRY32W>() as u32,
            ..Default::default()
        };
        let mut procs = Vec::new();
        let mut ok = Process32FirstW(snap, &mut entry).is_ok();
        while ok {
            let len = entry.szExeFile.iter().position(|c| *c == 0).unwrap_or(entry.szExeFile.len());
            procs.push(Proc {
                pid: entry.th32ProcessID,
                parent: entry.th32ParentProcessID,
                exe: String::from_utf16_lossy(&entry.szExeFile[..len]),
            });
            ok = Process32NextW(snap, &mut entry).is_ok();
        }
        let _ = CloseHandle(snap);
        Some(procs)
    }
}

fn created(pid: u32) -> Option<u64> {
    unsafe {
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let (mut c, mut e, mut k, mut u) =
            (FILETIME::default(), FILETIME::default(), FILETIME::default(), FILETIME::default());
        let ok = GetProcessTimes(process, &mut c, &mut e, &mut k, &mut u).is_ok();
        let _ = CloseHandle(process);
        ok.then_some(((c.dwHighDateTime as u64) << 32) | c.dwLowDateTime as u64)
    }
}

struct Collect {
    folder: String,
    wins: Vec<Win>,
}

/// Unowned, non-tool top-level windows in Z-order (topmost first), hidden ones
/// included and flagged: only desktop agent apps may be matched while hidden.
fn windows(folder: &str) -> Vec<Win> {
    let mut collect = Collect { folder: folder.to_string(), wins: Vec::new() };
    unsafe {
        let _ = EnumWindows(Some(visit), LPARAM(&mut collect as *mut Collect as isize));
    }
    collect.wins
}

unsafe extern "system" fn visit(hwnd: HWND, lparam: LPARAM) -> BOOL {
    let collect = &mut *(lparam.0 as *mut Collect);
    if GetWindow(hwnd, GW_OWNER).is_ok_and(|owner| !owner.is_invalid())
        || GetWindowLongW(hwnd, GWL_EXSTYLE) as u32 & WS_EX_TOOLWINDOW.0 != 0
    {
        return BOOL(1);
    }
    let mut pid = 0u32;
    GetWindowThreadProcessId(hwnd, Some(&mut pid));
    if pid == 0 {
        return BOOL(1);
    }
    let visible = IsWindowVisible(hwnd).as_bool();
    let mut buf = [0u16; 512];
    let n = GetWindowTextW(hwnd, &mut buf).max(0) as usize;
    let title = String::from_utf16_lossy(&buf[..n]).to_lowercase();
    if !visible && title.is_empty() {
        return BOOL(1);
    }
    let folder_match = !collect.folder.is_empty() && title.contains(&collect.folder);
    let mut rect = RECT::default();
    let area = if GetWindowRect(hwnd, &mut rect).is_ok() {
        (rect.right - rect.left).max(0) as i64 * (rect.bottom - rect.top).max(0) as i64
    } else {
        0
    };
    collect.wins.push(Win { hwnd: hwnd.0 as i64, pid, folder_match, visible, title, area });
    BOOL(1)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(pid: u32, parent: u32, exe: &str) -> Proc {
        Proc { pid, parent, exe: exe.into() }
    }
    fn w(hwnd: i64, pid: u32, folder_match: bool) -> Win {
        Win { hwnd, pid, folder_match, visible: true, ..Default::default() }
    }
    fn app_win(hwnd: i64, pid: u32, title: &str, visible: bool, area: i64) -> Win {
        Win { hwnd, pid, folder_match: false, visible, title: title.into(), area }
    }

    #[test]
    fn hidden_tray_desktop_app_window_is_chosen_by_exe() {
        // relay → cmd → Kimi Code.exe (main window hidden in the tray) → explorer.
        let procs = [
            p(100, 90, "coucou-hook.exe"),
            p(90, 80, "cmd.exe"),
            p(80, 60, "Kimi Code.exe"),
            p(60, 1, "explorer.exe"),
        ];
        let chain = ancestors(100, &procs, |_, _| true);
        let wins = [
            app_win(1, 80, "screenshot", false, 50),
            app_win(2, 80, "kimi code", false, 1_000_000),
            w(3, 60, false),
        ];
        assert_eq!(select(&chain, &procs, &wins), Some((2, 80)));
        // A hidden window of an ordinary process is never chosen.
        let procs = [p(100, 90, "coucou-hook.exe"), p(90, 1, "node.exe")];
        let chain = ancestors(100, &procs, |_, _| true);
        assert_eq!(select(&chain, &procs, &[app_win(4, 90, "x", false, 9)]), None);
    }

    #[test]
    fn desktop_app_prefers_visible_then_largest_and_checks_sibling_processes() {
        // relay → pwsh → codex.exe app-server → ChatGPT.exe renderer; the main
        // window belongs to the ChatGPT.exe browser process.
        let procs = [
            p(100, 90, "coucou-hook.exe"),
            p(90, 80, "pwsh.exe"),
            p(80, 70, "codex.exe"),
            p(70, 50, "ChatGPT.exe"),
            p(50, 1, "ChatGPT.exe"),
            p(40, 1, "Code.exe"),
        ];
        let chain = ancestors(100, &procs, |_, _| true);
        let wins = [
            w(9, 40, true),
            app_win(5, 50, "chatgpt", false, 10),
            app_win(6, 50, "chatgpt", true, 5),
            app_win(7, 50, "dde server window", false, 0),
        ];
        assert_eq!(select(&chain, &procs, &wins), Some((6, 50)));
        let wins = [app_win(5, 50, "chatgpt", false, 10), app_win(8, 50, "chatgpt", false, 99)];
        assert_eq!(select(&chain, &procs, &wins), Some((8, 50)));
        // Claude.exe is also the CLI name: no sibling search, only its own windows.
        let procs = [p(100, 90, "coucou-hook.exe"), p(90, 80, "claude.exe"), p(80, 1, "explorer.exe"), p(30, 1, "claude.exe")];
        let chain = ancestors(100, &procs, |_, _| true);
        assert_eq!(select(&chain, &procs, &[app_win(1, 30, "claude", true, 9)]), None);
        assert_eq!(select(&chain, &procs, &[app_win(2, 90, "claude", false, 9)]), Some((2, 90)));
    }

    #[test]
    fn codex_daemon_falls_back_to_the_terminal_running_the_codex_tui() {
        // Hook chain: relay → pwsh → codex.exe app-server daemon (parent gone).
        // TUIs: codex.exe 300 in WT window 21 (title names the folder) and a
        // newer one, 400, in WT window 22.
        let procs = [
            p(100, 90, "coucou-hook.exe"),
            p(90, 80, "pwsh.exe"),
            p(80, 5, "codex.exe"),
            p(300, 310, "codex.exe"),
            p(310, 320, "pwsh.exe"),
            p(320, 1, "WindowsTerminal.exe"),
            p(400, 410, "codex.exe"),
            p(410, 320, "powershell.exe"),
            p(500, 510, "codex.exe"),
            p(510, 520, "pwsh.exe"),
            p(520, 530, "codex.exe"),
            p(530, 1, "ChatGPT.exe"),
        ];
        let chain = ancestors(100, &procs, |_, _| true);
        assert_eq!(select(&chain, &procs, &[]), None);
        let created = |pid: u32| Some(pid as u64);
        let wins = [w(22, 320, false), w(21, 320, true), app_win(23, 530, "chatgpt", true, 9)];
        assert_eq!(codex_cli_fallback(&chain, &procs, &wins, |_, _| true, created), Some((21, 320)));
        // No folder match: the newest TUI's window (both share WT pid 320; the
        // newest TUI's terminal is the top WT window of that process).
        let wins = [w(22, 320, false)];
        assert_eq!(codex_cli_fallback(&chain, &procs, &wins, |_, _| true, created), Some((22, 320)));
        // No TUI at all: top Windows Terminal window; never ChatGPT or VS Code.
        let procs2 = [p(100, 90, "coucou-hook.exe"), p(90, 80, "pwsh.exe"), p(80, 5, "codex.exe"), p(320, 1, "WindowsTerminal.exe"), p(40, 1, "Code.exe")];
        let chain2 = ancestors(100, &procs2, |_, _| true);
        let wins = [w(9, 40, false), w(22, 320, false)];
        assert_eq!(codex_cli_fallback(&chain2, &procs2, &wins, |_, _| true, created), Some((22, 320)));
        assert_eq!(codex_cli_fallback(&chain2, &procs2, &[w(9, 40, false)], |_, _| true, created), None);
        // Not a Codex hook: no fallback.
        let procs3 = [p(100, 90, "coucou-hook.exe"), p(90, 1, "kimi.exe"), p(320, 1, "WindowsTerminal.exe")];
        let chain3 = ancestors(100, &procs3, |_, _| true);
        assert_eq!(codex_cli_fallback(&chain3, &procs3, &[w(22, 320, false)], |_, _| true, created), None);
    }

    #[test]
    fn codex_daemon_sessions_map_to_the_tui_in_the_session_folder() {
        // TUI 300 (in C:\A) started the shared daemon 80; TUI 400 runs in C:\B.
        let procs = [
            p(100, 90, "coucou-hook.exe"),
            p(90, 80, "powershell.exe"),
            p(80, 300, "codex.exe"),
            p(300, 310, "codex.exe"),
            p(310, 1, "cmd.exe"),
            p(400, 410, "codex.exe"),
            p(410, 1, "pwsh.exe"),
            p(500, 510, "codex.exe"),
            p(510, 520, "pwsh.exe"),
            p(520, 1, "ChatGPT.exe"),
        ];
        let chain = ancestors(100, &procs, |_, _| true);
        assert!(under_codex_daemon(&chain));
        let created = |pid: u32| Some(pid as u64);
        let dirs = |pid: u32| Some(if pid == 300 { r"C:\A\".to_string() } else { r"c:\b".to_string() });
        assert_eq!(codex_tui(&procs, r"C:\A", |_, _| true, created, dirs), Some(300));
        assert_eq!(codex_tui(&procs, "C:/B", |_, _| true, created, dirs), Some(400));
        assert_eq!(codex_tui(&procs, r"C:\Elsewhere", |_, _| true, created, dirs), Some(400));
        // `codex exec` from a shell and the desktop app's app-server are not the daemon.
        let exec = [p(100, 90, "coucou-hook.exe"), p(90, 80, "powershell.exe"), p(80, 70, "codex.exe"), p(70, 1, "cmd.exe")];
        assert!(!under_codex_daemon(&ancestors(100, &exec, |_, _| true)));
        let desktop = [p(100, 90, "coucou-hook.exe"), p(90, 80, "pwsh.exe"), p(80, 70, "codex.exe"), p(70, 1, "ChatGPT.exe")];
        assert!(!under_codex_daemon(&ancestors(100, &desktop, |_, _| true)));
        let orphan = [p(100, 90, "coucou-hook.exe"), p(90, 80, "pwsh.exe"), p(80, 5, "codex.exe")];
        assert!(under_codex_daemon(&ancestors(100, &orphan, |_, _| true)));
    }

    #[test]
    fn walks_up_to_the_first_ancestor_with_a_window() {
        let procs = [
            p(100, 90, "coucou-hook.exe"),
            p(90, 80, "node.exe"),
            p(80, 70, "bash.exe"),
            p(70, 60, "mintty.exe"),
            p(60, 50, "explorer.exe"),
        ];
        let chain = ancestors(100, &procs, |_, _| true);
        assert_eq!(chain.len(), 5);
        let wins = [w(11, 60, false), w(22, 70, false)];
        assert_eq!(select(&chain, &procs, &wins), Some((22, 70)));
    }

    #[test]
    fn vs_code_prefers_the_window_naming_the_session_folder() {
        let procs = [
            p(100, 90, "coucou-hook.exe"),
            p(90, 80, "pwsh.exe"),
            p(80, 70, "Code.exe"),
            p(70, 1, "Code.exe"),
        ];
        let chain = ancestors(100, &procs, |_, _| true);
        let wins = [w(1, 70, false), w(2, 70, true), w(3, 70, false)];
        assert_eq!(select(&chain, &procs, &wins), Some((2, 70)));
        let wins = [w(5, 70, false), w(6, 70, false)];
        assert_eq!(select(&chain, &procs, &wins), Some((5, 70)));
    }

    #[test]
    fn windows_terminal_hosts_the_console_session() {
        let procs = [
            p(100, 90, "coucou-hook.exe"),
            p(90, 80, "codex.exe"),
            p(80, 70, "pwsh.exe"),
            p(70, 60, "WindowsTerminal.exe"),
            p(60, 50, "explorer.exe"),
        ];
        let chain = ancestors(100, &procs, |_, _| true);
        assert_eq!(select(&chain, &procs, &[w(9, 70, false), w(8, 60, false)]), Some((9, 70)));
    }

    #[test]
    fn explorer_and_coucou_end_the_search_without_a_match() {
        let procs = [p(100, 90, "coucou-hook.exe"), p(90, 60, "node.exe"), p(60, 1, "explorer.exe")];
        let chain = ancestors(100, &procs, |_, _| true);
        assert_eq!(select(&chain, &procs, &[w(1, 60, false)]), None);
        let procs = [p(100, 90, "coucou-hook.exe"), p(90, 1, "Coucou.exe")];
        let chain = ancestors(100, &procs, |_, _| true);
        assert_eq!(select(&chain, &procs, &[w(1, 90, false)]), None);
    }

    #[test]
    fn recycled_parent_pids_and_cycles_end_the_chain() {
        let procs = [p(100, 90, "coucou-hook.exe"), p(90, 80, "node.exe"), p(80, 100, "term.exe")];
        assert_eq!(ancestors(100, &procs, |_, _| true).len(), 3);
        let chain = ancestors(100, &procs, |parent, _| parent != 80);
        assert_eq!(chain.len(), 2);
        assert_eq!(select(&chain, &procs, &[w(1, 80, false)]), None);
        let deep: Vec<Proc> = (10..40).map(|i| p(i, i + 1, "x.exe")).collect();
        assert_eq!(ancestors(10, &deep, |_, _| true).len(), MAX_DEPTH);
        assert!(ancestors(4, &deep, |_, _| true).is_empty());
    }

    #[test]
    fn console_process_is_the_nearest_lasting_ancestor_on_that_console() {
        // relay → cmd /c → kimi.exe → pwsh → WindowsTerminal; cmd, kimi and
        // pwsh share the tab's console.
        let procs = [
            p(100, 90, "coucou-hook.exe"),
            p(90, 80, "cmd.exe"),
            p(80, 70, "kimi.exe"),
            p(70, 60, "pwsh.exe"),
            p(60, 1, "WindowsTerminal.exe"),
        ];
        let chain = ancestors(100, &procs, |_, _| true);
        assert_eq!(pick_console_process(&chain, &[100, 90, 80, 70]), Some(80));
        assert_eq!(pick_console_process(&chain, &[70, 100]), Some(70));
        assert_eq!(pick_console_process(&chain, &[90, 100]), Some(90));
        assert_eq!(pick_console_process(&chain, &[100]), None);
        assert_eq!(pick_console_process(&chain, &[]), None);
    }

    #[test]
    fn folder_name_is_the_last_path_component() {
        assert_eq!(folder_name(r"C:\Work Space\Demo\"), "demo");
        assert_eq!(folder_name("/c/x/y"), "y");
        assert_eq!(folder_name(""), "");
    }

    /// Manual check: `cargo test -p coucou-hook origin_manual -- --ignored --nocapture`.
    #[test]
    #[ignore]
    fn origin_manual() {
        let started = std::time::Instant::now();
        let found = find(&std::env::current_dir().unwrap().to_string_lossy());
        let elapsed = started.elapsed();
        let procs = snapshot().unwrap();
        let me = unsafe { GetCurrentProcessId() };
        for p in ancestors(me, &procs, |_, _| true) {
            println!("chain pid={} exe={}", p.pid, p.exe);
        }
        for w in windows("").iter().filter(|w| found.is_some_and(|f| (f.0, f.1) == (w.hwnd, w.pid))) {
            println!("selected hwnd={:#x} pid={}", w.hwnd, w.pid);
        }
        unsafe {
            let console = GetConsoleWindow();
            let root = GetAncestor(console, GA_ROOTOWNER);
            let mut pid = 0u32;
            GetWindowThreadProcessId(root, Some(&mut pid));
            println!(
                "console={:#x} visible={} root_owner={:#x} visible={} pid={pid}",
                console.0 as i64,
                IsWindowVisible(console).as_bool(),
                root.0 as i64,
                IsWindowVisible(root).as_bool(),
            );
        }
        println!("origin={found:?} elapsed={elapsed:?}");
        if let Some(path) = std::env::var_os("COUCOU_ORIGIN_OUT") {
            let _ = std::fs::write(path, format!("origin={found:?} elapsed={elapsed:?}\n"));
        }
    }
}
