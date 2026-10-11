//! Several Coucous on one host each run a relay for the same request. The one
//! that gets an answer leaves `~/.coucou/answered/<key>`; the others see it and
//! let go, so Claude Code is not held until they time out. Same files and key as
//! nb-hook.py and coucou-hook.py.

use std::path::PathBuf;
use std::time::{Duration, SystemTime};

use serde_json::{Map, Value};

/// How long an answered mark is kept.
const KEEP: Duration = Duration::from_secs(3600);

/// The tool call: Claude Code's `tool_use_id` (PreToolUse), else a hash of
/// session, tool and input (PermissionRequest has no id).
pub fn key(map: &Map<String, Value>) -> String {
    let id = map.get("tool_use_id").and_then(Value::as_str).unwrap_or_default();
    if !id.is_empty() && id.len() <= 128 && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-') {
        return id.to_string();
    }
    let field = |k: &str| map.get(k).and_then(Value::as_str).unwrap_or_default().to_string();
    let mut input = map.get("tool_input").cloned().unwrap_or(Value::Null);
    // Sorted like Python's sort_keys, whatever serde_json's preserve_order says.
    input.sort_all_objects();
    let text = format!("{}\n{}\n{}", field("session_id"), field("tool_name"), input);
    let hash = text.bytes().fold(0xcbf2_9ce4_8422_2325u64, |h, b| (h ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3));
    format!("h{hash:016x}")
}

fn dir() -> Option<PathBuf> {
    Some(PathBuf::from(std::env::var_os("HOME")?).join(".coucou").join("answered"))
}

/// Another relay already answered this call.
pub fn is_answered(key: &str) -> bool {
    dir().is_some_and(|d| d.join(key).exists())
}

/// Marks the call answered (atomically), dropping marks older than KEEP.
pub fn mark(key: &str) {
    let Some(dir) = dir() else { return };
    if std::fs::create_dir_all(&dir).is_err() {
        return;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700));
    }
    let tmp = dir.join(format!(".{key}.{}", std::process::id()));
    if std::fs::write(&tmp, b"").is_ok() {
        let _ = std::fs::rename(&tmp, dir.join(key));
    }
    let now = SystemTime::now();
    for entry in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
        let old = entry.metadata().and_then(|m| m.modified()).is_ok_and(|t| now.duration_since(t).unwrap_or_default() > KEEP);
        if old {
            let _ = std::fs::remove_file(entry.path());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_tool_use_id_is_the_key_else_a_stable_hash() {
        let with_id = json!({ "tool_use_id": "toolu_01ABC", "session_id": "s" });
        assert_eq!(key(with_id.as_object().unwrap()), "toolu_01ABC");
        let a = json!({ "session_id": "s", "tool_name": "Bash", "tool_input": { "b": 1, "a": "x" } });
        let b = json!({ "tool_input": { "a": "x", "b": 1 }, "tool_name": "Bash", "session_id": "s" });
        assert_eq!(key(a.as_object().unwrap()), key(b.as_object().unwrap()));
        let other = json!({ "session_id": "s", "tool_name": "Bash", "tool_input": { "a": "y", "b": 1 } });
        assert_ne!(key(a.as_object().unwrap()), key(other.as_object().unwrap()));
        let bad = json!({ "tool_use_id": "../x", "session_id": "s" });
        assert!(key(bad.as_object().unwrap()).starts_with('h'));
    }
}
