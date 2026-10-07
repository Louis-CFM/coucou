// Global hotkeys: quick chat, new task, voice, robot. The combos live in settings.json
// in a readable form ("Ctrl+Alt+Space"); this module checks them, turns them
// into accelerators for tauri-plugin-global-shortcut and registers them from
// Rust only — the web pages never touch the plugin.

use std::collections::HashMap;
use std::str::FromStr;
use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Manager};
use tauri_plugin_global_shortcut::{GlobalShortcutExt, Shortcut, ShortcutEvent, ShortcutState};

pub const DEFAULT_CHAT: &str = "Ctrl+Alt+C";
pub const DEFAULT_TASK: &str = "Ctrl+Alt+N";
pub const DEFAULT_VOICE: &str = "Ctrl+Alt+V";
pub const DEFAULT_ROBOT: &str = "Ctrl+Alt+R";

fn default_chat() -> String {
    DEFAULT_CHAT.into()
}
fn default_task() -> String {
    DEFAULT_TASK.into()
}
fn default_voice() -> String {
    DEFAULT_VOICE.into()
}
fn default_robot() -> String {
    DEFAULT_ROBOT.into()
}

/// An empty combo means "no hotkey" for that action.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Hotkeys {
    #[serde(default = "default_chat")]
    pub chat: String,
    #[serde(default = "default_task")]
    pub task: String,
    #[serde(default = "default_voice")]
    pub voice: String,
    #[serde(default = "default_robot")]
    pub robot: String,
}

impl Default for Hotkeys {
    fn default() -> Self {
        Self { chat: default_chat(), task: default_task(), voice: default_voice(), robot: default_robot() }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Action {
    Chat,
    Task,
    Voice,
    Robot,
}

impl Action {
    pub const ALL: [Action; 4] = [Action::Chat, Action::Task, Action::Voice, Action::Robot];

    fn label(self) -> &'static str {
        match self {
            Action::Chat => "Quick chat",
            Action::Task => "New task",
            Action::Voice => "Voice",
            Action::Robot => "Robot",
        }
    }
}

impl Hotkeys {
    pub fn get(&self, action: Action) -> &str {
        match action {
            Action::Chat => &self.chat,
            Action::Task => &self.task,
            Action::Voice => &self.voice,
            Action::Robot => &self.robot,
        }
    }

    fn get_mut(&mut self, action: Action) -> &mut String {
        match action {
            Action::Chat => &mut self.chat,
            Action::Task => &mut self.task,
            Action::Voice => &mut self.voice,
            Action::Robot => &mut self.robot,
        }
    }

    /// Canonical spelling where a combo is valid; an invalid one is kept as
    /// typed so the error stays visible in Settings.
    pub fn sanitize(&mut self) {
        for action in Action::ALL {
            let slot = self.get_mut(action);
            if let Ok(c) = normalize(slot) {
                *slot = c;
            } else {
                *slot = slot.trim().to_string();
            }
        }
    }

    /// Every combo valid and no two actions sharing one.
    pub fn validate(&self) -> Result<Hotkeys, String> {
        let mut out = Hotkeys::default();
        for action in Action::ALL {
            let combo = normalize(self.get(action)).map_err(|e| format!("{}: {e}", action.label()))?;
            *out.get_mut(action) = combo;
        }
        for (i, a) in Action::ALL.iter().enumerate() {
            for b in &Action::ALL[i + 1..] {
                let ca = out.get(*a);
                if !ca.is_empty() && ca == out.get(*b) {
                    return Err(format!("{} and {} use the same keys ({ca}).", a.label(), b.label()));
                }
            }
        }
        Ok(out)
    }
}

const MODIFIERS: [&str; 4] = ["Ctrl", "Alt", "Shift", "Win"];

fn modifier(token: &str) -> Option<&'static str> {
    match token.to_ascii_lowercase().as_str() {
        "ctrl" | "control" => Some("Ctrl"),
        "alt" | "option" => Some("Alt"),
        "shift" => Some("Shift"),
        "win" | "super" | "meta" | "windows" | "cmd" | "command" => Some("Win"),
        _ => None,
    }
}

