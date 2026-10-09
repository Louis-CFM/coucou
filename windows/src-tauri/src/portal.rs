// Global shortcuts on Wayland, through the XDG desktop portal
// (org.freedesktop.portal.GlobalShortcuts): KDE Plasma 6, GNOME 48+,
// Hyprland's portal, COSMIC…
//
// Wayland lets no app grab keys, so the desktop holds the shortcuts and tells
// us when one is pressed. The exchange, all on the session bus:
//
//   CreateSession({handle_token, session_handle_token})  → Request → Response
//   BindShortcuts(session, [(id, {description, preferred_trigger})], "", {handle_token})
//                                                        → Request → Response
//   … then Activated(session, id, timestamp, options) on every press, and
//   ShortcutsChanged(session, shortcuts) when the user picks other keys.
//
// The desktop may show its own dialog to confirm the shortcuts or change their
// keys, so a Response can take as long as the user does: nothing here waits
// for one. Everything runs on one thread that owns the D-Bus connection and
// sleeps in poll() on the bus and a wake-up socket — no timeout, so it costs
// nothing while no key is pressed. Shortcuts.rs talks to it through a Handle
// and hears back through the callback given to `start`; this file knows
// nothing of Tauri.
//
// The D-Bus client is the `dbus` crate (libdbus), which keyring's Secret
// Service support already links.

use std::io::{ErrorKind, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::sync::mpsc::{self, TryRecvError};
use std::time::Duration;

use dbus::arg::{ArgType, PropMap, RefArg, Variant};
use dbus::channel::{BusType, Channel};
use dbus::message::MessageType;
use dbus::strings::Path;
use dbus::Message;
use tauri_plugin_global_shortcut::{Code, Modifiers, Shortcut};

const DEST: &str = "org.freedesktop.portal.Desktop";
const OBJECT: &str = "/org/freedesktop/portal/desktop";
const IFACE: &str = "org.freedesktop.portal.GlobalShortcuts";
const REQUEST: &str = "org.freedesktop.portal.Request";
const SESSION: &str = "org.freedesktop.portal.Session";
/// Tauri's identifier. Told to the portal so the desktop files the shortcuts
/// under Nova rather than under an unnamed app.
const APP_ID: &str = "com.sweety.nova";
/// For the calls themselves, which answer at once: the user's answer comes
/// later, in a Response signal.
const CALL_TIMEOUT: Duration = Duration::from_secs(10);

// ── Pure helpers ──────────────────────────────────────────────────────────────

/// Nova's accelerator ("Ctrl+Alt+Space") → the XDG shortcuts spec's trigger
/// ("CTRL+ALT+space"): modifiers CTRL, ALT, SHIFT, LOGO, then an xkb keysym
/// name. `None` for a binding that isn't a shortcut, or whose key has no
/// keysym here; the desktop then picks the key, or lets the user pick one.
pub fn xdg_trigger(keys: &str) -> Option<String> {
    trigger_of(&crate::shortcuts::parse(keys)?)
}

fn trigger_of(shortcut: &Shortcut) -> Option<String> {
    let mut parts = Vec::new();
    if shortcut.mods.contains(Modifiers::CONTROL) {
        parts.push("CTRL".to_string());
    }
    if shortcut.mods.contains(Modifiers::ALT) {
        parts.push("ALT".to_string());
    }
    if shortcut.mods.contains(Modifiers::SHIFT) {
        parts.push("SHIFT".to_string());
    }
    if shortcut.mods.intersects(Modifiers::SUPER | Modifiers::META) {
        parts.push("LOGO".to_string());
    }
    parts.push(keysym(shortcut.key)?);
    Some(parts.join("+"))
}

/// The xkb keysym name of the keys an accelerator may name (KEY_NAMES in
/// src/core/shortcuts.ts).
fn keysym(code: Code) -> Option<String> {
    use Code::*;
    let fixed = match code {
        Space => "space",
        Enter => "Return",
        Tab => "Tab",
        Backspace => "BackSpace",
        Delete => "Delete",
        Insert => "Insert",
        Home => "Home",
        End => "End",
        PageUp => "Page_Up",
        PageDown => "Page_Down",
        ArrowUp => "Up",
        ArrowDown => "Down",
        ArrowLeft => "Left",
        ArrowRight => "Right",
        Comma => "comma",
        Period => "period",
        Slash => "slash",
        Semicolon => "semicolon",
        Quote => "apostrophe",
        Backquote => "grave",
        BracketLeft => "bracketleft",
        BracketRight => "bracketright",
        Backslash => "backslash",
        Minus => "minus",
        Equal => "equal",
        _ => "",
    };
    if !fixed.is_empty() {
        return Some(fixed.to_string());
    }
    // KeyA → a, Digit1 → 1, F5 → F5.
    let name = code.to_string();
    if let Some(letter) = name.strip_prefix("Key").filter(|l| l.len() == 1) {
        return Some(letter.to_ascii_lowercase());
    }
    if let Some(digit) = name.strip_prefix("Digit").filter(|d| d.len() == 1) {
        return Some(digit.to_string());
    }
    let function = name
        .strip_prefix('F')
        .and_then(|n| n.parse::<u8>().ok())
        .is_some_and(|n| (1..=24).contains(&n));
    function.then_some(name)
}

/// Where the portal puts the Request object for `token`: the caller's unique
/// name without its colon, dots made underscores.
pub fn request_path(sender: &str, token: &str) -> String {
    format!("{OBJECT}/request/{}/{token}", escape_sender(sender))
}

/// Same rule for the Session object.
pub fn session_path(sender: &str, token: &str) -> String {
    format!("{OBJECT}/session/{}/{token}", escape_sender(sender))
}

fn escape_sender(sender: &str) -> String {
    sender.trim_start_matches(':').replace('.', "_")
}

/// One shortcut handed to the desktop.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Wanted {
    pub id: String,
    pub description: String,
    /// XDG trigger; `None` leaves the key to the desktop.
    pub trigger: Option<String>,
}

