mod active_window;
mod codex;
mod desktop;
mod display;
mod hook_server;
mod paths;
mod resources;
mod secrets;
mod window_mgr;

use hook_server::HookServerState;
use std::sync::Arc;
use tauri::Emitter;
use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Modifiers, Shortcut, ShortcutState};

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let hook_state = Arc::new(HookServerState::new());
    let hook_for_setup = Arc::clone(&hook_state);
    let codex_state = codex::CodexState::new();

    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, _shortcut, event| {
                    if event.state == ShortcutState::Pressed {
                        let _ = app.emit("desktop-hotkey", "shift+m");
                    }
                })
                .build(),
        )
        .manage(hook_state)
        .manage(secrets::SecretsState::new())
        .manage(codex_state)
        .setup(move |app| {
            let _ = paths::ensure();
            hook_server::start(app.handle().clone(), hook_for_setup);
            codex::refresh_auth_on_startup(app.handle().clone());
            // Shift+M — open desktop control / analyze screen
            let shortcut = Shortcut::new(Some(Modifiers::SHIFT), Code::KeyM);
            if let Err(e) = app.global_shortcut().register(shortcut) {
                eprintln!("[coucou] global shortcut Shift+M unavailable: {e}");
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            hook_server::preview_claude_hooks,
            hook_server::write_claude_hooks,
            hook_server::uninstall_claude_hooks,
            hook_server::hooks_installed,
            hook_server::permission_decision,
            secrets::secrets_get,
            secrets::secrets_set,
            secrets::secrets_delete,
            secrets::secrets_status,
            display::get_display_info,
            display::get_session_info,
            window_mgr::position_island,
            window_mgr::set_click_through,
            active_window::get_active_window,
            codex::codex_status,
            codex::codex_login_chatgpt,
            codex::codex_login_device_code,
            codex::codex_login_cancel,
            codex::codex_logout,
            codex::codex_get_auth_state,
            codex::codex_run_prompt,
            desktop::desktop_open,
            desktop::desktop_type_text,
            desktop::desktop_key,
            desktop::desktop_media,
            desktop::desktop_screenshot,
            desktop::desktop_session_hint,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
