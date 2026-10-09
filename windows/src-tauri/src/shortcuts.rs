// Global keyboard shortcuts — port of HotKeyCenter.swift + ShortcutLogic.swift.
//
// The shortcuts are registered from Rust through tauri-plugin-global-shortcut
// (RegisterHotKey on Windows, XGrabKey on X11). Wayland has no key grabs: there
// they go to the desktop through the XDG GlobalShortcuts portal (portal.rs), and
// where there is no such portal Settings lists `nova --shortcut <id>` commands
// to bind by hand. A press is handed to the island
// as a `shortcut` event carrying the action id; the island does the rest, the
// same way it handles the tray menu. The wardrobe is the exception: it goes out
// as its own `open-wardrobe` event, which the wardrobe view listens to.
//
// Default keys. The Mac uses ⌃⌥ + a letter. On Windows Ctrl+Alt *is* AltGr on
// most European layouts, so a global Ctrl+Alt+E would swallow every € typed on
// a French or German keyboard. The defaults below were checked against the
// AltGr layer of the French (AZERTY), German (QWERTZ), Spanish, Italian,
// Portuguese and Brazilian (ABNT2) layouts, which between them put a character
// on E, Q, M, W, C and on every digit and most punctuation keys:
//
//   Ctrl+Alt+Space   open the chat           Ctrl+Alt+→ / ←  next / previous pill
//   Ctrl+Alt+A       waiting permission      Ctrl+Alt+S      mute Nova
//   Ctrl+Alt+T       open the terminal       Ctrl+Alt+G      wardrobe
//   Ctrl+Alt+D       Nova to the desktop, or home again (the Mac's ⌃⌥D)
//   Ctrl+Alt+N       open / close the island (off by default, as on the Mac)
//
// ⌃⌥[ and ⌃⌥] became the arrows (brackets are AltGr characters almost
// everywhere) and ⌃⌥M became S (AltGr+M is µ in German). Layouts outside that
// list can still clash — Polish puts ą on AltGr+A and ś on AltGr+S — so on
// Windows every Ctrl+Alt combination is also checked against the keyboard
// layouts actually installed (platform::ctrl_alt_types) and left unregistered,
// flagged in Settings, when it types a character. The same table lives in
// src/core/shortcuts.ts; tests/shortcuts.test.mjs keeps the two in step.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::str::FromStr;
use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter, Manager, Runtime};
use tauri_plugin_global_shortcut::{Code, GlobalShortcut, Modifiers, Shortcut, ShortcutState};

use crate::island::WINDOW_LABEL;

/// One global action, as on the Mac (`ShortcutAction`). The ids are the Mac's
/// raw values and are stored in settings.json: never rename one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ActionDef {
    pub id: &'static str,
    pub default_keys: &'static str,
    pub enabled_by_default: bool,
    /// False for the Mac actions this version cannot do yet. Their ids and
    /// defaults stay reserved so a later port lands on the same keys.
    pub ported: bool,
}

const fn action(id: &'static str, keys: &'static str, on: bool, ported: bool) -> ActionDef {
    ActionDef { id, default_keys: keys, enabled_by_default: on, ported }
}

/// Same order as `ShortcutAction.allCases`.
pub const ACTIONS: &[ActionDef] = &[
    action("killEngine", "Ctrl+Alt+K", true, true),
    action("toggleIsland", "Ctrl+Alt+N", false, true),
    action("openChat", "Ctrl+Alt+Space", true, true),
    action("goToAlert", "Ctrl+Alt+A", true, true),
    action("jumpToTerminal", "Ctrl+Alt+T", true, true),
    // Dragging Nova onto a window is not in this version.
    action("attachFrontWindow", "Ctrl+Alt+F", true, false),
    action("nextPill", "Ctrl+Alt+Right", true, true),
    action("prevPill", "Ctrl+Alt+Left", true, true),
    action("muteToggle", "Ctrl+Alt+S", true, true),
    action("desktopToggle", "Ctrl+Alt+D", true, true),
    action("wardrobeToggle", "Ctrl+Alt+G", true, true),
];

pub fn find(id: &str) -> Option<&'static ActionDef> {
    ACTIONS.iter().find(|a| a.id == id)
}