/// One shortcut the desktop holds, and the keys it says run it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Bound {
    pub id: String,
    /// `trigger_description`, as the desktop writes it; `None` when it gave
    /// none or an empty one.
    pub trigger: Option<String>,
}

/// The value inside a variant, however deep.
fn unwrap_variant(arg: &dyn RefArg) -> &dyn RefArg {
    let mut arg = arg;
    while arg.arg_type() == ArgType::Variant {
        match arg.as_iter().and_then(|mut inner| inner.next()) {
            Some(inner) => arg = inner,
            None => break,
        }
    }
    arg
}

/// `key` in an `a{sv}` read off the bus.
fn dict_get<'a>(dict: &'a dyn RefArg, key: &str) -> Option<&'a dyn RefArg> {
    let mut items = unwrap_variant(dict).as_iter()?;
    while let (Some(k), Some(v)) = (items.next(), items.next()) {
        if k.as_str() == Some(key) {
            return Some(unwrap_variant(v));
        }
    }
    None
}

/// The `a(sa{sv})` list of BindShortcuts' Response and of ShortcutsChanged.
/// `None` when it isn't one.
pub fn parse_shortcuts(arg: &dyn RefArg) -> Option<Vec<Bound>> {
    let list = unwrap_variant(arg);
    if list.arg_type() != ArgType::Array {
        return None;
    }
    let mut out = Vec::new();
    for item in list.as_iter()? {
        let mut fields = item.as_iter()?;
        let id = fields.next()?.as_str()?.to_string();
        let trigger = fields
            .next()
            .and_then(|props| dict_get(props, "trigger_description"))
            .and_then(|t| t.as_str())
            .map(str::trim)
            .filter(|t| !t.is_empty())
            .map(str::to_string);
        out.push(Bound { id, trigger });
    }
    Some(out)
}

/// A Request's Response: `Ok(results)` when the user went ahead (0), `Err`
/// with the code otherwise (1 cancelled, 2 anything else).
pub fn parse_response(msg: &Message) -> Result<PropMap, u32> {
    match msg.read2::<u32, PropMap>() {
        Ok((0, results)) => Ok(results),
        Ok((code, _)) => Err(code),
        Err(_) => Err(2),
    }
}

/// The session CreateSession made: `session_handle` from its results (a
/// string or an object path, depending on the portal's age).
pub fn session_from_results(results: &PropMap) -> Option<String> {
    let handle = results.get("session_handle")?.0.as_str()?;
    (!handle.is_empty()).then(|| handle.to_string())
}

// ── The portal thread ─────────────────────────────────────────────────────────

/// What the thread tells shortcuts.rs. `gen` is the `bind` call it answers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// The desktop holds the shortcuts. `None` when it didn't say which.
    Bound { gen: u64, shortcuts: Option<Vec<Bound>> },
    /// The user gave some shortcuts other keys.
    Changed { gen: u64, shortcuts: Vec<Bound> },
    /// Refused, failed, or the desktop closed the session.
    Failed { gen: u64, reason: String },
    /// No GlobalShortcuts portal (or no session bus). The thread has stopped.
    Unavailable(String),
    /// A shortcut was pressed.
    Activated(String),
}

enum Command {
    Bind { gen: u64, shortcuts: Vec<Wanted> },
    Release,
}

/// The way to the portal thread. Sending never blocks.
pub struct Handle {
    tx: mpsc::Sender<Command>,
    wake: UnixStream,
}

impl Handle {
    /// Asks the desktop for `shortcuts` in place of the current ones. False
    /// when the thread is gone (no portal).
    pub fn bind(&self, gen: u64, shortcuts: Vec<Wanted>) -> bool {
        self.send(Command::Bind { gen, shortcuts })
    }

