// Camera, microphone and screen sharing held by another app: the island stays
// away and quiet during a call (CallWatcher.swift on the Mac). Linux reads
// PipeWire through `pw-dump --monitor`, which sleeps between changes.

#[cfg(any(target_os = "linux", test))]
use serde_json::Value;
#[cfg(any(target_os = "linux", test))]
use std::collections::{BTreeSet, HashMap};
use std::sync::Mutex;
use tauri::AppHandle;
#[cfg(target_os = "linux")]
use tauri::Emitter;
use crate::mutex::MutexExt;

#[cfg(target_os = "linux")]
pub const EVENT: &str = "call-sensors";

/// The last set sent, so the page can ask for it once it listens.
static HELD: Mutex<Vec<String>> = Mutex::new(Vec::new());

#[tauri::command]
pub fn call_sensors() -> Vec<String> {
    HELD.lock_recover().clone()
}

/// Folds one `pw-dump` batch into the objects seen so far: `info: null` removes one.
#[cfg(any(target_os = "linux", test))]
fn apply(objects: &mut HashMap<u64, Value>, batch: &Value) {
    for item in batch.as_array().into_iter().flatten() {
        let Some(id) = item.get("id").and_then(Value::as_u64) else { continue };
        match item.get("info") {
            Some(Value::Null) => {
                objects.remove(&id);
            }
            Some(Value::Object(info)) => {
                let entry = objects.entry(id).or_insert_with(|| item.clone());
                if let Some(type_) = item.get("type") {
                    entry["type"] = type_.clone();
                }
                // Only the changed parts may come again: keep what is already known.
                for (key, value) in info {
                    entry["info"][key] = value.clone();
                }
            }
            _ => {}
        }
    }
}

#[cfg(any(target_os = "linux", test))]
fn props(node: &Value) -> &Value {
    &node["info"]["props"]
}

#[cfg(any(target_os = "linux", test))]
fn class(node: &Value) -> &str {
    props(node)["media.class"].as_str().unwrap_or("")
}

#[cfg(any(target_os = "linux", test))]
fn is_camera(node: &Value) -> bool {
    let p = props(node);
    matches!(p["device.api"].as_str(), Some("v4l2" | "libcamera"))
        || p["media.role"].as_str() == Some("Camera")
}

/// `cam`, `mic`, `scr` held by any app but `own`, as on the Mac: a screen
/// counts only for an app also on the mic or camera, never a recorder alone.
#[cfg(any(target_os = "linux", test))]
pub fn held(objects: &HashMap<u64, Value>, own: &str) -> BTreeSet<&'static str> {
    let mut apps: HashMap<String, BTreeSet<&'static str>> = HashMap::new();
    for link in objects.values().filter(|o| o["type"] == "PipeWire:Interface:Link") {
        let node = |key: &str| link["info"][key].as_u64().and_then(|id| objects.get(&id));
        let (Some(from), Some(to)) = (node("output-node-id"), node("input-node-id")) else { continue };
        let p = props(to);
        if p["application.name"].as_str() == Some(own) {
            continue;
        }
        let kind = match class(to) {
            "Stream/Input/Audio" if class(from).starts_with("Audio/Source") => "mic",
            "Stream/Input/Video" if is_camera(from) => "cam",
            "Stream/Input/Video" => "scr",
            _ => continue,
        };
        let app = p["application.process.id"]
            .as_u64()
            .map(|pid| pid.to_string())
            .or_else(|| p["application.name"].as_str().map(str::to_string))
            .unwrap_or_default();
        apps.entry(app).or_default().insert(kind);
    }
    let mut out = BTreeSet::new();
    for kinds in apps.values() {
        let on_call = kinds.contains("cam") || kinds.contains("mic");
        for kind in kinds {
            if *kind != "scr" || on_call {
                out.insert(*kind);
            }
        }
    }
    out
}

#[cfg(target_os = "linux")]
pub fn start(app: AppHandle) {
    let own = std::env::current_exe()
        .ok()
        .and_then(|p| p.file_name().map(|n| n.to_string_lossy().into_owned()))
        .unwrap_or_default();
    let _ = std::thread::Builder::new().name("coucou-calls".into()).spawn(move || watch(&app, &own));
}

#[cfg(not(target_os = "linux"))]
pub fn start(_app: AppHandle) {}