/// What an action does, in English: the key of its label in Settings
/// (SHORTCUT_TEXT in src/core/shortcuts.ts; tests/shortcuts.test.mjs keeps
/// the two in step). The portal shows it in the desktop's own settings.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub fn description(id: &str) -> &'static str {
    use crate::i18n::n_;
    match id {
        "killEngine" => n_("Emergency engine stop (Strict mode)"),
        "toggleIsland" => n_("Open or close the island"),
        "openChat" => n_("Open the chat"),
        "goToAlert" => n_("Go to the waiting permission or question"),
        "jumpToTerminal" => n_("Open the terminal"),
        "attachFrontWindow" => n_("Attach the front window to the chat"),
        "nextPill" => n_("Next pill"),
        "prevPill" => n_("Previous pill"),
        "muteToggle" => n_("Mute or unmute Nova"),
        "desktopToggle" => n_("Send Nova to the desktop"),
        "wardrobeToggle" => n_("Open the wardrobe"),
        _ => "Nova",
    }
}

/// What the user chose for one action. An action missing from settings.json
/// uses its default; `keys` empty means no key at all.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Binding {
    pub keys: String,
    pub enabled: bool,
}

impl Default for Binding {
    fn default() -> Self {
        Self { keys: String::new(), enabled: true }
    }
}

/// `settings.shortcuts`: only the actions the user changed.
pub type Bindings = BTreeMap<String, Binding>;

/// The binding in force for `def`: the stored one, or the default.
pub fn effective(def: &ActionDef, stored: &Bindings) -> Binding {
    stored.get(def.id).cloned().unwrap_or_else(|| Binding {
        keys: def.default_keys.to_string(),
        enabled: def.enabled_by_default,
    })
}

// ── Status shown in Settings ──────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Status {
    /// Registered and listening.
    Active,
    /// Turned off, or no key.
    Off,
    /// Another app already holds this combination.
    InUse,
    /// Another Nova shortcut has the same combination.
    Duplicate,
    /// Not a combination the OS can register.
    Invalid,
    /// Ctrl+Alt+key types a character on one of the keyboard layouts.
    TypesCharacter,
    /// Global shortcuts can't be registered in this session (Wayland).
    Unsupported,
    /// The action itself isn't in this version.
    NotPorted,
    /// Wayland: handed to the desktop, which hasn't answered yet (it may be
    /// showing its own dialog).
    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    Pending,
    /// Wayland: the desktop took the others but left this one out.
    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    Refused,
}

/// Wayland: where the GlobalShortcuts portal stands. Absent from the report
/// wherever it isn't used (X11, Windows, or no portal).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub enum PortalState {
    /// Asked; the desktop may be showing its own dialog.
    Pending,
    /// The desktop holds the shortcuts and says when one is pressed.
    Active,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ActionStatus {
    pub id: &'static str,
    pub status: Status,
    /// The character a `TypesCharacter` combination types.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub typed: Option<String>,
    /// Wayland: the keys the desktop says run it, in its own words. It may
    /// let the user pick other keys than the ones Nova asked for.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trigger: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    pub actions: Vec<ActionStatus>,
    /// Why nothing could be registered at all, when that is the case.
    pub blocked: Option<String>,
    /// The command a desktop's own shortcut settings can run instead:
    /// `<this executable> --shortcut <action id>`.
    pub command: String,
    /// Wayland: the shortcuts went to the desktop through its portal.
    pub portal: Option<PortalState>,
}

/// What is registered right now: hot-key id → action id, plus the last report.
#[derive(Default)]
pub struct Registry {
    by_id: Mutex<HashMap<u32, &'static str>>,
    report: Mutex<Vec<ActionStatus>>,
    portal: Mutex<Option<PortalState>>,
    #[cfg(target_os = "linux")]
    wayland: Mutex<wayland::Link>,
}

// ── Pure helpers ──────────────────────────────────────────────────────────────

/// Parses an accelerator the way the plugin will. `None` for an empty or
/// unknown one, and for a bare or Shift-only key: a global shortcut needs
/// Ctrl, Alt or the Windows key, or it would take that key away from every
/// other app (same rule as parseKeys in src/core/shortcuts.ts).
pub fn parse(keys: &str) -> Option<Shortcut> {
    if keys.trim().is_empty() {
        return None;
    }
    let shortcut = Shortcut::from_str(keys).ok()?;
    let has_modifier = shortcut
        .mods
        .intersects(Modifiers::CONTROL | Modifiers::ALT | Modifiers::SUPER | Modifiers::META);
    (has_modifier && shortcut.key != Code::Escape).then_some(shortcut)
}

