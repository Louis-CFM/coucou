// Small append-only log at %LOCALAPPDATA%\Coucou\coucou.log on Windows and
// ~/.local/share/coucou/coucou.log on Linux — the equivalent of nbLog() in
// HookServer.swift. Nothing leaves the machine.

use std::io::Write;

use crate::{clock, settings};

pub fn line(message: impl AsRef<str>) {
    let (y, mo, d, h, mi, s) = clock::local_now();
    let stamp = format!("{y:04}-{mo:02}-{d:02} {h:02}:{mi:02}:{s:02}");
    let dir = settings::local_dir();
    if std::fs::create_dir_all(&dir).is_err() {
        return;
    }
    let path = dir.join("coucou.log");
    // Keep it from growing forever: start fresh past ~1 MB.
    if std::fs::metadata(&path).map(|m| m.len() > 1_000_000).unwrap_or(false) {
        let _ = std::fs::remove_file(&path);
    }
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(file, "{stamp} {}", message.as_ref());
    }
}
