//! The little bit of Win32 the relay needs: who we are, and who is on the other
//! end of the pipe.
//!
//! Named pipes live in a machine-wide namespace, so `\\.\pipe\coucou-<name>` can
//! be created by *any* account that gets there first. Two defences, both cheap:
//! the pipe name carries our SID, and once connected we check the server process
//! really belongs to us before sending anything.

use windows::core::PWSTR;
use windows::Win32::Foundation::{CloseHandle, HANDLE, LocalFree, HLOCAL};
use windows::Win32::Security::Authorization::ConvertSidToStringSidW;
use windows::Win32::Security::{GetTokenInformation, TokenUser, TOKEN_QUERY, TOKEN_USER};
use windows::Win32::System::Pipes::GetNamedPipeServerProcessId;
use windows::Win32::System::Threading::{
    GetCurrentProcess, OpenProcess, OpenProcessToken, PROCESS_QUERY_LIMITED_INFORMATION,
};

/// The SID of the account this process runs as, as `S-1-5-21-…`.
pub fn current_user_sid() -> Option<String> {
    unsafe { token_sid(GetCurrentProcess()) }
}

/// True when the process serving `handle` runs as the same user we do.
///
/// A failure to answer is treated as "not ours": refusing to talk to a pipe we
/// cannot vouch for costs one hook event, while trusting it could hand another
/// account on this machine the contents of every tool call.
pub fn pipe_server_is_same_user(handle: HANDLE) -> bool {
    let Some(mine) = current_user_sid() else { return false };
    unsafe {
        let mut pid = 0u32;
        if GetNamedPipeServerProcessId(handle, &mut pid).is_err() || pid == 0 {
            return false;
        }
        let Ok(process) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else {
            return false;
        };
        let theirs = token_sid(process);
        let _ = CloseHandle(process);
        theirs.as_deref() == Some(mine.as_str())
    }
}

/// The user SID behind a process handle. `process` is borrowed, never closed.
unsafe fn token_sid(process: HANDLE) -> Option<String> {
    let mut token = HANDLE::default();
    OpenProcessToken(process, TOKEN_QUERY, &mut token).ok()?;

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