    /// Gives every shortcut back (Settings is recording a new one).
    pub fn release(&self) -> bool {
        self.send(Command::Release)
    }

    fn send(&self, command: Command) -> bool {
        if self.tx.send(command).is_err() {
            return false;
        }
        // A full socket means a wake-up is already pending.
        let _ = (&self.wake).write(&[1]);
        true
    }
}

/// Starts the portal thread. It first checks there is a portal to talk to,
/// and says `Unavailable` (then stops) when there isn't.
pub fn start(on_event: impl Fn(Event) + Send + 'static) -> Option<Handle> {
    let (tx, rx) = mpsc::channel();
    let (wake_rx, wake_tx) = UnixStream::pair().ok()?;
    wake_rx.set_nonblocking(true).ok()?;
    wake_tx.set_nonblocking(true).ok()?;
    std::thread::Builder::new()
        .name("shortcuts-portal".into())
        .spawn(move || run(rx, wake_rx, on_event))
        .ok()?;
    Some(Handle { tx, wake: wake_tx })
}

fn run(rx: mpsc::Receiver<Command>, wake: UnixStream, on_event: impl Fn(Event)) {
    let mut portal = match Portal::connect() {
        Ok(portal) => portal,
        Err(why) => return on_event(Event::Unavailable(why)),
    };
    loop {
        loop {
            match rx.try_recv() {
                Ok(command) => portal.command(command, &on_event),
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => return portal.abandon(),
            }
        }
        while let Some(msg) = portal.channel.pop_message() {
            portal.message(&msg, &on_event);
        }
        if !portal.channel.is_connected() {
            return on_event(Event::Unavailable("the session bus went away".into()));
        }
        if let Err(why) = wait(&portal.channel, &wake) {
            portal.abandon();
            return on_event(Event::Unavailable(why));
        }
        // Drain the wake-ups; the commands themselves are in `rx`.
        let mut buf = [0u8; 64];
        while matches!((&wake).read(&mut buf), Ok(n) if n > 0) {}
        if portal.channel.read_write(Some(Duration::ZERO)).is_err() {
            return on_event(Event::Unavailable("the session bus went away".into()));
        }
    }
}

/// Sleeps until the bus or a command has something. No timeout.
fn wait(channel: &Channel, wake: &UnixStream) -> Result<(), String> {
    let watch = channel.watch();
    let mut events = libc::POLLIN;
    if channel.has_messages_to_send() {
        events |= libc::POLLOUT;
    }
    let mut fds = [
        libc::pollfd { fd: watch.fd, events, revents: 0 },
        libc::pollfd { fd: wake.as_raw_fd(), events: libc::POLLIN, revents: 0 },
    ];
    loop {
        let n = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, -1) };
        if n >= 0 {
            return Ok(());
        }
        let err = std::io::Error::last_os_error();
        if err.kind() != ErrorKind::Interrupted {
            return Err(format!("poll: {err}"));
        }
    }
}

/// Where the exchange with the desktop stands.
enum Phase {
    Idle,
    /// CreateSession sent, its Response awaited.
    Creating { gen: u64, request: String, session: String, want: Vec<Wanted> },
    /// BindShortcuts sent; the desktop may be showing its dialog.
    Binding { gen: u64, request: String, session: String, want: Vec<Wanted> },
    Bound { gen: u64, session: String, want: Vec<Wanted>, shortcuts: Option<Vec<Bound>> },
}

struct Portal {
    channel: Channel,
    sender: String,
    tokens: u64,
    phase: Phase,
}

impl Portal {
    fn connect() -> Result<Portal, String> {
        let mut channel = Channel::get_private(BusType::Session).map_err(|e| format!("session bus: {e}"))?;
        channel.set_watch_enabled(true);
        let sender = channel.unique_name().ok_or("no unique name on the session bus")?.to_string();
        let portal = Portal { channel, sender, tokens: 0, phase: Phase::Idle };

        // Names the app to the portal (xdg-desktop-portal 1.19+, apps outside
        // a sandbox). It has to come before any other portal call; an older
        // portal doesn't know it, and then the desktop names us itself.
        if let Err(err) = portal.call(
            method(OBJECT, "org.freedesktop.host.portal.Registry", "Register")?
                .append2(APP_ID, PropMap::new()),
        ) {
            crate::log::line(format!("shortcuts portal: no app registry ({err})"));
        }

        let version = portal
            .call(
                method(OBJECT, "org.freedesktop.DBus.Properties", "Get")?.append2(IFACE, "version"),
            )
            .and_then(|reply| {
                reply.read1::<Variant<u32>>().map(|v| v.0).map_err(|e| e.to_string())
            })
            .map_err(|e| format!("no GlobalShortcuts portal: {e}"))?;
        crate::log::line(format!("shortcuts portal: GlobalShortcuts version {version}"));

        for rule in [
            format!("type='signal',sender='{DEST}',interface='{IFACE}'"),
            format!("type='signal',sender='{DEST}',interface='{REQUEST}',member='Response'"),
            format!("type='signal',sender='{DEST}',interface='{SESSION}',member='Closed'"),
        ] {
            let add = Message::new_method_call(
                "org.freedesktop.DBus",
                "/org/freedesktop/DBus",
                "org.freedesktop.DBus",
                "AddMatch",
            )?
            .append1(rule);
            portal.call(add).map_err(|e| format!("AddMatch: {e}"))?;
        }
        Ok(portal)
    }

