// Nova runs without a console window: Nova is the whole UI.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    nova_lib::run()
}
