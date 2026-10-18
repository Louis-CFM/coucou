// Flow dictation on Wayland, where no app may watch the keyboard or type into
// another one.
//
// The key: a shortcut held through the desktop's GlobalShortcuts portal
// (portal.rs). The desktop tells when it is pressed (Activated) and released
// (Deactivated), which is all hold-to-talk needs; the user picks the keys in
// the desktop's own dialog, Ctrl+Alt+V suggested.
//
// The paste: Ctrl+V sent through the RemoteDesktop portal, keyboard only. The
// desktop asks once whether Coucou may control the keyboard; the answer is
// remembered with the restore token the portal gives back, kept in Coucou's
// folder. Where neither works, the words stay on the clipboard and the pill
// says so.

use std::collections::HashMap;
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use dbus::arg::{PropMap, RefArg, Variant};
use dbus::blocking::{BlockingSender, Connection};
use dbus::message::MatchRule;
use dbus::Path;

use super::KeyEvent;
use crate::portal;

pub const SHORTCUT_ID: &str = "flowDictate";

/// The portal session holding the dictation shortcut; dropping it gives the
/// shortcut back.
pub struct HoldKey {
    _handle: portal::Handle,
}

pub fn listen(tx: Sender<(KeyEvent, Instant)>) -> Option<HoldKey> {
    let handle = portal::start(move |event| match event {
        portal::Event::Activated(id) if id == SHORTCUT_ID => {
            let _ = tx.send((KeyEvent::Down, Instant::now()));
        }
        portal::Event::Deactivated(id) if id == SHORTCUT_ID => {
            let _ = tx.send((KeyEvent::Up, Instant::now()));
        }
        portal::Event::Bound { .. } => crate::log::line("flow: dictation shortcut held by the desktop"),
        portal::Event::Failed { reason, .. } | portal::Event::Unavailable(reason) => {
            crate::log::line(format!("flow: no dictation shortcut from the desktop ({reason})"));
        }
        _ => {}
    })?;
    let wanted = portal::Wanted {
        id: SHORTCUT_ID.into(),
        description: crate::i18n::t("Hold to dictate"),
        trigger: Some("CTRL+ALT+v".into()),
    };
    if !handle.bind(1, vec![wanted]) {
        return None;
    }
    Some(HoldKey { _handle: handle })
}

// ── The paste ─────────────────────────────────────────────────────────────────

const DEST: &str = "org.freedesktop.portal.Desktop";
const OBJECT: &str = "/org/freedesktop/portal/desktop";
const IFACE: &str = "org.freedesktop.portal.RemoteDesktop";
/// Keysyms of Ctrl, Shift and v.
const XK_CONTROL_L: i32 = 0xffe3;
const XK_SHIFT_L: i32 = 0xffe1;
const XK_V: i32 = 0x0076;

struct Remote {
    conn: Connection,
    session: String,
}

/// The RemoteDesktop session, opened on the first paste and kept.
static REMOTE: Mutex<Option<Remote>> = Mutex::new(None);
/// Refused once: not asked again until Coucou restarts.
static REFUSED: Mutex<bool> = Mutex::new(false);

fn token_file() -> std::path::PathBuf {
    super::store::Store::folder().join("remote-desktop-token")
}

fn variant<T: RefArg + 'static>(v: T) -> Variant<Box<dyn RefArg>> {
    Variant(Box::new(v))
}

/// Calls `method` with a request token and waits for its Response (the user
/// may have a dialog to answer). The results, or why there are none.
fn request(conn: &Connection, method: &str, args: impl FnOnce(&str) -> dbus::Message, tokens: &mut u32) -> Result<PropMap, String> {
    *tokens += 1;
    let token = format!("coucoupaste{}_{}", std::process::id(), tokens);
    let sender = conn.unique_name().to_string();
    let path = portal::request_path(&sender, &token);
    let answer: Arc<Mutex<Option<Result<PropMap, u32>>>> = Arc::new(Mutex::new(None));
    let slot = answer.clone();
    let rule = MatchRule::new_signal("org.freedesktop.portal.Request", "Response").with_path(Path::from(path.clone()));
    let id = conn
        .add_match(rule, move |(): (), _, msg| {
            *slot.lock().unwrap() = Some(portal::parse_response(msg));
            false
        })
        .map_err(|e| e.to_string())?;
    let msg = args(&token);
    conn.send_with_reply_and_block(msg, Duration::from_secs(10)).map_err(|e| format!("{method}: {e}"))?;
    let until = Instant::now() + Duration::from_secs(120);
    while answer.lock().unwrap().is_none() && Instant::now() < until {
        conn.process(Duration::from_millis(200)).map_err(|e| e.to_string())?;
    }
    let _ = conn.remove_match(id);
    let result = answer.lock().unwrap().take();
    match result {
        Some(Ok(results)) => Ok(results),
        Some(Err(code)) => Err(format!("{method} refused ({code})")),
        None => Err(format!("{method}: no answer")),
    }
}