    fn call(&self, msg: Message) -> Result<Message, String> {
        self.channel.send_with_reply_and_block(msg, CALL_TIMEOUT).map_err(|e| {
            format!("{}: {}", e.name().unwrap_or("error"), e.message().unwrap_or(""))
        })
    }

    /// A method call we don't wait on (closing a request or a session).
    fn close(&self, path: &str, iface: &str) {
        if let Ok(msg) = Message::new_method_call(DEST, path, iface, "Close") {
            let _ = self.channel.send(msg);
            self.channel.flush();
        }
    }

    fn token(&mut self) -> String {
        self.tokens += 1;
        format!("nova{}_{}", std::process::id(), self.tokens)
    }

    fn gen(&self) -> Option<u64> {
        match &self.phase {
            Phase::Idle => None,
            Phase::Creating { gen, .. } | Phase::Binding { gen, .. } | Phase::Bound { gen, .. } => Some(*gen),
        }
    }

    /// Drops whatever is in flight or bound. The portal may need a new session
    /// to bind other shortcuts, so a change always starts over.
    fn abandon(&mut self) {
        match std::mem::replace(&mut self.phase, Phase::Idle) {
            Phase::Idle => {}
            Phase::Creating { request, session, .. } | Phase::Binding { request, session, .. } => {
                self.close(&request, REQUEST);
                self.close(&session, SESSION);
            }
            Phase::Bound { session, .. } => self.close(&session, SESSION),
        }
    }

    fn command(&mut self, command: Command, on_event: &impl Fn(Event)) {
        match command {
            Command::Release => self.abandon(),
            Command::Bind { gen, shortcuts } => {
                // The same shortcuts as now: nothing to ask the desktop.
                if let Phase::Bound { gen: current, want, shortcuts: bound, .. } = &mut self.phase {
                    if *want == shortcuts {
                        *current = gen;
                        return on_event(Event::Bound { gen, shortcuts: bound.clone() });
                    }
                }
                self.abandon();
                if shortcuts.is_empty() {
                    return on_event(Event::Bound { gen, shortcuts: Some(Vec::new()) });
                }
                if let Err(reason) = self.create_session(gen, shortcuts) {
                    on_event(Event::Failed { gen, reason });
                }
            }
        }
    }

    fn create_session(&mut self, gen: u64, want: Vec<Wanted>) -> Result<(), String> {
        let handle_token = self.token();
        let session_token = self.token();
        let mut options = PropMap::new();
        options.insert("handle_token".into(), Variant(Box::new(handle_token.clone())));
        options.insert("session_handle_token".into(), Variant(Box::new(session_token.clone())));
        let reply = self.call(method(OBJECT, IFACE, "CreateSession")?.append1(options))?;
        // An old portal may not follow the token; its answer is the truth.
        let request = reply
            .read1::<Path>()
            .map(|p| p.to_string())
            .unwrap_or_else(|_| request_path(&self.sender, &handle_token));
        let session = session_path(&self.sender, &session_token);
        self.phase = Phase::Creating { gen, request, session, want };
        Ok(())
    }

    fn bind_shortcuts(&mut self, gen: u64, session: String, want: Vec<Wanted>) -> Result<(), String> {
        let list: Vec<(String, PropMap)> = want
            .iter()
            .map(|w| {
                let mut props = PropMap::new();
                props.insert("description".into(), Variant(Box::new(w.description.clone())));
                if let Some(trigger) = &w.trigger {
                    props.insert("preferred_trigger".into(), Variant(Box::new(trigger.clone())));
                }
                (w.id.clone(), props)
            })
            .collect();
        let handle_token = self.token();
        let mut options = PropMap::new();
        options.insert("handle_token".into(), Variant(Box::new(handle_token.clone())));
        let session_obj = Path::new(session.clone())?;
        let msg = method(OBJECT, IFACE, "BindShortcuts")?.append3(session_obj, list, "").append1(options);
        // Bound to the session even if the call fails, so abandon() closes it.
        self.phase = Phase::Binding {
            gen,
            request: request_path(&self.sender, &handle_token),
            session: session.clone(),
            want: want.clone(),
        };
        let reply = self.call(msg)?;
        if let Ok(path) = reply.read1::<Path>() {
            self.phase = Phase::Binding { gen, request: path.to_string(), session, want };
        }
        Ok(())
    }

