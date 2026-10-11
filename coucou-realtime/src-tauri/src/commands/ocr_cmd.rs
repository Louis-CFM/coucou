use crate::screen::ocr::{OcrEngine, OcrResult};
use tauri::command;

#[command]
pub fn capture_screen_context() -> Result<OcrResult, String> {
    OcrEngine::extract_screen_context()
}
