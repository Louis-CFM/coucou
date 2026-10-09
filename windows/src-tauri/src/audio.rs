// The default output's master volume and mute, through Core Audio
// (IAudioEndpointVolume): the music card's volume slider and the volume HUD.

use windows::Win32::Media::Audio::Endpoints::IAudioEndpointVolume;
use windows::Win32::Media::Audio::{eConsole, eRender, IMMDeviceEnumerator, MMDeviceEnumerator};
use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_ALL, COINIT_MULTITHREADED};

pub fn endpoint() -> Option<IAudioEndpointVolume> {
    unsafe {
        // Already initialised (either model) is fine: the call below works in both.
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        let devices: IMMDeviceEnumerator = CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL).ok()?;
        let device = devices.GetDefaultAudioEndpoint(eRender, eConsole).ok()?;
        device.Activate::<IAudioEndpointVolume>(CLSCTX_ALL, None).ok()
    }
}

/// 0…1.
pub fn master_volume() -> Option<f32> {
    unsafe { endpoint()?.GetMasterVolumeLevelScalar().ok() }
}

pub fn set_master_volume(v: f32) -> bool {
    endpoint().is_some_and(|e| unsafe { e.SetMasterVolumeLevelScalar(v.clamp(0.0, 1.0), std::ptr::null()).is_ok() })
}

pub fn muted() -> Option<bool> {
    unsafe { endpoint()?.GetMute().ok().map(|b| b.as_bool()) }
}

pub fn set_muted(on: bool) -> bool {
    endpoint().is_some_and(|e| unsafe { e.SetMute(on, std::ptr::null()).is_ok() })
}