    fn message(&mut self, msg: &Message, on_event: &impl Fn(Event)) {
        if msg.msg_type() != MessageType::Signal {
            return;
        }
        let (Some(path), Some(iface), Some(member)) = (msg.path(), msg.interface(), msg.member()) else {
            return;
        };
        match (&*iface, &*member) {
            (REQUEST, "Response") => self.response(&path, msg, on_event),
            (IFACE, "Activated") => {
                let Phase::Bound { session, .. } = &self.phase else { return };
                if let Ok((from, id)) = msg.read2::<Path, String>() {
                    if &*from == session.as_str() {
                        on_event(Event::Activated(id));
                    }
                }
            }
            (IFACE, "ShortcutsChanged") => {
                let Phase::Bound { gen, session, shortcuts, .. } = &mut self.phase else { return };
                let mut args = msg.iter_init();
                let from: Option<Path> = args.read().ok();
                if from.as_deref() != Some(session.as_str()) {
                    return;
                }
                if let Some(changed) = args.get_refarg().and_then(|a| parse_shortcuts(&*a)) {
                    *shortcuts = Some(changed.clone());
                    on_event(Event::Changed { gen: *gen, shortcuts: changed });
                }
            }
            (SESSION, "Closed") => {
                let ours = match &self.phase {
                    Phase::Binding { session, .. } | Phase::Bound { session, .. } => &*path == session.as_str(),
                    _ => false,
                };
                if ours {
                    let gen = self.gen().unwrap_or_default();
                    self.phase = Phase::Idle;
                    on_event(Event::Failed { gen, reason: "the desktop closed the session".into() });
                }
            }
            _ => {}
        }
    }

    fn response(&mut self, path: &str, msg: &Message, on_event: &impl Fn(Event)) {
        let awaited = match &self.phase {
            Phase::Creating { request, .. } | Phase::Binding { request, .. } => request == path,
            _ => false,
        };
        if !awaited {
            return;
        }
        let answer = parse_response(msg);
        match std::mem::replace(&mut self.phase, Phase::Idle) {
            Phase::Creating { gen, session, want, .. } => {
                let results = match answer {
                    Ok(results) => results,
                    Err(code) => {
                        self.close(&session, SESSION);
                        let reason = format!("CreateSession answered {code}");
                        return on_event(Event::Failed { gen, reason });
                    }
                };
                let session = session_from_results(&results).unwrap_or(session);
                if let Err(reason) = self.bind_shortcuts(gen, session, want) {
                    self.abandon();
                    on_event(Event::Failed { gen, reason: format!("BindShortcuts: {reason}") });
                }
            }
            Phase::Binding { gen, session, want, .. } => match answer {
                Ok(results) => {
                    let shortcuts = results.get("shortcuts").and_then(|v| parse_shortcuts(&*v.0));
                    self.phase = Phase::Bound { gen, session, want, shortcuts: shortcuts.clone() };
                    on_event(Event::Bound { gen, shortcuts });
                }
                Err(code) => {
                    self.close(&session, SESSION);
                    let reason = if code == 1 { "the user declined".to_string() } else { format!("BindShortcuts answered {code}") };
                    on_event(Event::Failed { gen, reason });
                }
            },
            other => self.phase = other,
        }
    }
}