/// The main key, in the spelling Settings shows. Only keys the plugin can map
/// to a Windows virtual key are accepted.
fn main_key(token: &str) -> Option<String> {
    let t = token.trim();
    let upper = t.to_ascii_uppercase();
    if upper.len() == 1 {
        let c = upper.chars().next().unwrap();
        if c.is_ascii_alphanumeric() {
            return Some(upper);
        }
    }
    if let Some(n) = upper.strip_prefix('F').and_then(|n| n.parse::<u8>().ok()) {
        if (1..=24).contains(&n) {
            return Some(format!("F{n}"));
        }
    }
    if let Some(n) = upper.strip_prefix("NUM").and_then(|n| n.parse::<u8>().ok()) {
        if n <= 9 {
            return Some(format!("Num{n}"));
        }
    }
    let named = match upper.as_str() {
        "SPACE" | "SPACEBAR" => "Space",
        "ENTER" | "RETURN" => "Enter",
        "TAB" => "Tab",
        "BACKSPACE" => "Backspace",
        "DELETE" | "DEL" => "Delete",
        "INSERT" | "INS" => "Insert",
        "HOME" => "Home",
        "END" => "End",
        "PAGEUP" | "PGUP" => "PageUp",
        "PAGEDOWN" | "PGDN" => "PageDown",
        "UP" | "ARROWUP" => "Up",
        "DOWN" | "ARROWDOWN" => "Down",
        "LEFT" | "ARROWLEFT" => "Left",
        "RIGHT" | "ARROWRIGHT" => "Right",
        "COMMA" | "," => "Comma",
        "PERIOD" | "." => "Period",
        "SLASH" | "/" => "Slash",
        "BACKSLASH" | "\\" => "Backslash",
        "SEMICOLON" | ";" => "Semicolon",
        "QUOTE" | "'" => "Quote",
        "BRACKETLEFT" | "[" => "BracketLeft",
        "BRACKETRIGHT" | "]" => "BracketRight",
        "MINUS" | "-" => "Minus",
        "EQUAL" | "=" => "Equal",
        "BACKQUOTE" | "`" => "Backquote",
        "PAUSE" => "Pause",
        "PRINTSCREEN" | "PRTSC" => "PrintScreen",
        "SCROLLLOCK" => "ScrollLock",
        "NUMLOCK" => "NumLock",
        "CAPSLOCK" => "CapsLock",
        "VOLUMEUP" | "AUDIOVOLUMEUP" => "VolumeUp",
        "VOLUMEDOWN" | "AUDIOVOLUMEDOWN" => "VolumeDown",
        "VOLUMEMUTE" | "AUDIOVOLUMEMUTE" => "VolumeMute",
        "MEDIAPLAYPAUSE" => "MediaPlayPause",
        "MEDIASTOP" => "MediaStop",
        "MEDIATRACKNEXT" => "MediaTrackNext",
        "MEDIATRACKPREVIOUS" | "MEDIATRACKPREV" => "MediaTrackPrevious",
        _ => return None,
    };
    Some(named.to_string())
}

