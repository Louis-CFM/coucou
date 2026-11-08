// NexIsland runs without a console window: Splash the dolphin is the whole UI.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    nexisland_lib::run()
}
