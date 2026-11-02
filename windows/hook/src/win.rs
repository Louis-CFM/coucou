//! The little bit of Win32 the relay needs: who we are, and who is on the other
//! end of the pipe.
//!
//! Named pipes live in a machine-wide namespace, so `\\.\pipe\coucou-<name>` can
//! be created by *any* process that gets there first. Two defences, both cheap:
//! the pipe name carries our SID, and once connected we check the server process
//! really is us (our account, outside any AppContainer, at Medium integrity or
//! above) before sending anything. Below our own level (Claude Code started as
//! administrator, Coucou not) it may show the session, never answer for it.

use std::time::{Duration, Instant};

use windows::core::PWSTR;
use windows::Win32::Foundation::{CloseHandle, HANDLE, LocalFree, HLOCAL};
use windows::Win32::Security::Authorization::ConvertSidToStringSidW;
use windows::Win32::Security::{
    GetSidSubAuthority, GetSidSubAuthorityCount, GetTokenInformation, TokenIntegrityLevel, TokenIsAppContainer,
    TokenUser, TOKEN_INFORMATION_CLASS, TOKEN_MANDATORY_LABEL, TOKEN_QUERY, TOKEN_USER,
};
use windows::Win32::System::Pipes::GetNamedPipeServerProcessId;
use windows::Win32::System::Threading::{
    GetCurrentProcess, OpenProcess, OpenProcessToken, PROCESS_QUERY_LIMITED_INFORMATION,
};

use crate::{Trust, CONNECT_TIMEOUT};

/// `ERROR_PIPE_BUSY` — every instance is serving someone else right now. This is
/// the one error worth retrying: the server exists and a slot will free up.
const ERROR_PIPE_BUSY: i32 = 231;

/// `SECURITY_MANDATORY_MEDIUM_RID`: where a normally started Coucou runs.
const MEDIUM_INTEGRITY: u32 = 0x2000;

/// `\\.\pipe\coucou-<sid>`. The SID keeps two accounts on the same machine from
/// ever meeting on the same pipe; the name falls back to the user name only if
/// the SID cannot be read at all, which should not happen.
fn pipe_path() -> String {
    let key = current_user_sid()
        .unwrap_or_else(|| std::env::var("USERNAME").unwrap_or_else(|_| "user".into()));
    format!(r"\\.\pipe\coucou-{key}")
}

/// Opens the pipe, with how far its server may be trusted. Retries only while
/// the server is busy: any other error means there is nothing to talk to, and
/// waiting would only delay Claude Code.
pub fn connect() -> Option<(std::fs::File, Trust)> {
    use std::os::windows::io::AsRawHandle;
    let path = pipe_path();
    let deadline = Instant::now() + CONNECT_TIMEOUT;
    loop {
        match std::fs::OpenOptions::new().read(true).write(true).open(&path) {
            Ok(file) => {
                let handle = HANDLE(file.as_raw_handle());
                // Somebody else's server on our pipe name gets nothing from us.
                return pipe_server_trust(handle).map(|trust| (file, trust));
            }
            Err(err) => {
                if err.raw_os_error() != Some(ERROR_PIPE_BUSY) || Instant::now() >= deadline {
                    return None;
                }
                std::thread::sleep(Duration::from_millis(15));
            }
        }
    }
}

/// The SID of the account this process runs as, as `S-1-5-21-…`.
pub fn current_user_sid() -> Option<String> {
    unsafe { identity(GetCurrentProcess()) }.map(|me| me.sid)
}

/// What decides whether a process may hear our tool calls and answer them.
#[derive(Debug, PartialEq)]
struct Identity {
    sid: String,
    /// The mandatory integrity level's RID: 0x1000 Low, 0x2000 Medium, 0x3000 High.
    integrity: u32,
    app_container: bool,
}

/// How far the process serving `handle` may be trusted (see `trust`); None when
/// it is not us.
///
/// A failure to answer is treated as "not ours": refusing to talk to a pipe we
/// cannot vouch for costs one hook event, while trusting it could hand another
/// process the contents of every tool call and let it answer them.
pub fn pipe_server_trust(handle: HANDLE) -> Option<Trust> {
    let mine = unsafe { identity(GetCurrentProcess()) }?;
    unsafe {
        let mut pid = 0u32;
        if GetNamedPipeServerProcessId(handle, &mut pid).is_err() || pid == 0 {
            return None;
        }
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let theirs = identity(process);
        let _ = CloseHandle(process);
        trust(&mine, &theirs?)
    }
}