fn method(path: &str, iface: &str, member: &str) -> Result<Message, String> {
    Message::new_method_call(DEST, path, iface, member)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nova_bindings_become_xdg_triggers() {
        assert_eq!(xdg_trigger("Ctrl+Alt+Space").as_deref(), Some("CTRL+ALT+space"));
        assert_eq!(xdg_trigger("Ctrl+Alt+A").as_deref(), Some("CTRL+ALT+a"));
        assert_eq!(xdg_trigger("Ctrl+Alt+Right").as_deref(), Some("CTRL+ALT+Right"));
        assert_eq!(xdg_trigger("Ctrl+Alt+Left").as_deref(), Some("CTRL+ALT+Left"));
        assert_eq!(xdg_trigger("Super+A").as_deref(), Some("LOGO+a"));
        assert_eq!(xdg_trigger("Ctrl+Alt+Shift+Super+K").as_deref(), Some("CTRL+ALT+SHIFT+LOGO+k"));
        assert_eq!(xdg_trigger("Ctrl+Shift+7").as_deref(), Some("CTRL+SHIFT+7"));
        assert_eq!(xdg_trigger("Alt+F5").as_deref(), Some("ALT+F5"));
        assert_eq!(xdg_trigger("Ctrl+F24").as_deref(), Some("CTRL+F24"));
        assert_eq!(xdg_trigger("Ctrl+Alt+Enter").as_deref(), Some("CTRL+ALT+Return"));
        assert_eq!(xdg_trigger("Ctrl+Alt+Backspace").as_deref(), Some("CTRL+ALT+BackSpace"));
        assert_eq!(xdg_trigger("Ctrl+Alt+PageDown").as_deref(), Some("CTRL+ALT+Page_Down"));
        assert_eq!(xdg_trigger("Ctrl+Alt+BracketLeft").as_deref(), Some("CTRL+ALT+bracketleft"));
        assert_eq!(xdg_trigger("Ctrl+Alt+Quote").as_deref(), Some("CTRL+ALT+apostrophe"));
        assert_eq!(xdg_trigger("Ctrl+Alt+Backquote").as_deref(), Some("CTRL+ALT+grave"));
        assert_eq!(xdg_trigger("Ctrl+Alt+Equal").as_deref(), Some("CTRL+ALT+equal"));
        // Any spelling parse() takes gives the same trigger.
        assert_eq!(xdg_trigger("control+option+arrowright"), xdg_trigger("Ctrl+Alt+Right"));
        assert_eq!(xdg_trigger("Ctrl+Alt+Super+T").as_deref(), Some("CTRL+ALT+LOGO+t"));
    }

    #[test]
    fn what_is_not_a_shortcut_has_no_trigger() {
        assert_eq!(xdg_trigger(""), None);
        assert_eq!(xdg_trigger("A"), None);
        assert_eq!(xdg_trigger("Shift+A"), None);
        assert_eq!(xdg_trigger("Ctrl+Alt+Nope"), None);
        // A real key with no keysym in the table: the desktop picks.
        assert_eq!(xdg_trigger("Ctrl+Alt+Numpad5"), None);
    }

    #[test]
    fn every_default_and_every_key_nova_records_has_a_trigger() {
        for def in crate::shortcuts::ACTIONS {
            assert!(xdg_trigger(def.default_keys).is_some(), "{}", def.id);
        }
        // KEY_NAMES in src/core/shortcuts.ts.
        let mut keys: Vec<String> = ('A'..='Z').chain('0'..='9').map(String::from).collect();
        keys.extend((1..=24).map(|n| format!("F{n}")));
        for k in [
            "Space", "Enter", "Tab", "Backspace", "Delete", "Insert", "Home", "End", "PageUp",
            "PageDown", "Up", "Down", "Left", "Right", "Comma", "Period", "Slash", "Semicolon",
            "Quote", "Backquote", "BracketLeft", "BracketRight", "Backslash", "Minus", "Equal",
        ] {
            keys.push(k.to_string());
        }
        for key in keys {
            let trigger = xdg_trigger(&format!("Ctrl+Alt+{key}"));
            assert!(trigger.as_deref().is_some_and(|t| t.starts_with("CTRL+ALT+")), "{key}: {trigger:?}");
        }
    }

    #[test]
    fn request_and_session_paths_follow_the_portal_rule() {
        assert_eq!(
            request_path(":1.42", "nova7_1"),
            "/org/freedesktop/portal/desktop/request/1_42/nova7_1"
        );
        assert_eq!(
            session_path(":1.42", "nova7_2"),
            "/org/freedesktop/portal/desktop/session/1_42/nova7_2"
        );
    }

    /// The Response signal as it comes off the bus.
    fn response(code: u32, results: PropMap) -> Message {
        let msg = Message::new_signal("/org/freedesktop/portal/desktop/request/1_42/t", REQUEST, "Response")
            .unwrap()
            .append2(code, results);
        wire(msg)
    }

    /// Through the wire format and back, so the reader sees what libdbus
    /// hands over for a message from the bus.
    fn wire(mut msg: Message) -> Message {
        msg.set_serial(1);
        let mut bytes = Vec::new();
        msg.marshal(|b| -> Result<(), ()> {
            bytes.extend_from_slice(b);
            Ok(())
        })
        .unwrap();
        Message::demarshal(&bytes).unwrap()
    }

    fn shortcut(id: &str, trigger: Option<&str>) -> (String, PropMap) {
        let mut props = PropMap::new();
        props.insert("description".into(), Variant(Box::new(format!("{id} description"))));
        if let Some(t) = trigger {
            props.insert("trigger_description".into(), Variant(Box::new(t.to_string())));
        }
        (id.to_string(), props)
    }

    #[test]
    fn a_bind_response_lists_the_shortcuts_and_their_keys() {
        let list = vec![
            shortcut("openChat", Some("Ctrl+Alt+Space")),
            shortcut("goToAlert", Some("  ")),
            shortcut("muteToggle", None),
        ];
        let mut results = PropMap::new();
        results.insert("shortcuts".into(), Variant(Box::new(list)));
        let msg = response(0, results);
        let results = parse_response(&msg).expect("a success");
        let parsed = parse_shortcuts(&*results["shortcuts"].0).expect("a list");
        assert_eq!(
            parsed,
            vec![
                Bound { id: "openChat".into(), trigger: Some("Ctrl+Alt+Space".into()) },
                Bound { id: "goToAlert".into(), trigger: None },
                Bound { id: "muteToggle".into(), trigger: None },
            ]
        );
    }

    #[test]
    fn a_refused_or_failed_response_carries_its_code() {
        assert_eq!(parse_response(&response(1, PropMap::new())).unwrap_err(), 1);
        assert_eq!(parse_response(&response(2, PropMap::new())).unwrap_err(), 2);
        // Not a Response at all.
        let other = Message::new_signal("/x", REQUEST, "Response").unwrap().append1("nope");
        assert_eq!(parse_response(&other).unwrap_err(), 2);
    }

    #[test]
    fn the_session_handle_is_read_as_a_string_or_an_object_path() {
        let path = "/org/freedesktop/portal/desktop/session/1_42/s";
        let mut as_string = PropMap::new();
        as_string.insert("session_handle".into(), Variant(Box::new(path.to_string())));
        let mut as_path = PropMap::new();
        as_path.insert("session_handle".into(), Variant(Box::new(Path::new(path).unwrap())));
        for results in [as_string, as_path] {
            let msg = response(0, results);
            let results = parse_response(&msg).unwrap();
            assert_eq!(session_from_results(&results).as_deref(), Some(path));
        }
        assert_eq!(session_from_results(&PropMap::new()), None);
    }

    #[test]
    fn shortcuts_changed_reads_the_same_list() {
        let list = vec![shortcut("nextPill", Some("Meta+N"))];
        let msg = Message::new_signal(OBJECT, IFACE, "ShortcutsChanged")
            .unwrap()
            .append2(Path::new("/s").unwrap(), list);
        let msg = wire(msg);
        let mut args = msg.iter_init();
        let _: Path = args.read().unwrap();
        let parsed = parse_shortcuts(&*args.get_refarg().unwrap()).unwrap();
        assert_eq!(parsed, vec![Bound { id: "nextPill".into(), trigger: Some("Meta+N".into()) }]);
        // Not a list: nothing.
        assert_eq!(parse_shortcuts(&"text".to_string()), None);
    }

    // ── The whole exchange, against a stand-in portal ─────────────────────────
    //
    // Needs a session bus of its own, so it doesn't run by default:
    //   dbus-run-session -- cargo test -p nova --lib portal -- --ignored

    /// Plays org.freedesktop.portal.Desktop: answers every request at once,
    /// reports each shortcut's keys as "Fake <preferred trigger>", presses
    /// the first one, and refuses a list holding "refuseMe".
    /// Stops (and gives the name back) once `stop` is set.
    fn fake_portal(ready: mpsc::Sender<()>, stop: std::sync::Arc<std::sync::atomic::AtomicBool>) {
        let ch = Channel::get_private(BusType::Session).unwrap();
        let name = Message::new_method_call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName")
            .unwrap()
            .append2(DEST, 4u32);
        let owner: u32 = ch.send_with_reply_and_block(name, CALL_TIMEOUT).unwrap().read1().unwrap();
        assert_eq!(owner, 1, "the stand-in must own {DEST} on this bus");
        ready.send(()).unwrap();
        let respond = |to: &str, request: &str, code: u32, results: PropMap| {
            let mut signal = Message::new_signal(request, REQUEST, "Response").unwrap().append2(code, results);
            signal.set_destination(Some(to.into()));
            ch.send(signal).unwrap();
        };
        while !stop.load(std::sync::atomic::Ordering::Relaxed) {
            let Ok(Some(msg)) = ch.blocking_pop_message(Duration::from_millis(50)) else { continue };
            if msg.msg_type() != MessageType::MethodCall {
                continue;
            }
            let sender = msg.sender().unwrap().to_string();
            let iface = msg.interface().map(|i| i.to_string()).unwrap_or_default();
            match (iface.as_str(), &*msg.member().unwrap()) {
                ("org.freedesktop.DBus.Properties", "Get") => {
                    ch.send(msg.method_return().append1(Variant(1u32))).unwrap();
                }
                (IFACE, "CreateSession") => {
                    let options: PropMap = msg.read1().unwrap();
                    let request = request_path(&sender, options["handle_token"].0.as_str().unwrap());
                    let session = session_path(&sender, options["session_handle_token"].0.as_str().unwrap());
                    ch.send(msg.method_return().append1(Path::new(request.clone()).unwrap())).unwrap();
                    let mut results = PropMap::new();
                    results.insert("session_handle".into(), Variant(Box::new(session)));
                    respond(&sender, &request, 0, results);
                }
                (IFACE, "BindShortcuts") => {
                    let mut args = msg.iter_init();
                    let session: Path = args.read().unwrap();
                    let list: Vec<(String, PropMap)> = args.read().unwrap();
                    let _parent: String = args.read().unwrap();
                    let options: PropMap = args.read().unwrap();
                    let request = request_path(&sender, options["handle_token"].0.as_str().unwrap());
                    ch.send(msg.method_return().append1(Path::new(request.clone()).unwrap())).unwrap();
                    if list.iter().any(|(id, _)| id == "refuseMe") {
                        respond(&sender, &request, 1, PropMap::new());
                        continue;
                    }
                    let bound: Vec<(String, PropMap)> = list
                        .iter()
                        .map(|(id, props)| {
                            let wanted = props.get("preferred_trigger").and_then(|t| t.0.as_str()).unwrap_or("?");
                            let mut out = PropMap::new();
                            out.insert("description".into(), Variant(Box::new(props["description"].0.as_str().unwrap().to_string())));
                            out.insert("trigger_description".into(), Variant(Box::new(format!("Fake {wanted}"))));
                            (id.clone(), out)
                        })
                        .collect();
                    let mut results = PropMap::new();
                    results.insert("shortcuts".into(), Variant(Box::new(bound)));
                    respond(&sender, &request, 0, results);
                    // A press, broadcast as the portal does.
                    let press = Message::new_signal(OBJECT, IFACE, "Activated")
                        .unwrap()
                        .append3(session.into_static(), list[0].0.clone(), 0u64)
                        .append1(PropMap::new());
                    ch.send(press).unwrap();
                }
                _ => {
                    ch.send(msg.method_return()).unwrap();
                }
            }
        }
    }

    #[test]
    #[ignore = "needs its own session bus: dbus-run-session -- cargo test -p nova --lib portal -- --ignored"]
    fn the_whole_exchange_with_a_stand_in_portal() {
        let recv = |rx: &mpsc::Receiver<Event>| rx.recv_timeout(Duration::from_secs(15)).expect("an event");

        let (ready_tx, ready_rx) = mpsc::channel();
        let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let fake = {
            let stop = stop.clone();
            std::thread::spawn(move || fake_portal(ready_tx, stop))
        };
        ready_rx.recv_timeout(Duration::from_secs(15)).unwrap();

        let (tx, rx) = mpsc::channel();
        let handle = start(move |e| drop(tx.send(e))).unwrap();
        let want = |ids: &[(&str, &str)]| -> Vec<Wanted> {
            ids.iter()
                .map(|(id, keys)| Wanted { id: id.to_string(), description: format!("{id}!"), trigger: xdg_trigger(keys) })
                .collect()
        };
        let bound = |ids: &[(&str, &str)]| -> Option<Vec<Bound>> {
            Some(ids.iter().map(|(id, t)| Bound { id: id.to_string(), trigger: Some(t.to_string()) }).collect())
        };

        let first = want(&[("openChat", "Ctrl+Alt+Space"), ("goToAlert", "Ctrl+Alt+A")]);
        assert!(handle.bind(1, first.clone()));
        let answer = bound(&[("openChat", "Fake CTRL+ALT+space"), ("goToAlert", "Fake CTRL+ALT+a")]);
        assert_eq!(recv(&rx), Event::Bound { gen: 1, shortcuts: answer.clone() });
        assert_eq!(recv(&rx), Event::Activated("openChat".into()));

        // The same shortcuts again: answered at once, the desktop isn't asked.
        assert!(handle.bind(2, first));
        assert_eq!(recv(&rx), Event::Bound { gen: 2, shortcuts: answer });

        // Other shortcuts: a new session.
        assert!(handle.bind(3, want(&[("muteToggle", "Super+M")])));
        assert_eq!(recv(&rx), Event::Bound { gen: 3, shortcuts: bound(&[("muteToggle", "Fake LOGO+m")]) });
        assert_eq!(recv(&rx), Event::Activated("muteToggle".into()));

        // Refused in the desktop's dialog.
        assert!(handle.bind(4, want(&[("refuseMe", "Ctrl+Alt+R")])));
        assert!(matches!(recv(&rx), Event::Failed { gen: 4, .. }));

        // Released, then bound again from nothing.
        assert!(handle.release());
        assert!(handle.bind(5, want(&[("nextPill", "Ctrl+Alt+Right")])));
        assert_eq!(recv(&rx), Event::Bound { gen: 5, shortcuts: bound(&[("nextPill", "Fake CTRL+ALT+Right")]) });
        assert_eq!(recv(&rx), Event::Activated("nextPill".into()));
        assert!(rx.recv_timeout(Duration::from_millis(200)).is_err(), "nothing more");

        // No GlobalShortcuts portal on the bus (none at all, or one without
        // that interface): Unavailable, and the thread is gone.
        stop.store(true, std::sync::atomic::Ordering::Relaxed);
        fake.join().unwrap();
        let (tx, rx) = mpsc::channel();
        let handle = start(move |e| drop(tx.send(e))).unwrap();
        assert!(matches!(recv(&rx), Event::Unavailable(_)));
        let gone = (0..100).any(|_| {
            std::thread::sleep(Duration::from_millis(10));
            !handle.release()
        });
        assert!(gone, "the thread should stop when there is no portal");
    }
}