/// "ctrl + alt + space" → "Ctrl+Alt+Space". Empty → "" (no hotkey).
/// Needs Ctrl, Alt or Win (Shift alone would steal ordinary typing); F-keys
/// may stand alone. Combos Windows keeps for itself are refused.
pub fn normalize(raw: &str) -> Result<String, String> {
    let raw = raw.trim();
    if raw.is_empty() {
        return Ok(String::new());
    }
    let tokens: Vec<&str> = raw.split('+').map(str::trim).collect();
    // "Ctrl+Alt++" — the last token is the "+" key itself, which we do not offer.
    if tokens.iter().any(|t| t.is_empty()) {
        return Err("That key combination is not valid.".into());
    }
    let (key_token, mod_tokens) = tokens.split_last().unwrap();
    let mut mods = Vec::new();
    for t in mod_tokens {
        let m = modifier(t).ok_or_else(|| format!("\"{t}\" is not Ctrl, Alt, Shift or Win."))?;
        if !mods.contains(&m) {
            mods.push(m);
        }
    }
    if modifier(key_token).is_some() {
        return Err("Add a key after the modifiers.".into());
    }
    let key = main_key(key_token).ok_or_else(|| format!("\"{key_token}\" can't be used as a hotkey."))?;
    let is_fkey = key.starts_with('F') && key.len() > 1 && key[1..].chars().all(|c| c.is_ascii_digit());
    let alone_ok = is_fkey || STANDALONE.contains(&key.as_str());
    if !alone_ok && !mods.iter().any(|m| *m != "Shift") {
        return Err("Use Ctrl, Alt or Win with the key.".into());
    }
    let mut ordered: Vec<&str> = MODIFIERS.iter().copied().filter(|m| mods.contains(m)).collect();
    ordered.push(&key);
    let combo = ordered.join("+");
    if is_reserved(&combo) {
        return Err(format!("{combo} is reserved by Windows."));
    }
    Ok(combo)
}

/// Keys that type nothing, so they may be a hotkey on their own. Fn+key
/// combinations on laptops usually send one of these (Fn itself never reaches Windows).
const STANDALONE: [&str; 10] = [
    "PrintScreen", "ScrollLock", "Pause", "VolumeUp", "VolumeDown", "VolumeMute",
    "MediaPlayPause", "MediaStop", "MediaTrackNext", "MediaTrackPrevious",
];

fn is_reserved(combo: &str) -> bool {
    matches!(combo, "Ctrl+Alt+Delete" | "Win+L" | "Alt+Tab" | "Alt+F4" | "Ctrl+Shift+Escape" | "Win+D" | "Win+H")
}

/// Canonical combo → accelerator string for the plugin ("Control+Alt+Space").
pub fn accelerator(combo: &str) -> String {
    combo
        .split('+')
        .map(|t| match t {
            "Ctrl" => "Control",
            "Win" => "Super",
            other => other,
        })
        .collect::<Vec<_>>()
        .join("+")
}