/// True when Windows reads the combination as AltGr: Ctrl and Alt held, no
/// Windows key.
pub fn is_altgr_like(shortcut: &Shortcut) -> bool {
    shortcut.mods.contains(Modifiers::CONTROL | Modifiers::ALT)
        && !shortcut.mods.intersects(Modifiers::SUPER | Modifiers::META)
}

/// The Windows virtual-key code global-hotkey registers for `code`, for the
/// keys that can type a character. Others (arrows, F-keys…) never do: `None`.
pub fn character_vk(code: Code) -> Option<u16> {
    use Code::*;
    let letters = [
        KeyA, KeyB, KeyC, KeyD, KeyE, KeyF, KeyG, KeyH, KeyI, KeyJ, KeyK, KeyL, KeyM, KeyN,
        KeyO, KeyP, KeyQ, KeyR, KeyS, KeyT, KeyU, KeyV, KeyW, KeyX, KeyY, KeyZ,
    ];
    if let Some(i) = letters.iter().position(|c| *c == code) {
        return Some(0x41 + i as u16);
    }
    let digits = [Digit0, Digit1, Digit2, Digit3, Digit4, Digit5, Digit6, Digit7, Digit8, Digit9];
    if let Some(i) = digits.iter().position(|c| *c == code) {
        return Some(0x30 + i as u16);
    }
    Some(match code {
        Space => 0x20,
        Semicolon => 0xBA,
        Equal => 0xBB,
        Comma => 0xBC,
        Minus => 0xBD,
        Period => 0xBE,
        Slash => 0xBF,
        Backquote => 0xC0,
        BracketLeft => 0xDB,
        Backslash => 0xDC,
        BracketRight => 0xDD,
        Quote => 0xDE,
        IntlBackslash => 0xE2,
        _ => return None,
    })
}

/// What each action should do, before the OS is asked anything: the shortcut
/// to register, or the reason it won't be. `types` answers whether a Ctrl+Alt
/// combination types a character (see platform::ctrl_alt_types).
pub fn plan(
    stored: &Bindings,
    types: impl Fn(&Shortcut) -> Option<String>,
) -> Vec<(&'static ActionDef, Result<Shortcut, ActionStatus>)> {
    let mut seen = HashSet::new();
    ACTIONS
        .iter()
        .map(|def| {
            let refuse = |status, typed| Err(ActionStatus { id: def.id, status, typed, trigger: None });
            let binding = effective(def, stored);
            let outcome = if !def.ported {
                refuse(Status::NotPorted, None)
            } else if !binding.enabled || binding.keys.trim().is_empty() {
                refuse(Status::Off, None)
            } else {
                match parse(&binding.keys) {
                    None => refuse(Status::Invalid, None),
                    Some(shortcut) => {
                        if let Some(typed) = types(&shortcut) {
                            refuse(Status::TypesCharacter, Some(typed))
                        } else if !seen.insert(shortcut.id()) {
                            refuse(Status::Duplicate, None)
                        } else {
                            Ok(shortcut)
                        }
                    }
                }
            };
            (def, outcome)
        })
        .collect()
}

/// `nova --shortcut <id>` → the action id, when it names a ported one.
pub fn from_args(args: &[String]) -> Option<&'static str> {
    let at = args.iter().position(|a| a == "--shortcut")?;
    let def = find(args.get(at + 1)?)?;
    def.ported.then_some(def.id)
}

// ── Registration ──────────────────────────────────────────────────────────────

/// The plugin, with every press routed through `dispatch`.
pub fn plugin<R: Runtime>() -> tauri::plugin::TauriPlugin<R> {
    tauri_plugin_global_shortcut::Builder::new()
        .with_handler(|app, shortcut, event| {
            if event.state != ShortcutState::Pressed {
                return;
            }
            let Some(registry) = app.try_state::<Registry>() else { return };
            let action = registry.by_id.lock().unwrap().get(&shortcut.id()).copied();
            if let Some(action) = action {
                dispatch(app, action);
            }
        })
        .build()
}

/// Hands an action to the island.
pub fn dispatch<R: Runtime>(app: &AppHandle<R>, action: &str) {
    if action == "killEngine" { crate::engine::kill_switch(); return; }
    crate::log::line(format!("shortcut {action}"));
    if action == "wardrobeToggle" {
        let _ = app.emit_to(WINDOW_LABEL, "open-wardrobe", ());
    } else {
        let _ = app.emit_to(WINDOW_LABEL, "shortcut", action.to_string());
    }
}

