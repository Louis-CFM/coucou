// Coucou runs without a console window: Mochi is the whole UI.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    #[cfg(target_os = "linux")]
    linux_env();
    coucou_lib::run()
}

/// Must run before GTK starts, while the process is still single-threaded.
#[cfg(target_os = "linux")]
fn linux_env() {
    // Wayland lets no client place its own window or keep it above the others,
    // and the island needs both. XWayland does allow it, and the cursor read
    // in island.rs goes through X too. An explicit GDK_BACKEND is respected.
    if std::env::var_os("WAYLAND_DISPLAY").is_some() && std::env::var_os("GDK_BACKEND").is_none() {
        std::env::set_var("GDK_BACKEND", "x11");
    }
    // WebKitGTK's DMA-BUF renderer leaves transparent windows blank on many
    // drivers (NVIDIA above all). Same escape hatch: set it yourself to opt out.
    if std::env::var_os("WEBKIT_DISABLE_DMABUF_RENDERER").is_none() {
        std::env::set_var("WEBKIT_DISABLE_DMABUF_RENDERER", "1");
    }
}
