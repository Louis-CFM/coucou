use crate::audio::{mic_capture::AudioDeviceInfo, MicCapture};
use tauri::command;

#[command]
pub fn get_audio_devices() -> Result<Vec<AudioDeviceInfo>, String> {
    Ok(MicCapture::list_input_devices())
}

#[command]
pub fn test_audio_capture() -> Result<bool, String> {
    Ok(true)
}
