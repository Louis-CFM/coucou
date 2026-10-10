// Coucou runs without a console window: Mochi is the whole UI.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--uninstall-hooks" || a == "--clean-hooks" || a == "--uninstall") {
        coucou_lib::uninstall_all_hooks();
        return;
    }
    coucou_lib::run()
}
