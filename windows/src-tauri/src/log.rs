// Small append-only log at %LOCALAPPDATA%\Coucou\coucou.log (Windows) or
// ~/.local/share/coucou/coucou.log (Linux) — the equivalent of nbLog() in
// HookServer.swift. Nothing leaves the machine.

use std::io::Write;
use std::path::Path;

use crate::{platform, settings};

/// Past this size the log becomes coucou.log.1 (replacing the one before).
const MAX_LOG: u64 = 1_000_000;

pub fn line(message: impl AsRef<str>) {
    let t = platform::local_time();
    let stamp = format!(
        "{:04}-{:02}-{:02} {:02}:{:02}:{:02}",
        t.year, t.month, t.day, t.hour, t.minute, t.second
    );
    let dir = settings::local_dir();
    if platform::ensure_private_dir(&dir).is_err() {
        return;
    }
    append(&dir.join("coucou.log"), &stamp, message.as_ref());
}

/// One line at the end of `path`. A full log rolls over to `<name>.1` rather
/// than being deleted: the lines leading up to a problem are the ones wanted.
fn append(path: &Path, stamp: &str, message: &str) {
    if std::fs::metadata(path).map(|m| m.len() > MAX_LOG).unwrap_or(false) {
        let _ = std::fs::rename(path, path.with_extension("log.1"));
    }
    let mut options = std::fs::OpenOptions::new();
    options.create(true).append(true);
    // Readable by us only, like the macOS log.
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    if let Ok(mut file) = options.open(path) {
        let _ = writeln!(file, "{stamp} {message}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_full_log_rolls_over_instead_of_vanishing() {
        let dir = std::env::temp_dir().join(format!("coucou-log-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("coucou.log");
        std::fs::write(&path, vec![b'x'; (MAX_LOG + 1) as usize]).unwrap();

        append(&path, "2026-10-11 10:00:00", "after the rollover");

        let old = std::fs::metadata(dir.join("coucou.log.1")).unwrap().len();
        assert_eq!(old, MAX_LOG + 1, "the previous megabyte is kept");
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.starts_with("2026-10-11 10:00:00 after the rollover"), "{text:?}");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
