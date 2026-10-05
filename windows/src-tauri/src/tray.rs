// Notification-area icon: Open, Settings, Pause, Quit.

use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Emitter, Manager, Wry};

use crate::i18n::tr;
use crate::island::WINDOW_LABEL;

/// Kept so the labels can follow a language change without rebuilding the tray.
struct Items {
    open: MenuItem<Wry>,
    settings: MenuItem<Wry>,
    pause: MenuItem<Wry>,
    quit: MenuItem<Wry>,
}

fn labels() -> [&'static str; 4] {
    [
        tr("Open Coucou", "Abrir Coucou"),
        tr("Settings…", "Ajustes…"),
        tr("Pause", "Pausar"),
        tr("Quit", "Salir"),
    ]
}

pub fn build(app: &AppHandle) -> tauri::Result<()> {
    let [open_label, settings_label, pause_label, quit_label] = labels();
    let open = MenuItem::with_id(app, "open", open_label, true, None::<&str>)?;
    let settings = MenuItem::with_id(app, "settings", settings_label, true, None::<&str>)?;
    let pause = MenuItem::with_id(app, "pause", pause_label, true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", quit_label, true, None::<&str>)?;
    let sep1 = PredefinedMenuItem::separator(app)?;
    let sep2 = PredefinedMenuItem::separator(app)?;

    let menu = Menu::with_items(app, &[&open, &sep1, &settings, &pause, &sep2, &quit])?;
    app.manage(Items { open, settings, pause, quit });

    let mut builder = TrayIconBuilder::with_id("coucou")
        .tooltip("Coucou")
        .menu(&menu)
        .on_menu_event(|app: &AppHandle, event| match event.id.as_ref() {
            "quit" => app.exit(0),
            "settings" => crate::show_settings_window(app),
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

/// Relabels the menu in the current language.
pub fn retitle(app: &AppHandle) {
    let Some(items) = app.try_state::<Items>() else { return };
    let [open, settings, pause, quit] = labels();
    let _ = items.open.set_text(open);
    let _ = items.settings.set_text(settings);
    let _ = items.pause.set_text(pause);
    let _ = items.quit.set_text(quit);
}