/// Unregisters everything Nova holds.
fn release<R: Runtime>(app: &AppHandle<R>) {
    if let Some(gs) = app.try_state::<GlobalShortcut<R>>() {
        if let Err(err) = gs.unregister_all() {
            crate::log::line(format!("shortcuts: unregister failed: {err}"));
        }
    }
    if let Some(registry) = app.try_state::<Registry>() {
        registry.by_id.lock().unwrap().clear();
    }
}

/// Registers the shortcuts in `stored` in place of the current ones, and
/// tells the settings window how each one went. Never fails: a shortcut that
/// can't be had is reported, not fatal.
pub fn apply<R: Runtime>(app: &AppHandle<R>, stored: &Bindings) {
    release(app);
    let blocked = crate::platform::global_shortcuts_blocked();
    let plan = plan(stored, typed_character);
    // Wayland: to the desktop's portal when there is one. Without one, as
    // below: every shortcut unsupported, and Settings shows the commands to
    // bind by hand.
    #[cfg(target_os = "linux")]
    if blocked == Some("wayland") && wayland::bind(app, stored, &plan) {
        return;
    }
    let gs = app.try_state::<GlobalShortcut<R>>();

    let mut by_id = HashMap::new();
    let mut report = Vec::new();
    for (def, outcome) in plan {
        let status = match outcome {
            Err(status) => status,
            Ok(_) if blocked.is_some() || gs.is_none() => {
                ActionStatus { id: def.id, status: Status::Unsupported, typed: None, trigger: None }
            }
            Ok(shortcut) => {
                // No lock of ours is held here: the plugin calls our handler
                // with its own lock taken, on the thread that registers.
                let result = gs.as_ref().map(|gs| gs.register(shortcut));
                let status = match result {
                    Some(Ok(())) => {
                        by_id.insert(shortcut.id(), def.id);
                        Status::Active
                    }
                    Some(Err(err)) => {
                        crate::log::line(format!("shortcuts: {} not registered: {err}", def.id));
                        Status::InUse
                    }
                    None => Status::Unsupported,
                };
                ActionStatus { id: def.id, status, typed: None, trigger: None }
            }
        };
        report.push(status);
    }

    if let Some(registry) = app.try_state::<Registry>() {
        *registry.by_id.lock().unwrap() = by_id;
        *registry.report.lock().unwrap() = report;
        *registry.portal.lock().unwrap() = None;
    }
    let _ = app.emit("shortcuts-status", status(app));
}

/// Lets go of every shortcut while a new one is being recorded in Settings,
/// so pressing a combination Nova already holds records it instead of
/// running it.
pub fn suspend<R: Runtime>(app: &AppHandle<R>) {
    release(app);
    #[cfg(target_os = "linux")]
    wayland::release(app);
}

pub fn status<R: Runtime>(app: &AppHandle<R>) -> Report {
    let registry = app.try_state::<Registry>();
    let actions = registry.as_ref().map(|r| r.report.lock().unwrap().clone()).unwrap_or_default();
    let portal = registry.as_ref().and_then(|r| *r.portal.lock().unwrap());
    Report {
        actions,
        blocked: crate::platform::global_shortcuts_blocked().map(str::to_string),
        command: format!("{} --shortcut", launch_command()),
        portal,
    }
}

/// How a desktop shortcut should start us: the AppImage when we run from one
/// (the mounted executable moves on every launch), this executable otherwise.
fn launch_command() -> String {
    let exe = std::env::var_os("APPIMAGE")
        .map(std::path::PathBuf::from)
        .or_else(|| std::env::current_exe().ok())
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|| "nova".to_string());
    if exe.contains(' ') {
        format!("\"{exe}\"")
    } else {
        exe
    }
}

fn typed_character(shortcut: &Shortcut) -> Option<String> {
    if !is_altgr_like(shortcut) {
        return None;
    }
    let vk = character_vk(shortcut.key)?;
    crate::platform::ctrl_alt_types(vk, shortcut.mods.contains(Modifiers::SHIFT))
}

// ── Wayland: the GlobalShortcuts portal ───────────────────────────────────────

/// Glue between `apply` and the portal thread (portal.rs). Each `bind` gets a
/// new generation; an answer to an older one is dropped, so a slow desktop
/// dialog can't overwrite what the latest settings asked for.
#[cfg(target_os = "linux")]
mod wayland {
    use super::*;
    use crate::portal::{self, Bound, Event, Wanted};