#[cfg(target_os = "linux")]
fn watch(app: &AppHandle, own: &str) {
    use std::os::unix::process::CommandExt;
    use std::process::{Command, Stdio};
    loop {
        let mut cmd = Command::new("pw-dump");
        cmd.args(["--monitor", "--no-colors"]).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
        // Goes with Coucou when it quits.
        unsafe {
            cmd.pre_exec(|| {
                libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM);
                Ok(())
            });
        }
        let mut child = match cmd.spawn() {
            Ok(child) => child,
            Err(err) => {
                crate::log::line(format!("calls: no pw-dump ({err}), calls are not watched"));
                return;
            }
        };
        let mut objects = HashMap::new();
        let stream = serde_json::Deserializer::from_reader(std::io::BufReader::new(child.stdout.take().unwrap()));
        for batch in stream.into_iter::<Value>() {
            let Ok(batch) = batch else { break };
            apply(&mut objects, &batch);
            let now: Vec<String> = held(&objects, own).into_iter().map(str::to_string).collect();
            let mut last = HELD.lock_recover();
            if *last != now {
                crate::log::line(format!("calls: {now:?}"));
                *last = now.clone();
                let _ = app.emit_to(crate::island::WINDOW_LABEL, EVENT, now);
            }
        }
        let _ = child.wait();
        // PipeWire restarted: nothing is held until it says otherwise.
        *HELD.lock_recover() = Vec::new();
        let _ = app.emit_to(crate::island::WINDOW_LABEL, EVENT, Vec::<String>::new());
        std::thread::sleep(std::time::Duration::from_secs(5));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn node(id: u64, class: &str, extra: Value) -> Value {
        let mut props = json!({ "media.class": class });
        props.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
        json!({ "id": id, "type": "PipeWire:Interface:Node", "info": { "state": "running", "props": props } })
    }

    fn link(id: u64, from: u64, to: u64) -> Value {
        json!({ "id": id, "type": "PipeWire:Interface:Link", "info": { "output-node-id": from, "input-node-id": to } })
    }

    fn seen(batch: Value) -> BTreeSet<&'static str> {
        let mut objects = HashMap::new();
        apply(&mut objects, &batch);
        held(&objects, "coucou").into_iter().collect()
    }

    #[test]
    fn a_call_is_another_apps_mic_or_camera() {
        let mic = node(1, "Audio/Source", json!({}));
        let sink = node(2, "Audio/Sink", json!({}));
        let cam = node(3, "Video/Source", json!({ "device.api": "v4l2" }));
        let screen = node(4, "Video/Source", json!({ "node.name": "screencast" }));
        let browser = |id, class| node(id, class, json!({ "application.name": "Example Browser", "application.process.id": 4242 }));
        let recorder = node(20, "Stream/Input/Video", json!({ "application.name": "Recorder", "application.process.id": 77 }));

        // Nothing linked: nothing held.
        assert!(seen(json!([mic, sink, cam, screen])).is_empty());
        // A browser on the mic.
        assert_eq!(seen(json!([mic, browser(10, "Stream/Input/Audio"), link(100, 1, 10)])), ["mic"].into());
        // A visualiser reading the speakers is not on the mic.
        assert!(seen(json!([sink, browser(10, "Stream/Input/Audio"), link(100, 2, 10)])).is_empty());
        // The camera.
        assert_eq!(seen(json!([cam, browser(11, "Stream/Input/Video"), link(101, 3, 11)])), ["cam"].into());
        // A recorder on the screen alone is not a call.
        assert!(seen(json!([screen, recorder, link(102, 4, 20)])).is_empty());
        // A browser on a call sharing its screen, the recorder still beside it.
        let call = json!([mic, cam, screen, recorder,
            browser(10, "Stream/Input/Audio"), browser(11, "Stream/Input/Video"), browser(12, "Stream/Input/Video"),
            link(100, 1, 10), link(101, 3, 11), link(102, 4, 20), link(103, 4, 12)]);
        assert_eq!(seen(call), ["cam", "mic", "scr"].into());
        // Coucou's own listening does not count.
        let own = node(13, "Stream/Input/Audio", json!({ "application.name": "coucou" }));
        assert!(seen(json!([mic, own, link(104, 1, 13)])).is_empty());
    }

    #[test]
    fn a_removed_link_ends_the_call_and_updates_keep_the_rest() {
        let mut objects = HashMap::new();
        let stream = node(10, "Stream/Input/Audio", json!({ "application.name": "Example Browser" }));
        apply(&mut objects, &json!([node(1, "Audio/Source", json!({})), stream, link(100, 1, 10)]));
        assert_eq!(held(&objects, "coucou"), ["mic"].into());
        // A state change alone keeps the props seen before.
        apply(&mut objects, &json!([{ "id": 10, "info": { "state": "idle" } }]));
        assert_eq!(held(&objects, "coucou"), ["mic"].into());
        apply(&mut objects, &json!([{ "id": 100, "info": null }]));
        assert!(held(&objects, "coucou").is_empty());
    }
}
