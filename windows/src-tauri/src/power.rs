use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use tauri::Emitter;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BatteryStatusDto {
    pub has_battery: bool,
    pub level: f64,
    pub percent: u8,
    pub charging: bool,
    pub ac_connected: bool,
    pub time_remaining_seconds: Option<u32>,
}

static CURRENT_STATUS: Mutex<Option<BatteryStatusDto>> = Mutex::new(None);

#[cfg(windows)]
#[repr(C)]
#[derive(Default, Debug, Clone, Copy)]
struct SystemPowerStatus {
    ac_line_status: u8,
    battery_flag: u8,
    battery_life_percent: u8,
    system_status_flag: u8,
    battery_life_time: u32,
    battery_full_life_time: u32,
}

#[cfg(windows)]
extern "system" {
    fn GetSystemPowerStatus(lp_system_power_status: *mut SystemPowerStatus) -> i32;
}

/// Fallback state when power status cannot be determined (e.g. desktop PC plugged into AC)
pub fn fallback_status() -> BatteryStatusDto {
    BatteryStatusDto {
        has_battery: false,
        level: 1.0,
        percent: 100,
        charging: false,
        ac_connected: true,
        time_remaining_seconds: None,
    }
}

/// Queries the native Win32 power status API directly.
#[tauri::command]
pub fn get_battery_status() -> Result<BatteryStatusDto, String> {
    #[cfg(windows)]
    {
        let mut status = SystemPowerStatus::default();
        let res = unsafe { GetSystemPowerStatus(&mut status) };
        if res == 0 {
            return Err("GetSystemPowerStatus call failed".into());
        }

        // battery_flag: 128 means no system battery (desktop PC plugged directly to AC)
        // battery_life_percent: 255 means status unknown
        let has_battery = (status.battery_flag & 128) == 0 && status.battery_life_percent != 255;
        let ac_connected = status.ac_line_status == 1;

        // Charging is true if battery_flag has bit 3 (8) set,
        // OR if AC is connected and the battery is not fully charged (< 100)
        let is_charging = has_battery
            && ((status.battery_flag & 8) != 0
                || (ac_connected && status.battery_life_percent < 100));

        let percent = if status.battery_life_percent <= 100 {
            status.battery_life_percent
        } else {
            100
        };

        let level = (percent as f64) / 100.0;
        let time_remaining = if status.battery_life_time != u32::MAX && status.battery_life_time > 0 {
            Some(status.battery_life_time)
        } else {
            None
        };

        let dto = BatteryStatusDto {
            has_battery,
            level,
            percent,
            charging: is_charging,
            ac_connected,
            time_remaining_seconds: time_remaining,
        };

        if let Ok(mut lock) = CURRENT_STATUS.lock() {
            *lock = Some(dto.clone());
        }

        Ok(dto)
    }

    #[cfg(not(windows))]
    {
        let dto = fallback_status();
        if let Ok(mut lock) = CURRENT_STATUS.lock() {
            *lock = Some(dto.clone());
        }
        Ok(dto)
    }
}

/// Returns the authoritative battery status, using fresh native API with fallback to cache.
pub fn get_authoritative_status() -> BatteryStatusDto {
    match get_battery_status() {
        Ok(fresh) => fresh,
        Err(_) => {
            if let Ok(lock) = CURRENT_STATUS.lock() {
                lock.clone().unwrap_or_else(fallback_status)
            } else {
                fallback_status()
            }
        }
    }
}

/// Force-refreshes battery status and emits "battery-changed" if status differs.
#[tauri::command]
pub fn refresh_battery_status(handle: tauri::AppHandle) -> Result<BatteryStatusDto, String> {
    let status = get_battery_status()?;
    let _ = handle.emit("battery-changed", &status);
    Ok(status)
}

/// Spawns a background hardware power status monitoring thread.
/// Continuously monitors Win32 GetSystemPowerStatus and emits "battery-changed"
/// events to all webview windows whenever charge, percent, or AC status changes.
pub fn setup(handle: &tauri::AppHandle) {
    let handle = handle.clone();

    // Cache initial snapshot immediately
    let initial = get_authoritative_status();
    crate::log::line(format!(
        "[coucou] power monitor initialized — has_battery: {}, percent: {}%, charging: {}",
        initial.has_battery, initial.percent, initial.charging
    ));

    std::thread::Builder::new()
        .name("coucou-power-monitor".into())
        .spawn(move || {
            let mut last_status: Option<BatteryStatusDto> = Some(initial);

            loop {
                std::thread::sleep(std::time::Duration::from_millis(1000));
                if let Ok(status) = get_battery_status() {
                    let changed = match &last_status {
                        Some(prev) => prev != &status,
                        None => true,
                    };

                    if changed {
                        crate::log::line(format!(
                            "[coucou] power status changed: {}% (charging: {}, ac: {})",
                            status.percent, status.charging, status.ac_connected
                        ));
                        last_status = Some(status.clone());
                        let _ = handle.emit("battery-changed", &status);
                    }
                }
            }
        })
        .expect("failed to spawn power monitor thread");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_power_status() {
        let status = get_battery_status().expect("get_battery_status should succeed");
        println!("BATTERY STATUS RESULT: {:?}", status);
        assert!(status.percent <= 100);
    }
}
