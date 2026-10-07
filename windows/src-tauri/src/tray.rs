// Notification-area icon: Open, Settings, Pause, Lock position, Reset
// position, Quit.

use tauri::menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Emitter, Manager, Wry};

use crate::island::WINDOW_LABEL;

/// The "Lock position" check item, kept so Settings and the island header can
/// update its tick.
struct LockItem(CheckMenuItem<Wry>);

pub fn build(app: &AppHandle, locked: bool) -> tauri::Result<()> {
    let open = MenuItem::with_id(app, "open", "Open Coucou", true, None::<&str>)?;
    let settings = MenuItem::with_id(app, "settings", "Settings…", true, None::<&str>)?;
    let pause = MenuItem::with_id(app, "pause", "Pause", true, None::<&str>)?;
    let lock = CheckMenuItem::with_id(app, "lock", "Lock position", true, locked, None::<&str>)?;
    let reset = MenuItem::with_id(app, "reset-position", "Reset position", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
    let sep1 = PredefinedMenuItem::separator(app)?;
    let sep2 = PredefinedMenuItem::separator(app)?;
    let sep3 = PredefinedMenuItem::separator(app)?;

    let menu = Menu::with_items(app, &[&open, &sep1, &settings, &pause, &sep2, &lock, &reset, &sep3, &quit])?;
    app.manage(LockItem(lock));

    let mut builder = TrayIconBuilder::with_id("coucou")
        .tooltip("Coucou")
        .menu(&menu)
        .on_menu_event(|app: &AppHandle, event| match event.id.as_ref() {
            "quit" => crate::quit(app),
            "settings" => crate::show_settings_window(app),
            "lock" => {
                let shared = app.state::<crate::Shared>();
                // The check item has already flipped its own tick.
                let locked = !shared.settings.lock().unwrap().island_locked;
                crate::set_island_locked(app, &shared, locked);
            }
            "reset-position" => {
                let shared = app.state::<crate::Shared>();
                crate::reset_island_position(app, &shared);
            }
            id => {
                let _ = app.emit_to(WINDOW_LABEL, "tray", id.to_string());
            }
        });

    if let Some(icon) = app.default_window_icon().cloned() {
        builder = builder.icon(icon);
    }

    builder.build(app)?;
    Ok(())
}

/// Keeps the tray tick in step with the setting.
pub fn sync_lock(app: &AppHandle, locked: bool) {
    if let Some(item) = app.try_state::<LockItem>() {
        let _ = item.0.set_checked(locked);
    }
}
