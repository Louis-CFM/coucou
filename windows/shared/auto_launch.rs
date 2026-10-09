//! Windows files shared by the app and its relay; never read paths from hook input.

use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::windows::fs::OpenOptionsExt;
use std::path::{Component, Path, PathBuf};

use serde_json::Value;

pub const LAUNCH_ARG: &str = "--agent-auto-launch";
pub const SHARING_VIOLATION: i32 = 32;

/// Local process diagnostics only: no hook payloads, prompts, session IDs or keys.
pub fn diagnostic(message: impl AsRef<str>) {
    let Some(dir) = local_dir() else {
        return;
    };
    let path = dir.join("auto-launch.log");
    if std::fs::metadata(&path).is_ok_and(|m| m.len() > 1_000_000) {
        let _ = std::fs::remove_file(&path);
    }
    let millis = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(
            file,
            "unix_ms={millis} pid={} {}",
            std::process::id(),
            message.as_ref()
        );
    }
}

pub fn local_dir() -> Option<PathBuf> {
    let path = PathBuf::from(std::env::var_os("LOCALAPPDATA")?);
    path.is_absolute().then(|| path.join("Coucou"))
}

pub fn settings_path() -> Option<PathBuf> {
    let path = PathBuf::from(std::env::var_os("APPDATA")?);
    path.is_absolute()
        .then(|| path.join("Coucou/settings.json"))
}

pub fn lock(path: &Path) -> io::Result<File> {
    OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .share_mode(0)
        .open(path)
}

pub fn read_json(path: &Path) -> io::Result<Value> {
    let mut bytes = Vec::new();
    File::open(path)?
        .take(1024 * 1024 + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() > 1024 * 1024 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "auto-launch file is too large",
        ));
    }
    let bytes = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(&bytes);
    serde_json::from_slice(bytes).map_err(io::Error::from)
}

pub fn write_json(path: &Path, value: &Value) -> io::Result<()> {
    let temp = path.with_extension(format!("json.{}", std::process::id()));
    let result = (|| {
        let mut file = File::create(&temp)?;
        file.write_all(value.to_string().as_bytes())?;
        file.sync_all()?;
        drop(file);
        std::fs::rename(&temp, path)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(temp);
    }
    result
}

pub fn enabled(path: &Path) -> bool {
    read_json(path)
        .ok()
        .and_then(|v| v.get("autoLaunchWithAgents").and_then(Value::as_bool))
        == Some(true)
}

/// Only a local, existing coucou.exe, registered by Coucou itself. No PATH or shell lookup.
pub fn executable(path: &Path) -> Option<PathBuf> {
    let local = |p: &Path| {
        matches!(p.components().next(), Some(Component::Prefix(prefix))
        if matches!(prefix.kind(), std::path::Prefix::Disk(_) | std::path::Prefix::VerbatimDisk(_)))
    };
    if !path.is_absolute()
        || !local(path)
        || !path.is_file()
        || !path
            .file_name()?
            .to_str()?
            .eq_ignore_ascii_case("coucou.exe")
    {
        return None;
    }
    let resolved = path.canonicalize().ok()?;
    (local(&resolved)
        && resolved
            .file_name()?
            .to_str()?
            .eq_ignore_ascii_case("coucou.exe"))
    .then_some(resolved)
}
