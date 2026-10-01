// Linux specifics: the display backend, the environment handed to programs we
// launch, and whether a tray icon is possible at all.
//
// Coucou needs three things Wayland deliberately keeps from ordinary windows:
// placing itself at the top centre of the screen, staying above other windows,
// and staying out of the taskbar. XWayland still allows all three, and every
// Wayland desktop Bazzite ships (KDE Plasma, GNOME) runs it, so on a Wayland
// session we ask GTK for its X11 backend. `COUCOU_NATIVE_WAYLAND=1` opts out,
// and a GDK_BACKEND set by the user always wins.

use std::process::Command;
use std::sync::OnceLock;

/// Variables we set for ourselves and must not leak into launched programs —
/// a browser forced onto XWayland would be blurry for no reason.
static OWN_VARS: OnceLock<Vec<&'static str>> = OnceLock::new();

/// Must run before Tauri (and so GTK) starts, while the process is still
/// single-threaded.
pub fn prepare_env() {
    let mut own = Vec::new();
    let unset = |name: &str| std::env::var_os(name).map(|v| v.is_empty()).unwrap_or(true);

    let wayland = !unset("WAYLAND_DISPLAY");
    let xwayland = !unset("DISPLAY");
    if wayland && xwayland && unset("GDK_BACKEND") && unset("COUCOU_NATIVE_WAYLAND") {
        std::env::set_var("GDK_BACKEND", "x11");
        own.push("GDK_BACKEND");
    }

    // WebKitGTK's DMA-BUF renderer draws blank or garbled windows on the NVIDIA
    // driver, which Bazzite ships on its -nvidia images.
    let nvidia = std::path::Path::new("/sys/module/nvidia").exists();
    if nvidia && unset("WEBKIT_DISABLE_DMABUF_RENDERER") {
        std::env::set_var("WEBKIT_DISABLE_DMABUF_RENDERER", "1");
        own.push("WEBKIT_DISABLE_DMABUF_RENDERER");
    }

    let _ = OWN_VARS.set(own);
}

/// Strips what we set for ourselves, and what an AppImage's launcher sets for
/// its bundled libraries, from a program we are about to start.
pub fn clean_env(cmd: &mut Command) -> &mut Command {
    for var in OWN_VARS.get().map(Vec::as_slice).unwrap_or(&[]) {
        cmd.env_remove(var);
    }
    if std::env::var_os("APPIMAGE").is_some() {
        for var in [
            "LD_LIBRARY_PATH",
            "GDK_PIXBUF_MODULE_FILE",
            "GIO_MODULE_DIR",
            "GIO_EXTRA_MODULES",
            "GSETTINGS_SCHEMA_DIR",
            "GST_PLUGIN_SYSTEM_PATH",
            "GST_PLUGIN_SYSTEM_PATH_1_0",
            "GTK_PATH",
            "GTK_EXE_PREFIX",
            "GTK_DATA_PREFIX",
            "PYTHONHOME",
            "PYTHONPATH",
        ] {
            cmd.env_remove(var);
        }
    }
    cmd
}

/// The tray icon goes through libayatana-appindicator (or the older
/// libappindicator), loaded at run time — and a missing library is a panic deep
/// inside the tray crate, not an error. So look first, and run without a tray
/// rather than not at all: the island has its own settings view.
pub fn tray_available() -> bool {
    const LIBS: &[&str] = &[
        "libayatana-appindicator3.so.1\0",
        "libayatana-appindicator3.so\0",
        "libappindicator3.so.1\0",
        "libappindicator3.so\0",
    ];
    LIBS.iter().any(|name| unsafe {
        let handle = libc::dlopen(name.as_ptr().cast(), libc::RTLD_LAZY | libc::RTLD_LOCAL);
        if handle.is_null() {
            false
        } else {
            libc::dlclose(handle);
            true
        }
    })
}

/// `which`, without a shell.
pub fn find_on_path(name: &str) -> Option<std::path::PathBuf> {
    use std::os::unix::fs::PermissionsExt;
    let dirs = std::env::var_os("PATH")?;
    std::env::split_paths(&dirs)
        .map(|dir| dir.join(name))
        .find(|p| {
            std::fs::metadata(p)
                .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
                .unwrap_or(false)
        })
}