fn open() -> Result<Remote, String> {
    let conn = Connection::new_session().map_err(|e| e.to_string())?;
    let mut tokens = 0;
    let call = |member: &str| dbus::Message::new_method_call(DEST, OBJECT, IFACE, member).map_err(|e| e.to_string());

    let session_token = format!("coucoupastes{}", std::process::id());
    let create = call("CreateSession")?;
    let results = request(&conn, "CreateSession", |token| {
        let mut options: PropMap = HashMap::new();
        options.insert("handle_token".into(), variant(token.to_string()));
        options.insert("session_handle_token".into(), variant(session_token.clone()));
        create.append1(options)
    }, &mut tokens)?;
    let session = portal::session_from_results(&results).ok_or("no session")?;

    let restore = std::fs::read_to_string(token_file()).ok().filter(|t| !t.trim().is_empty());
    let select = call("SelectDevices")?;
    request(&conn, "SelectDevices", |token| {
        let mut options: PropMap = HashMap::new();
        options.insert("handle_token".into(), variant(token.to_string()));
        options.insert("types".into(), variant(1u32)); // keyboard
        options.insert("persist_mode".into(), variant(2u32)); // until revoked
        if let Some(restore) = &restore {
            options.insert("restore_token".into(), variant(restore.trim().to_string()));
        }
        select.append2(Path::from(session.clone()), options)
    }, &mut tokens)?;

    let start = call("Start")?;
    let results = request(&conn, "Start", |token| {
        let mut options: PropMap = HashMap::new();
        options.insert("handle_token".into(), variant(token.to_string()));
        start.append3(Path::from(session.clone()), "", options)
    }, &mut tokens)?;
    if let Some(token) = results.get("restore_token").and_then(|v| v.0.as_str()) {
        let _ = crate::platform::ensure_private_dir(&super::store::Store::folder());
        let _ = std::fs::write(token_file(), token);
    }
    Ok(Remote { conn, session })
}

fn key(remote: &Remote, keysym: i32, pressed: bool) -> Result<(), String> {
    let msg = dbus::Message::new_method_call(DEST, OBJECT, IFACE, "NotifyKeyboardKeysym")
        .map_err(|e| e.to_string())?
        .append3(Path::from(remote.session.clone()), PropMap::new(), keysym)
        .append1(pressed as u32);
    remote.conn.send_with_reply_and_block(msg, Duration::from_secs(5)).map_err(|e| e.to_string())?;
    Ok(())
}

/// Ctrl+V (Ctrl+Shift+V) through the RemoteDesktop portal.
pub fn send_paste(shift: bool) -> Result<(), String> {
    if *REFUSED.lock().unwrap() {
        return Err("remote desktop refused".into());
    }
    let mut slot = REMOTE.lock().unwrap();
    if slot.is_none() {
        match open() {
            Ok(r) => *slot = Some(r),
            Err(err) => {
                *REFUSED.lock().unwrap() = true;
                return Err(err);
            }
        }
    }
    let remote = slot.as_ref().unwrap();
    let mut seq = vec![(XK_CONTROL_L, true)];
    if shift {
        seq.push((XK_SHIFT_L, true));
    }
    seq.extend([(XK_V, true), (XK_V, false)]);
    if shift {
        seq.push((XK_SHIFT_L, false));
    }
    seq.push((XK_CONTROL_L, false));
    for (sym, down) in seq {
        if let Err(err) = key(remote, sym, down) {
            // The session ended (the user revoked it): open a new one next time.
            *slot = None;
            return Err(err);
        }
    }
    Ok(())
}