/// Our account is not enough: a Low-integrity or AppContainer process of that
/// account (a browser renderer, say) could create the pipe before Coucou does
/// and answer "allow" to every tool call. So: our account, outside any
/// AppContainer, at Medium integrity or above. At our level or above it may
/// answer; between Medium and our level it may only show the session
/// (`Display`): a Medium process of our account can already read an elevated
/// session's transcript in the user's profile, but it never answers for it.
fn trust(mine: &Identity, theirs: &Identity) -> Option<Trust> {
    if theirs.sid != mine.sid || theirs.app_container || theirs.integrity < MEDIUM_INTEGRITY {
        return None;
    }
    Some(if theirs.integrity >= mine.integrity { Trust::Full } else { Trust::Display })
}

/// The identity behind a process handle. `process` is borrowed, never closed.
unsafe fn identity(process: HANDLE) -> Option<Identity> {
    let mut token = HANDLE::default();
    OpenProcessToken(process, TOKEN_QUERY, &mut token).ok()?;
    let found = token_identity(token);
    let _ = CloseHandle(token);
    found
}

unsafe fn token_identity(token: HANDLE) -> Option<Identity> {
    let user_buf = token_info(token, TokenUser)?;
    let user = std::ptr::read_unaligned(user_buf.as_ptr() as *const TOKEN_USER);
    let mut text = PWSTR::null();
    ConvertSidToStringSidW(user.User.Sid, &mut text).ok()?;
    let sid = text.to_string().ok();
    let _ = LocalFree(Some(HLOCAL(text.0 as *mut _)));

    // The level is the last sub-authority of the label's SID, S-1-16-<level>.
    let label_buf = token_info(token, TokenIntegrityLevel)?;
    let label = std::ptr::read_unaligned(label_buf.as_ptr() as *const TOKEN_MANDATORY_LABEL);
    let count = *GetSidSubAuthorityCount(label.Label.Sid);
    let integrity = *GetSidSubAuthority(label.Label.Sid, u32::from(count.checked_sub(1)?));

    let (mut container, mut len) = (0u32, 0u32);
    GetTokenInformation(token, TokenIsAppContainer, Some((&mut container as *mut u32).cast()), 4, &mut len).ok()?;
    Some(Identity { sid: sid?, integrity, app_container: container != 0 })
}

/// One class of token information: the first call sizes the buffer, the second fills it.
unsafe fn token_info(token: HANDLE, class: TOKEN_INFORMATION_CLASS) -> Option<Vec<u8>> {
    let mut needed = 0u32;
    let _ = GetTokenInformation(token, class, None, 0, &mut needed);
    if needed == 0 {
        return None;
    }
    let mut buf = vec![0u8; needed as usize];
    GetTokenInformation(token, class, Some(buf.as_mut_ptr().cast()), needed, &mut needed).ok()?;
    Some(buf)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn our_own_unsandboxed_process_is_trusted_fully_at_our_level_and_for_display_from_medium_up() {
        let id = |sid: &str, integrity: u32, app_container: bool| Identity { sid: sid.into(), integrity, app_container };
        let (medium, high) = (id("S-1-5-21-1", 0x2000, false), id("S-1-5-21-1", 0x3000, false));
        let cases = [
            (&high, id("S-1-5-21-1", 0x2000, false), Some(Trust::Display), "Claude Code as administrator, Coucou started normally"),
            (&medium, id("S-1-5-21-1", 0x2000, false), Some(Trust::Full), "Coucou as we are"),
            (&high, id("S-1-5-21-1", 0x3000, false), Some(Trust::Full), "both as administrator"),
            (&medium, id("S-1-5-21-1", 0x3000, false), Some(Trust::Full), "an elevated Coucou"),
            (&medium, id("S-1-5-21-1", 0x1000, false), None, "our account at Low integrity"),
            (&high, id("S-1-5-21-1", 0x1000, false), None, "our account at Low integrity, we elevated"),
            (&medium, id("S-1-5-21-1", 0x2000, true), None, "our account inside an AppContainer"),
            (&high, id("S-1-5-21-1", 0x2000, true), None, "our account inside an AppContainer, we elevated"),
            (&medium, id("S-1-5-21-2", 0x2000, false), None, "another account"),
            (&high, id("S-1-5-21-2", 0x2000, false), None, "another account, we elevated"),
        ];
        for (mine, theirs, want, why) in cases {
            assert_eq!(trust(mine, &theirs), want, "{why}");
        }
    }

    #[test]
    fn our_own_process_reads_as_us() {
        let me = unsafe { identity(GetCurrentProcess()) }.expect("our own token is readable");
        assert!(me.sid.starts_with("S-1-5-"), "{}", me.sid);
        assert!(me.integrity >= 0x1000 && !me.app_container, "{me:?}");
        assert_eq!(trust(&me, &me), Some(Trust::Full));
    }
}
