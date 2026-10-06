// Coucou runs without a console window: Mochi is the whole UI.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    // `--setup-agents` / `--remove-agents` run before Tauri exists, so they
    // never meet the single-instance check or open a window.
    if let Some(code) = coucou_lib::run_cli(std::env::args()) {
        std::process::exit(code);
    }
    coucou_lib::run()
}
