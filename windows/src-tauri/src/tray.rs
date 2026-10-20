// Notification-area icon: Open, Weekly recap, Wardrobe, Settings, Pause, Quit.
// "Update Coucou to X…" shows under Open only while a new version is out
// (update.rs).

use std::sync::Mutex;

use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Emitter, Manager, Wry};

use crate::i18n::{n_, t, tf};
use crate::island::WINDOW_LABEL;

/// The menu's items, id and English label, in order. The labels are shown in
/// the interface language (i18n.rs) and follow it when it changes.
const ITEMS: [(&str, &str); 6] = [
    ("open", n_("Open Coucou")),
    ("recap", n_("Weekly recap")),
    ("wardrobe", n_("Wardrobe…")),
    ("settings", n_("Settings…")),
    ("pause", n_("Pause")),
    ("quit", n_("Quit")),
];

/// Kept so a language change relabels the menu without rebuilding the tray.
struct Items(Vec<(&'static str, MenuItem<Wry>)>);

/// "Update Coucou to X…": in the menu only while `version` is set.
struct UpdateItem {
    menu: Menu<Wry>,
    item: MenuItem<Wry>,
    version: Mutex<Option<String>>,
}

fn update_label(version: &str) -> String {
    tf("Update Coucou to {version}…", &[("version", version)])
}

pub fn build(app: &AppHandle) -> tauri::Result<()> {
    let mut items = Vec::new();
    for (id, label) in ITEMS {
        items.push((label, MenuItem::with_id(app, id, t(label), true, None::<&str>)?));
    }
    let [open, recap, wardrobe, settings, pause, quit] = [0, 1, 2, 3, 4, 5].map(|i| &items[i].1);
    let sep1 = PredefinedMenuItem::separator(app)?;
    let sep2 = PredefinedMenuItem::separator(app)?;

    let menu = Menu::with_items(app, &[open, recap, &sep1, wardrobe, settings, pause, &sep2, quit])?;
    app.manage(Items(items));
    // Its click goes to the island like the others (id "update"): it opens the update card.
    let update = MenuItem::with_id(app, "update", "", true, None::<&str>)?;
    app.manage(UpdateItem { menu: menu.clone(), item: update, version: Mutex::new(None) });

    let mut builder = TrayIconBuilder::with_id("coucou")
        .tooltip("Coucou")
        .menu(&menu)
        .on_menu_event(|app: &AppHandle, event| match event.id.as_ref() {
            "quit" => app.exit(0),
            "settings" => crate::show_settings_window(app),
            // The Coucou window: dictation, notes and every setting.
            "open" => crate::show_hub(app, None),
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
    for (label, item) in &items.0 {
        let _ = item.set_text(t(label));
    }
    if let Some(update) = app.try_state::<UpdateItem>() {
        // Copied out first: the menu calls wait for the main thread, never under the lock.
        let version = update.version.lock().unwrap().clone();
        if let Some(version) = version {
            let _ = update.item.set_text(update_label(&version));
        }
    }
}

/// Shows "Update Coucou to `version`…" right under Open, or takes it out (None).
pub fn set_update(app: &AppHandle, version: Option<&str>) {
    let Some(update) = app.try_state::<UpdateItem>() else { return };
    let was_shown = {
        let mut shown = update.version.lock().unwrap();
        if shown.as_deref() == version {
            return;
        }
        let was = shown.is_some();
        *shown = version.map(str::to_string);
        was
    };
    match version {
        Some(v) => {
            let _ = update.item.set_text(update_label(v));
            if !was_shown {
                let _ = update.menu.insert(&update.item, 1);
            }
        }
        None => {
            let _ = update.menu.remove(&update.item);
        }
    }
}
