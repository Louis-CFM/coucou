//! The Linux side of the relay: where the socket is, and who is on the other end.
//!
//! `$XDG_RUNTIME_DIR` is private to the user (mode 0700), which already keeps
//! other accounts out. We still check the uid of the process serving the socket
//! before sending anything, the same promise the Windows build keeps with SIDs.

use std::os::unix::io::AsRawFd;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;

/// `$XDG_RUNTIME_DIR/coucou.sock`, or `/tmp/coucou-<uid>.sock` when there is no
/// runtime dir. Coucou computes the same path (src-tauri/src/pipe.rs).
pub fn socket_path() -> PathBuf {
    match std::env::var_os("XDG_RUNTIME_DIR").filter(|d| !d.is_empty()) {
        Some(dir) => PathBuf::from(dir).join("coucou.sock"),
        None => std::env::temp_dir().join(format!("coucou-{}.sock", unsafe { libc::getuid() })),
    }
}

/// Connects to Coucou. A missing socket or a refused connection means the app is
/// closed: we give up at once rather than delay Claude Code.
pub fn connect() -> Option<UnixStream> {
    let stream = UnixStream::connect(socket_path()).ok()?;
    // Somebody else's server on our socket gets nothing from us.
    (peer_uid(&stream)? == unsafe { libc::getuid() }).then_some(stream)
}

/// The uid of the process on the other end, from the kernel (SO_PEERCRED).
fn peer_uid(stream: &UnixStream) -> Option<u32> {
    let mut cred = libc::ucred { pid: 0, uid: 0, gid: 0 };
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    let rc = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut cred as *mut libc::ucred).cast(),
            &mut len,
        )
    };
    (rc == 0).then_some(cred.uid)
}
