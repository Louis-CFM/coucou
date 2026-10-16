// Coucou runs without a console window: Mochi is the whole UI.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--uninstall-hooks" || a == "--clean-hooks" || a == "--uninstall") {
        if let Err(error) = coucou_lib::uninstall_all_hooks() {
            eprintln!("Could not remove Coucou hooks: {error}");
            std::process::exit(1);
        }
        return;
    }
    coucou_lib::run()
}