/// The plugin's error text → what Settings shows.
pub fn register_error_message(raw: &str) -> String {
    let lower = raw.to_ascii_lowercase();
    if lower.contains("already registered") {
        "Taken by another app (or by Windows). Pick another combination.".into()
    } else {
        format!("Could not register: {raw}")
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HotkeyStatus {
    pub action: Action,
    pub combo: String,
    pub registered: bool,
    pub error: Option<String>,
}

#[derive(Default)]
pub struct HotkeyState {
    ids: Mutex<HashMap<u32, Action>>,
    status: Mutex<Vec<HotkeyStatus>>,
}

/// Swaps every Coucou hotkey for `keys`. Each action is registered on its own,
/// so one taken combo does not cost the other two.
pub fn apply(app: &AppHandle, keys: &Hotkeys) -> Vec<HotkeyStatus> {
    let gs = app.global_shortcut();
    if let Err(err) = gs.unregister_all() {
        crate::log::line(format!("hotkeys unregister: {err}"));
    }
    let state = app.state::<HotkeyState>();
    let mut ids = HashMap::new();
    let mut out = Vec::new();
    for action in Action::ALL {
        let raw = keys.get(action);
        let status = match normalize(raw) {
            Ok(combo) if combo.is_empty() => HotkeyStatus { action, combo, registered: false, error: None },
            Ok(combo) => match Shortcut::from_str(&accelerator(&combo)) {
                Ok(shortcut) if ids.contains_key(&shortcut.id()) => HotkeyStatus {
                    action,
                    combo,
                    registered: false,
                    error: Some("Already used by another Coucou hotkey.".into()),
                },
                Ok(shortcut) => match gs.register(shortcut) {
                    Ok(()) => {
                        ids.insert(shortcut.id(), action);
                        HotkeyStatus { action, combo, registered: true, error: None }
                    }
                    Err(err) => HotkeyStatus {
                        action,
                        combo,
                        registered: false,
                        error: Some(register_error_message(&err.to_string())),
                    },
                },
                Err(err) => HotkeyStatus { action, combo, registered: false, error: Some(err.to_string()) },
            },
            Err(err) => HotkeyStatus { action, combo: raw.to_string(), registered: false, error: Some(err) },
        };
        if let Some(err) = &status.error {
            crate::log::line(format!("hotkey {:?} {}: {err}", action, status.combo));
        }
        out.push(status);
    }
    *state.ids.lock().unwrap() = ids;
    *state.status.lock().unwrap() = out.clone();
    out
}

/// While Settings records a new combo, the old ones must not fire.
pub fn suspend(app: &AppHandle) {
    if let Err(err) = app.global_shortcut().unregister_all() {
        crate::log::line(format!("hotkeys suspend: {err}"));
    }
    app.state::<HotkeyState>().ids.lock().unwrap().clear();
}

pub fn status(app: &AppHandle) -> Vec<HotkeyStatus> {
    app.state::<HotkeyState>().status.lock().unwrap().clone()
}

/// The plugin's handler: key-down only.
pub fn on_shortcut(app: &AppHandle, shortcut: &Shortcut, event: ShortcutEvent) {
    if event.state != ShortcutState::Pressed {
        return;
    }
    let action = app.state::<HotkeyState>().ids.lock().unwrap().get(&shortcut.id()).copied();
    match action {
        Some(Action::Chat) => crate::quick::toggle(app, crate::quick::CHAT),
        Some(Action::Task) => crate::quick::toggle(app, crate::quick::TASK),
        Some(Action::Voice) => crate::quick::voice(app),
        Some(Action::Robot) => crate::quick::toggle(app, crate::quick::ROBOT),
        None => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn combos_are_normalised() {
        assert_eq!(normalize(" ctrl + alt + space ").unwrap(), "Ctrl+Alt+Space");
        assert_eq!(normalize("Alt+Control+n").unwrap(), "Ctrl+Alt+N");
        assert_eq!(normalize("shift+super+v").unwrap(), "Shift+Win+V");
        assert_eq!(normalize("Ctrl+Ctrl+1").unwrap(), "Ctrl+1");
        assert_eq!(normalize("F9").unwrap(), "F9");
        assert_eq!(normalize("Shift+F13").unwrap(), "Shift+F13");
        assert_eq!(normalize("Ctrl+Alt+ArrowUp").unwrap(), "Ctrl+Alt+Up");
        assert_eq!(normalize("Win+num5").unwrap(), "Win+Num5");
        assert_eq!(normalize("").unwrap(), "");
        assert_eq!(normalize("   ").unwrap(), "");
        assert_eq!(normalize("printscreen").unwrap(), "PrintScreen");
        assert_eq!(normalize("AudioVolumeUp").unwrap(), "VolumeUp");
        assert_eq!(normalize("MediaTrackPrev").unwrap(), "MediaTrackPrevious");
        assert!(normalize("CapsLock").is_err(), "CapsLock alone would break typing");
        assert!(normalize("NumLock").is_err());
        assert_eq!(normalize("Ctrl+Alt+NumLock").unwrap(), "Ctrl+Alt+NumLock");
    }

    #[test]
    fn bad_combos_are_refused() {
        for bad in [
            "A", "Shift+A", "Ctrl+Alt", "Ctrl+", "Ctrl++", "Hyper+A", "Ctrl+Alt+Foo", "Ctrl+A+B",
            "Ctrl+Alt+Delete", "Win+L", "Alt+F4", "F25", "Ctrl+Alt+é",
        ] {
            assert!(normalize(bad).is_err(), "{bad}");
        }
        assert_eq!(normalize("Shift+A").unwrap_err(), "Use Ctrl, Alt or Win with the key.");
        assert_eq!(normalize("Win+L").unwrap_err(), "Win+L is reserved by Windows.");
    }

    #[test]
    fn every_normalised_combo_parses_as_a_plugin_shortcut() {
        for combo in [
            DEFAULT_CHAT, DEFAULT_TASK, DEFAULT_VOICE, "Shift+Win+V", "Ctrl+Alt+Up", "Win+Num5",
            "Ctrl+Shift+Comma", "Alt+Backquote", "F24", "Ctrl+Alt+PageDown",
            "PrintScreen", "MediaPlayPause", "VolumeMute", "MediaTrackPrevious", "Ctrl+ScrollLock",
            "Ctrl+Alt+NumLock", "Win+CapsLock", "Pause",
        ] {
            let c = normalize(combo).unwrap();
            assert!(Shortcut::from_str(&accelerator(&c)).is_ok(), "{c} → {}", accelerator(&c));
        }
        assert_eq!(accelerator("Ctrl+Shift+Win+K"), "Control+Shift+Super+K");
        assert_ne!(
            Shortcut::from_str(&accelerator(DEFAULT_CHAT)).unwrap().id(),
            Shortcut::from_str(&accelerator(DEFAULT_TASK)).unwrap().id()
        );
    }

    #[test]
    fn defaults_and_validation() {
        let d = Hotkeys::default();
        assert_eq!((d.chat.as_str(), d.task.as_str(), d.voice.as_str()), ("Ctrl+Alt+C", "Ctrl+Alt+N", "Ctrl+Alt+V"));
        assert_eq!(d.validate().unwrap(), d);

        let dup = Hotkeys { voice: "alt+ctrl+c".into(), ..Hotkeys::default() };
        assert_eq!(dup.validate().unwrap_err(), "Quick chat and Voice use the same keys (Ctrl+Alt+C).");

        let off = Hotkeys { chat: "".into(), task: "".into(), ..Hotkeys::default() };
        assert_eq!(off.validate().unwrap().chat, "");

        let bad = Hotkeys { task: "Shift+T".into(), ..Hotkeys::default() };
        assert_eq!(bad.validate().unwrap_err(), "New task: Use Ctrl, Alt or Win with the key.");

        let mut messy = Hotkeys { chat: " control+alt+space ".into(), task: " nope ".into(), ..Hotkeys::default() };
        messy.sanitize();
        assert_eq!(messy.chat, "Ctrl+Alt+Space");
        assert_eq!(messy.task, "nope");
    }

    #[test]
    fn missing_fields_fall_back_to_defaults() {
        let h: Hotkeys = serde_json::from_str(r#"{"chat":"Ctrl+Alt+K"}"#).unwrap();
        assert_eq!(h.chat, "Ctrl+Alt+K");
        assert_eq!(h.task, DEFAULT_TASK);
        assert_eq!(h.voice, DEFAULT_VOICE);
        assert_eq!(h.robot, DEFAULT_ROBOT, "older settings files get the robot hotkey");
    }

    #[test]
    fn the_robot_hotkey_is_checked_like_the_others() {
        let d = Hotkeys::default();
        assert_eq!(d.robot, "Ctrl+Alt+R");
        let dup = Hotkeys { robot: "ctrl+alt+n".into(), ..Hotkeys::default() };
        assert_eq!(dup.validate().unwrap_err(), "New task and Robot use the same keys (Ctrl+Alt+N).");
        let off = Hotkeys { robot: "".into(), ..Hotkeys::default() };
        assert_eq!(off.validate().unwrap().robot, "");
        assert!(crate::quick::is_quick("quick-robot") && !crate::quick::is_quick("settings"));
    }

    #[test]
    fn registration_errors_are_readable() {
        assert_eq!(
            register_error_message("HotKey already registered: HotKey { mods: ... }"),
            "Taken by another app (or by Windows). Pick another combination."
        );
        assert_eq!(register_error_message("boom"), "Could not register: boom");
    }
}
