//! Minimal, local status shared with the GNOME panel. No prompts or paths.
use serde::{Deserialize, Serialize};

#[derive(Default, Deserialize, Serialize)]
pub struct PanelPointer {
    x: f64,
    y: f64,
    hover: bool,
    visible: bool,
    #[serde(default)]
    updated: f64,
    #[serde(default)]
    transport: String,
}

fn valid_frame(png: &[u8]) -> bool {
    png.len() >= 33
        && png.len() <= 65_536
        && png.starts_with(b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR")
        && png[16..24] == [0, 0, 0, 80, 0, 0, 0, 64]
}

fn valid_pixels(bytes: &[u8]) -> bool {
    bytes.len() == 16 + 80 * 64 * 4
        && bytes.starts_with(b"CCF1")
        && f64::from_le_bytes(bytes[8..16].try_into().unwrap()).is_finite()
}

/// A single tiny frame, never a path or arbitrary image supplied by the shell.
/// Runtime files live in the user's private RAM directory and are replaced
/// atomically; a slow shell cannot build a queue of old animation frames.
#[tauri::command]
pub fn publish_panel_frame(request: tauri::ipc::Request<'_>) -> PanelPointer {
    #[cfg(target_os = "linux")]
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let tauri::ipc::InvokeBody::Raw(bytes) = request.body() else {
            return PanelPointer::default();
        };
        let raw = valid_pixels(bytes);
        if !raw && !valid_frame(bytes) {
            return PanelPointer::default();
        }
        let Some(socket) = crate::platform::relay_socket_path() else {
            return PanelPointer::default();
        };
        let Some(dir) = socket.parent() else {
            return PanelPointer::default();
        };
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs_f64())
            .unwrap_or(0.0);
        let mut pointer = std::fs::read(dir.join("coucou-panel-pointer.json"))
            .ok()
            .filter(|b| b.len() <= 1024)
            .and_then(|b| serde_json::from_slice::<PanelPointer>(&b).ok())
            .filter(|p| p.updated.is_finite() && (now - p.updated).abs() < 2.0)
            .unwrap_or_default();
        pointer.x = if pointer.x.is_finite() {
            pointer.x.clamp(-1.0, 1.0)
        } else {
            0.0
        };
        pointer.y = if pointer.y.is_finite() {
            pointer.y.clamp(-1.0, 1.0)
        } else {
            0.0
        };
        let temp = dir.join("coucou-panel-frame.tmp");
        let target = if raw {
            "coucou-panel-frame.rgba"
        } else {
            "coucou-panel-frame.png"
        };
        if let Ok(mut file) = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&temp)
        {
            if file.write_all(bytes).is_ok() {
                let _ = std::fs::rename(&temp, dir.join(target));
            }
        }
        return pointer;
    }
    #[cfg(not(target_os = "linux"))]
    PanelPointer::default()
}

#[cfg(test)]
mod frame_tests {
    use super::*;
    #[test]
    fn raw_pixels_require_exact_size_magic_and_finite_timestamp() {
        let mut bytes = vec![0; 16 + 80 * 64 * 4];
        bytes[..4].copy_from_slice(b"CCF1");
        assert!(valid_pixels(&bytes));
        assert!(!valid_pixels(&bytes[..bytes.len() - 1]));
        bytes.push(0);
        assert!(!valid_pixels(&bytes));
        bytes.pop();
        bytes[8..16].copy_from_slice(&f64::NAN.to_le_bytes());
        assert!(!valid_pixels(&bytes));
        bytes[8..16].copy_from_slice(&0f64.to_le_bytes());
        bytes[0] = 0;
        assert!(!valid_pixels(&bytes));
    }
    #[test]
    fn frame_is_bounded_and_has_the_fixed_avatar_dimensions() {
        let mut png = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR".to_vec();
        png.extend([0, 0, 0, 80, 0, 0, 0, 64]);
        png.extend([0; 9]);
        assert!(valid_frame(&png));
        png[19] = 81;
        assert!(!valid_frame(&png));
        assert!(!valid_frame(b"not a PNG"));
        assert!(!valid_frame(&vec![0; 65_537]));
    }
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PanelStatus {
    working: u32,
    waiting: u32,
    agent: String,
    phase: String,
    expanded: bool,
    #[serde(default)]
    closing: bool,
    #[serde(default)]
    surface_width: f64,
    #[serde(default)]
    surface_height: f64,
}

#[tauri::command]
pub fn publish_panel_state(mut status: PanelStatus) -> bool {
    #[cfg(target_os = "linux")]
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let Some(socket) = crate::platform::relay_socket_path() else {
            return false;
        };
        let Some(dir) = socket.parent() else {
            return false;
        };
        status.agent = status
            .agent
            .chars()
            .filter(|c| !c.is_control())
            .take(40)
            .collect();
        if !["idle", "working", "waiting", "error", "finished"].contains(&status.phase.as_str()) {
            status.phase = "idle".into();
        }
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let data = serde_json::json!({"working": status.working, "waiting": status.waiting,
            "agent": status.agent, "phase": status.phase, "expanded": status.expanded,
            "closing": status.closing, "motion": true,
            "surfaceWidth": status.surface_width.clamp(0.0, 720.0),
            "surfaceHeight": status.surface_height.clamp(0.0, 320.0), "updated": now});
        let temp = dir.join("coucou-panel-status.tmp");
        if let Ok(mut file) = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&temp)
        {
            if file.write_all(data.to_string().as_bytes()).is_ok() {
                let _ = std::fs::rename(&temp, dir.join("coucou-panel-status.json"));
            }
        }
        let marker = std::fs::read_to_string(dir.join("coucou-panel-active"))
            .ok()
            .and_then(|s| s.trim().parse::<u32>().ok());
        return marker.is_some_and(|pid| {
            std::fs::read_to_string(format!("/proc/{pid}/comm"))
                .is_ok_and(|name| name.trim() == "gnome-shell")
        });
    }
    #[cfg(not(target_os = "linux"))]
    false
}