    /// The portal thread, once started.
    #[derive(Default)]
    pub enum Link {
        #[default]
        NotStarted,
        Running { handle: portal::Handle, gen: u64 },
        /// No portal (or no session bus): today's commands instead, for the
        /// rest of the run.
        Gone,
    }

    /// Hands the planned shortcuts to the desktop. False when there is no
    /// portal to hand them to; `apply` then carries on as before.
    pub fn bind<R: Runtime>(
        app: &AppHandle<R>,
        stored: &Bindings,
        plan: &[(&'static ActionDef, Result<Shortcut, ActionStatus>)],
    ) -> bool {
        let Some(registry) = app.try_state::<Registry>() else { return false };
        // Held until the request is sent, so the thread's answer (on_event
        // takes this lock too) always lands after the Pending report below.
        let mut link = registry.wayland.lock().unwrap();
        if matches!(*link, Link::Gone) {
            return false;
        }
        let wanted: Vec<Wanted> = plan
            .iter()
            .filter(|(_, outcome)| outcome.is_ok())
            .map(|(def, _)| Wanted {
                    id: def.id.to_string(),
                    description: crate::i18n::t(description(def.id)),
                    trigger: portal::xdg_trigger(&effective(def, stored).keys),
            })
            .collect();
        *registry.report.lock().unwrap() = plan
            .iter()
            .map(|(def, outcome)| match outcome {
                Err(status) => status.clone(),
                Ok(_) => ActionStatus { id: def.id, status: Status::Pending, typed: None, trigger: None },
            })
            .collect();
        *registry.portal.lock().unwrap() = Some(PortalState::Pending);

        if matches!(*link, Link::NotStarted) {
            let events = app.clone();
            *link = match portal::start(move |event| on_event(&events, event)) {
                Some(handle) => Link::Running { handle, gen: 0 },
                None => Link::Gone,
            };
        }
        let Link::Running { handle, gen } = &mut *link else { return false };
        *gen += 1;
        if !handle.bind(*gen, wanted) {
            *link = Link::Gone;
            return false;
        }
        drop(link);
        let _ = app.emit("shortcuts-status", status(app));
        true
    }

    /// Gives the shortcuts back to the desktop while Settings records a new
    /// one; the next `apply` binds them again.
    pub fn release<R: Runtime>(app: &AppHandle<R>) {
        let Some(registry) = app.try_state::<Registry>() else { return };
        let mut link = registry.wayland.lock().unwrap();
        if let Link::Running { handle, gen } = &mut *link {
            *gen += 1;
            handle.release();
        }
    }

    /// What the portal thread says. Runs on that thread.
    fn on_event<R: Runtime>(app: &AppHandle<R>, event: Event) {
        let Some(registry) = app.try_state::<Registry>() else { return };
        if let Event::Activated(id) = &event {
            if let Some(def) = find(id).filter(|d| d.ported) {
                dispatch(app, def.id);
            }
            return;
        }
        let mut link = registry.wayland.lock().unwrap();
        let current = match &*link {
            Link::Running { gen, .. } => *gen,
            _ => 0,
        };
        {
            let mut report = registry.report.lock().unwrap();
            let mut portal = registry.portal.lock().unwrap();
            match event {
                Event::Bound { gen, shortcuts } if gen == current => {
                    crate::log::line("shortcuts: registered with the desktop portal");
                    mark_bound(&mut report, shortcuts.as_deref());
                    *portal = Some(PortalState::Active);
                }
                Event::Changed { gen, shortcuts } if gen == current => mark_changed(&mut report, &shortcuts),
                Event::Failed { gen, reason } if gen == current => {
                    crate::log::line(format!("shortcuts: the desktop portal didn't take them: {reason}"));
                    mark_failed(&mut report);
                    *portal = None;
                }
                Event::Unavailable(reason) => {
                    crate::log::line(format!("shortcuts: no portal, commands instead ({reason})"));
                    *link = Link::Gone;
                    mark_failed(&mut report);
                    *portal = None;
                }
                _ => return,
            }
        }
        drop(link);
        let _ = app.emit("shortcuts-status", status(app));
    }

    fn handed_over(status: Status) -> bool {
        matches!(status, Status::Pending | Status::Active | Status::Refused)
    }

    /// The desktop answered: each shortcut it lists is active, with its keys;
    /// one it left out is refused. `None`: it didn't list them, so all are.
    pub fn mark_bound(report: &mut [ActionStatus], shortcuts: Option<&[Bound]>) {
        for st in report.iter_mut().filter(|st| handed_over(st.status)) {
            let bound = match shortcuts {
                None => Some(None),
                Some(list) => list.iter().find(|b| b.id == st.id).map(|b| b.trigger.clone()),
            };
            match bound {
                Some(trigger) => {
                    st.status = Status::Active;
                    st.trigger = trigger;
                }
                None => {
                    st.status = Status::Refused;
                    st.trigger = None;
                }
            }
        }
    }

    /// The user gave some shortcuts other keys in the desktop's settings.
    pub fn mark_changed(report: &mut [ActionStatus], shortcuts: &[Bound]) {
        for st in report.iter_mut().filter(|st| handed_over(st.status)) {
            if let Some(b) = shortcuts.iter().find(|b| b.id == st.id) {
                st.status = Status::Active;
                st.trigger = b.trigger.clone();
            }
        }
    }

    /// No portal after all: what a Wayland session showed before it.
    pub fn mark_failed(report: &mut [ActionStatus]) {
        for st in report.iter_mut().filter(|st| handed_over(st.status)) {
            st.status = Status::Unsupported;
            st.trigger = None;
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        fn report() -> Vec<ActionStatus> {
            plan(&Bindings::new(), |_| None)
                .into_iter()
                .map(|(def, outcome)| match outcome {
                    Err(status) => status,
                    Ok(_) => ActionStatus { id: def.id, status: Status::Pending, typed: None, trigger: None },
                })
                .collect()
        }

        fn of<'a>(report: &'a [ActionStatus], id: &str) -> &'a ActionStatus {
            report.iter().find(|s| s.id == id).unwrap()
        }

        fn bound(id: &str, trigger: Option<&str>) -> Bound {
            Bound { id: id.into(), trigger: trigger.map(str::to_string) }
        }

        #[test]
        fn the_desktop_answer_marks_each_shortcut() {
            let mut r = report();
            let answer = [bound("openChat", Some("Ctrl+Alt+Space")), bound("goToAlert", None)];
            mark_bound(&mut r, Some(&answer));
            assert_eq!(of(&r, "openChat").status, Status::Active);
            assert_eq!(of(&r, "openChat").trigger.as_deref(), Some("Ctrl+Alt+Space"));
            assert_eq!(of(&r, "goToAlert").status, Status::Active);
            assert_eq!(of(&r, "goToAlert").trigger, None);
            // Left out of the answer.
            assert_eq!(of(&r, "muteToggle").status, Status::Refused);
            assert_eq!(of(&r, "desktopToggle").status, Status::Refused);
            // Never handed over: untouched.
            assert_eq!(of(&r, "toggleIsland").status, Status::Off);
            assert_eq!(of(&r, "attachFrontWindow").status, Status::NotPorted);
        }

        #[test]
        fn an_answer_without_a_list_takes_them_all() {
            let mut r = report();
            mark_bound(&mut r, None);
            assert!(r.iter().all(|s| matches!(s.status, Status::Active | Status::Off | Status::NotPorted)));
            assert_eq!(of(&r, "nextPill").status, Status::Active);
        }

        #[test]
        fn new_keys_from_the_desktop_replace_the_old_ones() {
            let mut r = report();
            mark_bound(&mut r, Some(&[bound("openChat", Some("Ctrl+Alt+Space"))]));
            mark_changed(&mut r, &[bound("openChat", Some("Meta+C")), bound("muteToggle", Some("Meta+M"))]);
            assert_eq!(of(&r, "openChat").trigger.as_deref(), Some("Meta+C"));
            assert_eq!(of(&r, "muteToggle").status, Status::Active);
            assert_eq!(of(&r, "muteToggle").trigger.as_deref(), Some("Meta+M"));
            assert_eq!(of(&r, "toggleIsland").status, Status::Off);
        }

        #[test]
        fn a_failure_goes_back_to_unsupported() {
            let mut r = report();
            mark_bound(&mut r, Some(&[bound("openChat", Some("Ctrl+Alt+Space"))]));
            mark_failed(&mut r);
            for s in &r {
                assert!(matches!(s.status, Status::Unsupported | Status::Off | Status::NotPorted), "{}", s.id);
                assert_eq!(s.trigger, None);
            }
            assert_eq!(of(&r, "openChat").status, Status::Unsupported);
        }

        #[test]
        fn every_action_has_a_description() {
            for def in ACTIONS {
                assert_ne!(description(def.id), "Nova", "{}", def.id);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MAC_IDS: [&str; 10] = [
        "toggleIsland", "openChat", "goToAlert", "jumpToTerminal", "attachFrontWindow",
        "nextPill", "prevPill", "muteToggle", "desktopToggle", "wardrobeToggle",
    ];

    fn never(_: &Shortcut) -> Option<String> {
        None
    }

    // testDefaultsExhaustive
    #[test]
    fn every_mac_action_has_a_default_and_keeps_its_id() {
        let ids: Vec<_> = ACTIONS.iter().map(|a| a.id).collect();
        assert_eq!(ids, MAC_IDS);
    }

    // testAllDefaultsHaveModifier
    #[test]
    fn every_default_parses_and_has_a_modifier() {
        for def in ACTIONS {
            let shortcut = parse(def.default_keys)
                .unwrap_or_else(|| panic!("{} default does not parse", def.id));
            assert!(is_altgr_like(&shortcut), "{} default is not Ctrl+Alt", def.id);
        }
    }

    // testNoDefaultDuplicates
    #[test]
    fn no_two_defaults_share_a_combination() {
        let mut seen = HashSet::new();
        for def in ACTIONS {
            assert!(seen.insert(parse(def.default_keys).unwrap().id()), "{} duplicates", def.id);
        }
    }

    // testEnabledByDefault
    #[test]
    fn only_the_island_toggle_is_off_by_default() {
        for def in ACTIONS {
            assert_eq!(def.enabled_by_default, def.id != "toggleIsland", "{}", def.id);
        }
    }

    #[test]
    fn the_action_not_ported_yet_is_reserved_not_registered() {
        let plan = plan(&Bindings::new(), never);
        for (def, outcome) in plan {
            let reserved = def.id == "attachFrontWindow";
            assert_eq!(def.ported, !reserved);
            match outcome {
                Ok(_) => assert!(def.ported && def.enabled_by_default, "{}", def.id),
                Err(s) if reserved => assert_eq!(s.status, Status::NotPorted),
                Err(s) => assert_eq!((def.id, s.status), ("toggleIsland", Status::Off)),
            }
        }
    }

    #[test]
    fn parsing_needs_a_modifier_and_a_known_key() {
        assert!(parse("").is_none());
        assert!(parse("A").is_none(), "a bare key would take A from every app");
        assert!(parse("Shift+A").is_none(), "so would Shift+A");
        assert!(parse("Ctrl+Escape").is_none());
        assert!(parse("Ctrl+Alt+Nope").is_none());
        assert!(parse("Ctrl+Alt").is_none());
        let s = parse("Ctrl+Alt+Space").unwrap();
        assert_eq!(s.key, Code::Space);
        assert!(s.mods.contains(Modifiers::CONTROL | Modifiers::ALT));
        assert!(!s.mods.contains(Modifiers::SHIFT));
        let all = parse("Ctrl+Alt+Shift+Super+K").unwrap();
        assert!(all.mods.contains(Modifiers::CONTROL | Modifiers::ALT | Modifiers::SHIFT | Modifiers::SUPER));
        // Case and spelling don't change the combination.
        assert_eq!(parse("ctrl+alt+right").unwrap().id(), parse("Control+Alt+ArrowRight").unwrap().id());
    }

    #[test]
    fn only_ctrl_alt_without_the_windows_key_reads_as_altgr() {
        assert!(is_altgr_like(&parse("Ctrl+Alt+E").unwrap()));
        assert!(is_altgr_like(&parse("Ctrl+Alt+Shift+E").unwrap()));
        assert!(!is_altgr_like(&parse("Ctrl+Shift+E").unwrap()));
        assert!(!is_altgr_like(&parse("Ctrl+Alt+Super+E").unwrap()));
    }

    #[test]
    fn virtual_keys_match_the_ones_registered() {
        assert_eq!(character_vk(Code::KeyA), Some(0x41));
        assert_eq!(character_vk(Code::KeyZ), Some(0x5A));
        assert_eq!(character_vk(Code::Digit0), Some(0x30));
        assert_eq!(character_vk(Code::Digit9), Some(0x39));
        assert_eq!(character_vk(Code::BracketRight), Some(0xDD));
        assert_eq!(character_vk(Code::Space), Some(0x20));
        assert_eq!(character_vk(Code::ArrowLeft), None);
        assert_eq!(character_vk(Code::F5), None);
    }

    // testDuplicateDetection
    #[test]
    fn a_combination_used_twice_is_registered_once() {
        let mut stored = Bindings::new();
        let same = Binding { keys: "Ctrl+Alt+A".into(), enabled: true };
        stored.insert("jumpToTerminal".into(), same.clone());
        let plan = plan(&stored, never);
        let alert = plan.iter().find(|(d, _)| d.id == "goToAlert").unwrap();
        let term = plan.iter().find(|(d, _)| d.id == "jumpToTerminal").unwrap();
        assert!(alert.1.is_ok());
        assert_eq!(term.1.as_ref().unwrap_err().status, Status::Duplicate);

        // Same key, other modifiers: not a duplicate.
        stored.insert("jumpToTerminal".into(), Binding { keys: "Ctrl+Shift+A".into(), enabled: true });
        let plan = super::plan(&stored, never);
        assert!(plan.iter().all(|(d, o)| o.is_ok() || !d.ported || d.id == "toggleIsland"));

        // A disabled action doesn't hold its keys.
        stored.insert("goToAlert".into(), Binding { keys: "Ctrl+Alt+A".into(), enabled: false });
        stored.insert("jumpToTerminal".into(), same);
        let plan = super::plan(&stored, never);
        let term = plan.iter().find(|(d, _)| d.id == "jumpToTerminal").unwrap();
        assert!(term.1.is_ok());
    }

    #[test]
    fn a_combination_that_types_a_character_is_not_registered() {
        let euro = |s: &Shortcut| (s.key == Code::KeyA).then(|| "ą".to_string());
        let plan = plan(&Bindings::new(), euro);
        let alert = plan.iter().find(|(d, _)| d.id == "goToAlert").unwrap();
        let refused = alert.1.as_ref().unwrap_err();
        assert_eq!(refused.status, Status::TypesCharacter);
        assert_eq!(refused.typed.as_deref(), Some("ą"));
    }

    #[test]
    fn stored_bindings_override_the_defaults_and_the_rest_fall_back() {
        let mut stored = Bindings::new();
        stored.insert("openChat".into(), Binding { keys: "Ctrl+Shift+K".into(), enabled: true });
        stored.insert("muteToggle".into(), Binding { keys: String::new(), enabled: true });
        let chat = effective(find("openChat").unwrap(), &stored);
        assert_eq!(chat.keys, "Ctrl+Shift+K");
        let alert = effective(find("goToAlert").unwrap(), &stored);
        assert_eq!(alert, Binding { keys: "Ctrl+Alt+A".into(), enabled: true });
        let toggle = effective(find("toggleIsland").unwrap(), &stored);
        assert!(!toggle.enabled);
        let plan = plan(&stored, never);
        let mute = plan.iter().find(|(d, _)| d.id == "muteToggle").unwrap();
        assert_eq!(mute.1.as_ref().unwrap_err().status, Status::Off);
    }

    // testLoadSaveRoundTrip
    #[test]
    fn bindings_round_trip_through_json() {
        let mut stored = Bindings::new();
        stored.insert("openChat".into(), Binding { keys: "Ctrl+Alt+K".into(), enabled: false });
        let json = serde_json::to_string(&stored).unwrap();
        assert_eq!(json, r#"{"openChat":{"keys":"Ctrl+Alt+K","enabled":false}}"#);
        assert_eq!(serde_json::from_str::<Bindings>(&json).unwrap(), stored);
        // A hand-edited entry without `enabled` stays on.
        let partial: Bindings = serde_json::from_str(r#"{"openChat":{"keys":"Ctrl+Alt+K"}}"#).unwrap();
        assert!(partial["openChat"].enabled);
    }

    #[test]
    fn the_command_line_names_an_action() {
        let args = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(from_args(&args(&["nova", "--shortcut", "openChat"])), Some("openChat"));
        assert_eq!(from_args(&args(&["nova", "--shortcut", "wardrobeToggle"])), Some("wardrobeToggle"));
        assert_eq!(from_args(&args(&["nova", "--shortcut"])), None);
        assert_eq!(from_args(&args(&["nova", "--shortcut", "rm -rf"])), None);
        assert_eq!(from_args(&args(&["nova", "--shortcut", "desktopToggle"])), Some("desktopToggle"));
        assert_eq!(from_args(&args(&["nova", "--shortcut", "attachFrontWindow"])), None);
        assert_eq!(from_args(&args(&["nova"])), None);
    }
}
