// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod audio;
mod commands;
mod db;
mod screen;
mod tools;

use db::repository::Database;
use std::fs;
use tauri::Manager;

fn main() {
    tauri::Builder::default()
        .setup(|app| {
            // Setup local app data directory for SQLite database
            let app_data_dir = app
                .path()
                .app_data_dir()
                .unwrap_or_else(|_| std::path::PathBuf::from("."));
            
            let _ = fs::create_dir_all(&app_data_dir);
            let db_path = app_data_dir.join("coucou_realtime.db");
            let db_path_str = db_path.to_str().unwrap_or("coucou_realtime.db");

            let database = Database::new(db_path_str).unwrap_or_else(|err| {
                eprintln!("Aviso: Falha ao abrir SQLite no disco ({}), usando memória.", err);
                Database::new_in_memory().expect("Falha ao iniciar SQLite em memória")
            });

            app.manage(database);

            println!("[Coucou Realtime] Backend nativo Rust iniciado com sucesso.");
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::audio_cmd::get_audio_devices,
            commands::audio_cmd::test_audio_capture,
            commands::ocr_cmd::capture_screen_context,
            commands::agent_cmd::get_agents,
            commands::agent_cmd::set_active_agent,
            commands::agent_cmd::upsert_agent,
            commands::agent_cmd::delete_agent,
            commands::agent_cmd::get_memories,
            commands::agent_cmd::add_memory,
            commands::agent_cmd::delete_memory,
            commands::agent_cmd::get_sessions,
            commands::agent_cmd::create_session,
            commands::agent_cmd::get_session_entries,
            commands::agent_cmd::add_session_entry,
            commands::agent_cmd::get_tools,
            commands::agent_cmd::update_tool,
            commands::agent_cmd::execute_tool,
            commands::settings_cmd::toggle_main_window,
            commands::settings_cmd::get_app_version,
        ])
        .run(tauri::generate_context!())
        .expect("Erro ao executar aplicativo Coucou Realtime");
}
