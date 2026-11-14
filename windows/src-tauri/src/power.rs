use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BatteryStatusDto {
    pub has_battery: bool,
    pub level: f64,
    pub percent: u8,
    pub charging: bool,
    pub ac_connected: bool,
    pub time_remaining_seconds: Option<u32>,
}

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
        let has_battery = (status.battery_flag & 128) == 0 && status.battery_life_percent != 255;
        let ac_connected = status.ac_line_status == 1;
        let is_charging = (status.battery_flag & 8) != 0 || (ac_connected && status.battery_life_percent < 100);

        let percent = if status.battery_life_percent <= 100 {
            status.battery_life_percent
        } else if has_battery {
            100
        } else {
            100
        };

        let level = (percent as f64) / 100.0;
        let time_remaining = if status.battery_life_time != u32::MAX && status.battery_life_time > 0 {
            Some(status.battery_life_time)
        } else {
            None
        };

        Ok(BatteryStatusDto {
            has_battery,
            level,
            percent,
            charging: is_charging,
            ac_connected,
            time_remaining_seconds: time_remaining,
        })
    }

    #[cfg(not(windows))]
    {
        // Fallback for non-windows environments
        Ok(BatteryStatusDto {
            has_battery: false,
            level: 1.0,
            percent: 100,
            charging: true,
            ac_connected: true,
            time_remaining_seconds: None,
        })
    }
}

/// Spawns a background hardware power status monitoring thread.
/// Continuously monitors Win32 GetSystemPowerStatus and emits "battery-changed"
/// events to all webview windows whenever charge, percent, or AC status changes.
pub fn setup(handle: &tauri::AppHandle) {
    let handle = handle.clone();
    std::thread::Builder::new()
        .name("coucou-power-monitor".into())
        .spawn(move || {
            let mut last_percent: Option<u8> = None;
            let mut last_charging: Option<bool> = None;
            let mut last_ac: Option<bool> = None;

            loop {
                if let Ok(status) = get_battery_status() {
                    let changed = last_percent != Some(status.percent)
                        || last_charging != Some(status.charging)
                        || last_ac != Some(status.ac_connected);

                    if changed {
                        last_percent = Some(status.percent);
                        last_charging = Some(status.charging);
                        last_ac = Some(status.ac_connected);
                        use tauri::Emitter;
                        let _ = handle.emit("battery-changed", &status);
                    }
                }
                std::thread::sleep(std::time::Duration::from_millis(1500));
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

