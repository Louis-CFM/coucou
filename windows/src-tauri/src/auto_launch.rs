use std::fs::File;
use tauri::{AppHandle, Manager};

#[path = "../../shared/auto_launch.rs"]
#[allow(dead_code)] // The relay also compiles this file, using the read side.
mod files;

pub use files::diagnostic;
pub use files::LAUNCH_ARG;

#[cfg(test)]
pub fn enabled_for_test(path: &std::path::Path) -> bool {
    files::enabled(path)
}

struct Running {
    _lock: File,
}

/// Register the executable we are actually running, after Tauri's single-instance check.
pub fn register(app: &AppHandle) -> std::io::Result<()> {
    let dir =
        files::local_dir().ok_or_else(|| std::io::Error::other("LOCALAPPDATA is unavailable"))?;
    crate::platform::ensure_private_dir(&dir)?;
    diagnostic(format!(
        "app_setup auto_launch_arg={}",
        std::env::args().any(|a| a == LAUNCH_ARG)
    ));
    let guard = match files::lock(&dir.join("auto-launch-running.lock")) {
        Ok(guard) => guard,
        // Covers the brief interval before the single-instance plugin's window exists.
        Err(err) if err.raw_os_error() == Some(files::SHARING_VIOLATION) => {
            diagnostic("app_duplicate_exit running_lock=true");
            std::process::exit(0);
        }
        Err(err) => return Err(err),
    };
    app.manage(Running { _lock: guard });
    let exe = std::env::current_exe()?;
    let exe = files::executable(&exe)
        .ok_or_else(|| std::io::Error::other("invalid Coucou executable"))?;
    files::write_json(
        &dir.join("auto-launch-executable.json"),
        &serde_json::json!({ "executable": exe }),
    )
}
