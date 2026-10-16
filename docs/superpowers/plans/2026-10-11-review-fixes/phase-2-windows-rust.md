# Phase 2 — Windows/Linux Rust backend and `coucou-hook` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the Windows/Linux backend bugs from the review:
- the phone pairing being wiped (C1, C4) and the dropped trailing state push (C5);
- the phone loop's idle cost;
- the session readers' traversal, option-injection and parsing edge cases (C9, C10, C13);
- the hook's unbounded stdin and its 2 s budget (C15);
- out-of-order events and stale cards in the pipe (C17);
- UI-thread blocking (C18);
- the hidden island's 20 Hz wakeups.

**Architecture:** Each fix lands in the module that owns the behaviour, with the decision logic pulled into a small pure function that a unit test can drive: `Settings::from_webview`, `phone::plan`, `phone::take_interval`, `cli_sessions::*`, `pipe::wait_for_decision`, `hook::read_all_within`. One new module, `src-tauri/src/cli_sessions.rs`, holds what the four `*_sessions.rs` readers share.

**Tech Stack:** Rust 2021, Tauri 2, tokio (this phase adds its `macros` feature for `select!`/`pin!`), rusqlite (bundled SQLite with JSON1), reqwest.

**Spec:** `README.md` in this folder (findings C1, C4, C5, C9, C10, C11, C13, C15, C17, C18, C19, V3, V5, V6, L3, L4, L6; contracts 4, 5, 6).

## Global Constraints

See `README.md` → Global Constraints. For this phase:
- Run tests from `windows/`: `cargo test --workspace` (package names: `coucou` for `src-tauri`, `coucou-hook` for `hook`). A single test: `cargo test -p coucou --lib <module>::tests::<name>`.
- The release profile is `panic = "abort"`: no new `unwrap()`/slicing on data that comes from outside (hook payloads, CLI files, the network).
- No new crates. `tokio`'s `macros` feature is the only manifest change.
- Never block the agent. The hook must still exit within its budget whatever the app does.

## Review Focus

See `README.md`. Tests this phase owns: `a_prompt_never_reads_as_an_option` (Task 2.8), `a_torn_character_at_the_end_does_not_lose_the_transcript` and `a_long_session_is_read_from_its_end` and `a_huge_session_meta_line_still_names_the_session` (Task 2.9), `only_the_last_parts_are_read` (Task 2.10).

---

### Task 2.1: A webview save never undoes what only Rust changes (C1)

Both webviews hold a full `Settings` copy from boot and send it whole on every change (`island.ts:260/266/272`, `chat.ts:70`, `shortcuts.ts:116`, `settings/main.ts:37`). `lib.rs:106-108` only protects `desktop_mochi`. So the first volume change after pairing wipes `phone_pc_id`, `phone_paired`, `phone_worker` and `phone_enabled`. `phone.rs` also never tells the webviews it changed anything.

**Files:**
- Modify: `windows/src-tauri/src/settings.rs` (new `impl Settings` block after `impl Default for Settings`; test in `mod tests` at line ~397)
- Modify: `windows/src-tauri/src/lib.rs:98-136` (`save_settings`) and `:526-539` (`phone_enable`)
- Modify: `windows/src-tauri/src/phone.rs` (`finish_pair`, `unpair`, `claimed`)

**Interfaces:**
- Produces: `impl Settings { pub fn from_webview(&self, incoming: Settings) -> Settings }`.
- Produces: `phone::set_enabled(app: &AppHandle, on: bool)` and the private `phone::update_settings(app, change)`, which saves and emits `settings-changed`.

- [ ] **Step 1: Write the failing test**

In `windows/src-tauri/src/settings.rs`, inside the existing `#[cfg(test)] mod tests { … }`, add:

```rust
    #[test]
    fn a_webview_save_keeps_what_only_rust_may_change() {
        let mut current = Settings::default();
        current.phone_enabled = true;
        current.phone_worker = "https://relay.example".into();
        current.phone_pc_id = "a1b2c3d4e5f6a1b2c3d4e5f6".into();
        current.phone_paired = true;
        current.phone_device = "Pixel".into();
        current.hooks_installed = true;
        current.plan_relay_installed = true;
        current.desktop_mochi.on_desktop = true;

        // A webview's copy from before the pairing, carrying one real change.
        let mut stale = Settings::default();
        stale.sound_volume = 0.05;

        let saved = current.from_webview(stale);
        assert_eq!(saved.sound_volume, 0.05, "the webview's own change goes through");
        assert!(saved.phone_enabled && saved.phone_paired);
        assert_eq!(saved.phone_worker, "https://relay.example");
        assert_eq!(saved.phone_pc_id, "a1b2c3d4e5f6a1b2c3d4e5f6");
        assert_eq!(saved.phone_device, "Pixel");
        assert!(saved.hooks_installed && saved.plan_relay_installed);
        assert!(saved.desktop_mochi.on_desktop);
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd windows && cargo test -p coucou --lib settings::tests::a_webview_save_keeps_what_only_rust_may_change`
Expected: FAIL to compile, `no method named from_webview found for struct Settings`.

- [ ] **Step 3: Write minimal implementation**

In `settings.rs`, after the `impl Default for Settings { … }` block, add:

```rust
impl Settings {
    /// What a webview sends back, with the fields only Rust changes kept as they
    /// are: the phone pairing (phone.rs), whether Coucou's hooks and status line
    /// are in Claude Code's settings.json (hooks.rs) and Mochi's desktop spot
    /// (desktop.rs). A webview holds a copy taken at boot and writes the whole
    /// object back on any change, so its stale copy would otherwise undo them.
    pub fn from_webview(&self, mut incoming: Settings) -> Settings {
        incoming.desktop_mochi = self.desktop_mochi.clone();
        incoming.hooks_installed = self.hooks_installed;
        incoming.plan_relay_installed = self.plan_relay_installed;
        incoming.phone_enabled = self.phone_enabled;
        incoming.phone_worker = self.phone_worker.clone();
        incoming.phone_pc_id = self.phone_pc_id.clone();
        incoming.phone_paired = self.phone_paired;
        incoming.phone_device = self.phone_device.clone();
        incoming
    }
}
```

In `lib.rs`, replace the first part of `save_settings` (from `let (screen_changed, autostart_changed, shortcuts_changed) = {` through `let settings = shared.settings.lock().unwrap().clone();`) with:

```rust
    let (settings, screen_changed, autostart_changed, shortcuts_changed) = {
        let mut current = shared.settings.lock().unwrap();
        let next = current.from_webview(settings);
        let screen_changed = current.screen != next.screen;
        let autostart_changed = current.autostart != next.autostart;
        let shortcuts_changed = current.shortcuts != next.shortcuts;
        *current = next.clone();
        (next, screen_changed, autostart_changed, shortcuts_changed)
    };
```

Leave the rest of the function (`settings::save`, autostart, geometry, integrations, spotify, shortcuts, language, `emit("settings-changed", settings)`) unchanged.

In `phone.rs`, add below `fn nonempty`:

```rust
/// Changes the phone fields, saves, and tells both webviews: their copies of
/// the settings would otherwise keep the old values and write them back.
fn update_settings(app: &AppHandle, change: impl FnOnce(&mut crate::settings::Settings)) {
    let snapshot = {
        let shared = app.state::<crate::Shared>();
        let mut s = shared.settings.lock().unwrap();
        change(&mut s);
        s.clone()
    };
    if let Err(err) = crate::settings::save(&snapshot) {
        crate::log::line(format!("could not save settings: {err}"));
    }
    let _ = app.emit("settings-changed", snapshot);
}

/// Settings → "Control from the phone".
pub fn set_enabled(app: &AppHandle, on: bool) {
    update_settings(app, |s| s.phone_enabled = on);
    if on {
        spawn(app.clone());
    }
}
```

Then replace the hand-written lock/clone/save sequences:
- In `finish_pair`, replace everything from `let shared = app.state::<crate::Shared>();` to `let _ = crate::settings::save(&snapshot);` with:

```rust
    update_settings(app, |s| {
        s.phone_worker = pair.worker.clone();
        s.phone_pc_id = pair.pc_id.clone();
        s.phone_paired = false;
        s.phone_device.clear();
        s.phone_enabled = true;
    });
```

- In `unpair`, replace the last block (`let shared = …` through `save`) with:

```rust
    update_settings(app, |s| {
        s.phone_paired = false;
        s.phone_device.clear();
        s.phone_pc_id.clear();
    });
```

- In `claimed`, replace the inner `{ let shared = …; let _ = crate::settings::save(&snapshot); }` block with:

```rust
        update_settings(app, |s| {
            s.phone_paired = true;
            s.phone_device = device.clone();
        });
```

Add `Emitter` to `phone.rs`'s `use tauri::{…}` (it already imports `Emitter, Manager`, so check it is there). In `lib.rs`, replace the body of `phone_enable` and drop its `shared` parameter:

```rust
#[tauri::command]
fn phone_enable(app: AppHandle, on: bool) {
    phone::set_enabled(&app, on);
}
```

- [ ] **Step 4: Run tests**

Run: `cd windows && cargo test -p coucou --lib settings:: && cargo check -p coucou`
Expected: PASS, and `cargo check` clean.

- [ ] **Step 5: Manual check (Windows or Linux)**

`npm run tauri dev`. Pair a phone in Settings → Android phone, then change the island's sound volume. Restart Coucou: Settings still shows the phone paired, and `%APPDATA%\Coucou\settings.json` still has `phonePcId`.

- [ ] **Step 6: Commit**

```bash
git add windows/src-tauri/src/settings.rs windows/src-tauri/src/lib.rs windows/src-tauri/src/phone.rs
git commit -m "Windows/Linux: a webview save no longer wipes the phone pairing"
```

---

### Task 2.2: A failed (re-)pair leaves the working pairing alone (C4); pairing never blocks the UI (C18)

`start_pair` writes the new secret to the keychain before the box exists (`phone.rs:70`), and `lib.rs:546-548` clears it on failure. A failed second pairing therefore destroys the first. `phone_pair` and `phone_unpair` are sync commands that `block_on` a request with a 10 s timeout, and Tauri runs sync commands on the main thread.

**Files:**
- Modify: `windows/src-tauri/src/phone.rs` (`Pairing`, `start_pair`, `finish_pair`, `unpair`; new `BoxRef`, `current_box`; new `#[cfg(test)] mod tests`)
- Modify: `windows/src-tauri/src/lib.rs:541-557` (`phone_pair`, `phone_unpair`)

**Interfaces:**
- Produces: `pub fn start_pair(worker: &str) -> Result<Pairing, String>` (no keychain write), `pub async fn finish_pair(app: &AppHandle, pair: &Pairing) -> Result<(), String>`, `pub async fn unpair(app: &AppHandle)`.

- [ ] **Step 1: Write the failing tests**

At the end of `phone.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_pairing_code_carries_the_box_id_its_secret_and_the_relay() {
        let p = start_pair("https://relay.example.workers.dev").unwrap();
        let parts: Vec<&str> = p.code.split('|').collect();
        assert_eq!(parts.len(), 3);
        assert!(parts[0].len() == 24 && parts[0].bytes().all(|b| b.is_ascii_hexdigit()));
        assert!(parts[1].len() == 64 && parts[1].bytes().all(|b| b.is_ascii_hexdigit()));
        // The secret travels in the code and is only stored once the box exists.
        assert_eq!(parts[1], p.secret);
        assert_eq!(parts[2], "https://relay.example.workers.dev");
        assert!(p.qr_svg.contains("<svg"));
    }

    #[test]
    fn a_relay_must_be_https_or_this_machine() {
        assert!(start_pair("http://relay.example").is_err());
        assert!(start_pair("http://127.0.0.1:8787").is_ok());
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd windows && cargo test -p coucou --lib phone::tests`
Expected: FAIL to compile, `no field secret on type Pairing`. (As written today, `start_pair` would also write to the real Credential Manager.)

- [ ] **Step 3: Write minimal implementation**

In `phone.rs`, replace `pub struct Pairing { … }`, `start_pair`, `finish_pair` and `unpair` with:

```rust
/// The credentials a box is created with. `pc_id` identifies it (and is fine
/// in settings.json); `secret` authenticates every call. It reaches the
/// keychain only once the relay has created the box, so a pairing that fails
/// leaves the previous one working.
pub struct Pairing {
    pub worker: String,
    pub pc_id: String,
    secret: String,
    /// `id|secret|worker` — what the QR encodes and the manual fallback shows.
    pub code: String,
    /// The QR as SVG markup, for the settings window to drop into the page.
    pub qr_svg: String,
}

/// A phone taking over the island: the code and its QR. Nothing is stored yet.
pub fn start_pair(worker: &str) -> Result<Pairing, String> {
    let worker = check_worker(worker)?;
    let Some(pc_id) = hex(12) else { return Err("no random source".into()) };
    let Some(secret) = hex(32) else { return Err("no random source".into()) };
    let code = format!("{pc_id}|{secret}|{worker}");
    let qr_svg = qrcode::QrCode::new(code.as_bytes())
        .map_err(|e| e.to_string())?
        .render::<qrcode::render::svg::Color>()
        .build();
    Ok(Pairing { worker, pc_id, secret, code, qr_svg })
}

/// The box this PC is paired with now, if any.
struct BoxRef {
    worker: String,
    id: String,
    secret: String,
}

fn current_box(app: &AppHandle) -> Option<BoxRef> {
    let (worker, id) = {
        let shared = app.state::<crate::Shared>();
        let s = shared.settings.lock().unwrap();
        (s.phone_worker.clone(), s.phone_pc_id.clone())
    };
    Some(BoxRef { worker: nonempty(worker)?, id: nonempty(id)?, secret: secret()? })
}

/// Called once the code is on screen: creates the box, and only when the relay
/// has it does the new pairing replace the old one, whose box is then wiped.
pub async fn finish_pair(app: &AppHandle, pair: &Pairing) -> Result<(), String> {
    post_async(&pair.worker, "pair", &json!({ "id": pair.pc_id, "secret": pair.secret })).await?;
    let old = current_box(app);
    crate::secrets::set("phone-secret", &pair.secret)?;
    update_settings(app, |s| {
        s.phone_worker = pair.worker.clone();
        s.phone_pc_id = pair.pc_id.clone();
        s.phone_paired = false;
        s.phone_device.clear();
        s.phone_enabled = true;
    });
    spawn(app.clone());
    // The previous box would otherwise keep the old phone's token and the last state for good.
    if let Some(old) = old.filter(|o| o.id != pair.pc_id) {
        let _ = post_async(&old.worker, "unpair", &json!({ "id": old.id, "secret": old.secret })).await;
    }
    Ok(())
}

pub async fn unpair(app: &AppHandle) {
    if let Some(current) = current_box(app) {
        let _ = post_async(&current.worker, "unpair", &json!({ "id": current.id, "secret": current.secret })).await;
    }
    let _ = crate::secrets::clear("phone-secret");
    update_settings(app, |s| {
        s.phone_paired = false;
        s.phone_device.clear();
        s.phone_pc_id.clear();
    });
}
```

In `lib.rs`, replace `phone_pair` and `phone_unpair` with async commands (no more `secrets::clear` on failure):

```rust
/// Create the pairing code/QR and the relay box. The phone claims it with the
/// `coucou://` payload the code carries. Async: the relay may take seconds.
#[tauri::command]
async fn phone_pair(app: AppHandle, worker: String) -> Result<serde_json::Value, String> {
    let pair = phone::start_pair(&worker)?;
    phone::finish_pair(&app, &pair).await?;
    Ok(json!({ "code": pair.code, "qrSvg": pair.qr_svg }))
}

/// Forget the phone and wipe its mailbox on the relay.
#[tauri::command]
async fn phone_unpair(app: AppHandle) {
    phone::unpair(&app).await;
}
```

- [ ] **Step 4: Run tests**

Run: `cd windows && cargo test -p coucou --lib phone::tests && cargo check -p coucou`
Expected: PASS.

- [ ] **Step 5: Manual check**

With a phone paired, open Settings → Android phone → Pair phone… and enter `http://127.0.0.1:9` as the relay, a loopback address where nothing listens. The error shows. The existing phone still gets the next approval card, and Settings still shows it as paired.

- [ ] **Step 6: Commit**

```bash
git add windows/src-tauri/src/phone.rs windows/src-tauri/src/lib.rs
git commit -m "Windows/Linux: a failed re-pair keeps the working pairing; pairing is async"
```

---

### Task 2.3: The last state of a burst reaches the phone (C5); the island learns whether a push got through

`push_state` (`phone.rs:233`) drops any non-alert push within 1.5 s of the previous one and never sends it later. The island also cannot tell a failed alert from a delivered one, because `lib.rs:563` swallows the error.

**Files:**
- Modify: `windows/src-tauri/src/phone.rs` (`push_state` → `plan` + `send_state`; statics)
- Modify: `windows/src-tauri/src/lib.rs:559-564` (`phone_state`)
- Test: `phone.rs` `mod tests`

**Interfaces:**
- Produces: `fn plan(last: Option<Instant>, now: Instant, alert: bool) -> Plan`, with `enum Plan { Now, After(Duration) }`. Command `phone_state(...) -> bool` (contract 6).

- [ ] **Step 1: Write the failing test**

Add to `phone.rs` `mod tests`:

```rust
    #[test]
    fn a_push_inside_the_gap_is_delayed_not_dropped() {
        let t0 = Instant::now();
        assert_eq!(plan(None, t0, false), Plan::Now);
        assert_eq!(
            plan(Some(t0), t0 + Duration::from_millis(400), false),
            Plan::After(Duration::from_millis(1100))
        );
        // A card waking the phone never waits.
        assert_eq!(plan(Some(t0), t0 + Duration::from_millis(400), true), Plan::Now);
        assert_eq!(plan(Some(t0), t0 + PUSH_GAP, false), Plan::Now);
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd windows && cargo test -p coucou --lib phone::tests::a_push_inside_the_gap`
Expected: FAIL to compile, `cannot find function plan`.

- [ ] **Step 3: Write minimal implementation**

In `phone.rs`, replace the whole `pub async fn push_state(…) { … }` with:

```rust
/// The shortest gap between two state pushes that do not wake the phone.
const PUSH_GAP: Duration = Duration::from_millis(1500);

#[derive(Debug, PartialEq)]
enum Plan {
    Now,
    After(Duration),
}

/// When a push may go: an alert at once, anything else at most every
/// PUSH_GAP — and the last one of a burst after the gap, never not at all.
fn plan(last: Option<Instant>, now: Instant, alert: bool) -> Plan {
    match last {
        Some(t) if !alert && now.duration_since(t) < PUSH_GAP => Plan::After(PUSH_GAP - now.duration_since(t)),
        _ => Plan::Now,
    }
}

struct Outgoing {
    last: Option<Instant>,
    /// The newest state held back by the gap; a later one replaces it.
    held: Option<Value>,
    flush_scheduled: bool,
}

static OUTGOING: Mutex<Outgoing> = Mutex::new(Outgoing { last: None, held: None, flush_scheduled: false });

/// PC → phone: the island's latest state. `alert` gets an FCM wake; the rest is
/// for when the app is already open. Ok when sent, held for the end of the gap,
/// or not needed (no phone paired); Err when the relay could not be reached.
pub async fn push_state(app: &AppHandle, payload: Value, alert: bool) -> Result<(), String> {
    let now = Instant::now();
    let wait = {
        let mut out = OUTGOING.lock().unwrap();
        match plan(out.last, now, alert) {
            Plan::Now => {
                out.last = Some(now);
                out.held = None;
                None
            }
            Plan::After(wait) => {
                out.held = Some(payload.clone());
                if out.flush_scheduled {
                    return Ok(());
                }
                out.flush_scheduled = true;
                Some(wait)
            }
        }
    };
    let Some(wait) = wait else { return send_state(app, payload, alert).await };
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(wait).await;
        let held = {
            let mut out = OUTGOING.lock().unwrap();
            out.flush_scheduled = false;
            out.last = Some(Instant::now());
            out.held.take()
        };
        if let Some(payload) = held {
            let _ = send_state(&app, payload, false).await;
        }
    });
    Ok(())
}

async fn send_state(app: &AppHandle, payload: Value, alert: bool) -> Result<(), String> {
    let (worker, id) = {
        let shared = app.state::<crate::Shared>();
        let s = shared.settings.lock().unwrap();
        if !s.phone_enabled || !s.phone_paired {
            return Ok(());
        }
        (s.phone_worker.clone(), s.phone_pc_id.clone())
    };
    let (Some(worker), Some(id), Some(sec)) = (nonempty(worker), nonempty(id), secret()) else {
        return Ok(());
    };
    let mut body = json!({ "id": id, "secret": sec, "state": payload });
    if alert {
        // What wakes the phone: the card kind, nothing else.
        body["alert"] = payload
            .get("awaiting")
            .and_then(|a| a.get("kind"))
            .and_then(Value::as_str)
            .map(|k| if k == "question" { json!("question") } else { json!("approval") })
            .unwrap_or(json!("approval"));
    }
    post_async(&worker, "state", &body).await.map(|_| ())
}
```

In `lib.rs`, replace `phone_state` with:

```rust
/// The island pushes its visible state after each change; `alert` wakes the
/// phone for a waiting card. False when the relay could not be reached, so the
/// island tries the alert again with its next change.
#[tauri::command]
async fn phone_state(app: AppHandle, payload: serde_json::Value, alert: bool) -> bool {
    phone::push_state(&app, payload, alert).await.is_ok()
}
```

- [ ] **Step 4: Run tests**

Run: `cd windows && cargo test -p coucou --lib phone::tests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add windows/src-tauri/src/phone.rs windows/src-tauri/src/lib.rs
git commit -m "Windows/Linux: the last state of a burst reaches the phone; phone_state reports delivery"
```

---

### Task 2.4: The phone loop costs nothing until a phone is set up, and polls slowly when idle

`phone::spawn` runs from launch for every user (`lib.rs:1065`). It wakes every 3 s forever, reads the Credential Manager on every iteration (the tuple at `phone.rs:158-159` calls `secret()` even when the feature is off), polls `claimed` forever after a Pair click (`:184`), and builds a new HTTP client per request (`:266`).

**Files:**
- Modify: `windows/src-tauri/src/phone.rs` (constants, statics, `spawn`, `claimed`, `take`, `send_state`, `finish_pair`, `update_settings`, `post_async`)
- Test: `phone.rs` `mod tests`

**Interfaces:**
- Produces: `fn take_interval(card_up: bool, since_phone: Option<Duration>) -> Duration`, `fn pairing_open(since_pairing: Option<Duration>) -> bool`, `fn wake()`.

- [ ] **Step 1: Write the failing tests**

Add to `phone.rs` `mod tests`:

```rust
    #[test]
    fn the_outbox_is_read_quickly_only_while_something_is_going_on() {
        assert_eq!(take_interval(true, None), POLL);
        assert_eq!(take_interval(false, Some(Duration::from_secs(30))), POLL);
        assert_eq!(take_interval(false, Some(ACTIVE_WINDOW + Duration::from_secs(1))), POLL_IDLE);
        assert_eq!(take_interval(false, None), POLL_IDLE);
    }

    #[test]
    fn a_pairing_code_is_watched_for_half_an_hour() {
        assert!(pairing_open(Some(Duration::from_secs(60))));
        assert!(!pairing_open(Some(PAIR_WINDOW + Duration::from_secs(1))));
        assert!(!pairing_open(None));
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd windows && cargo test -p coucou --lib phone::tests`
Expected: FAIL to compile, `cannot find function take_interval`.

- [ ] **Step 3: Write minimal implementation**

In `phone.rs`:

1. Imports: change `use std::sync::Mutex;` to `use std::sync::atomic::{AtomicBool, Ordering};` and `use std::sync::{LazyLock, Mutex};`, and add `use tokio::sync::Notify;`.

2. Below `const POLL …`, add:

```rust
/// How often the outbox is read while nothing is going on — no card up, the
/// phone quiet for a while. A message typed then waits at most this long.
const POLL_IDLE: Duration = Duration::from_secs(10);
/// After the phone last sent something, it is answered at the quick pace.
const ACTIVE_WINDOW: Duration = Duration::from_secs(120);
/// How long a pairing code on screen is watched for a phone to claim it.
const PAIR_WINDOW: Duration = Duration::from_secs(30 * 60);

/// Rings when something the loop decides on changed: settings, a card, a pairing.
static WAKE: LazyLock<Notify> = LazyLock::new(Notify::new);
static CARD_UP: AtomicBool = AtomicBool::new(false);
static PHONE_SPOKE: Mutex<Option<Instant>> = Mutex::new(None);
static PAIRING_SINCE: Mutex<Option<Instant>> = Mutex::new(None);

fn wake() {
    WAKE.notify_one();
}

fn since(at: &Mutex<Option<Instant>>) -> Option<Duration> {
    at.lock().unwrap().map(|t| t.elapsed())
}

fn take_interval(card_up: bool, since_phone: Option<Duration>) -> Duration {
    if card_up || since_phone.is_some_and(|d| d < ACTIVE_WINDOW) { POLL } else { POLL_IDLE }
}

fn pairing_open(since_pairing: Option<Duration>) -> bool {
    since_pairing.is_some_and(|d| d < PAIR_WINDOW)
}
```

3. Replace the `tauri::async_runtime::spawn(async move { … });` body inside `pub fn spawn` with:

```rust
    tauri::async_runtime::spawn(async move {
        let mut backoff = POLL;
        loop {
            let (enabled, paired, worker, id) = {
                let shared = app.state::<crate::Shared>();
                let s = shared.settings.lock().unwrap();
                (s.phone_enabled, s.phone_paired, s.phone_worker.clone(), s.phone_pc_id.clone())
            };
            // Nothing to do until the settings change: no timer, no keychain read.
            let ready = enabled && (paired || pairing_open(since(&PAIRING_SINCE)));
            let (true, Some(worker), Some(id)) = (ready, nonempty(worker), nonempty(id)) else {
                WAKE.notified().await;
                continue;
            };
            let Some(sec) = secret() else {
                WAKE.notified().await;
                continue;
            };
            let result = if paired {
                take(&app, &worker, &id, &sec).await
            } else {
                claimed(&app, &worker, &id, &sec).await
            };
            if result.is_err() {
                // The worker or the network is down: keep trying, quietly,
                // widening the gap so a phone-less afternoon is cheap.
                let _ = tokio::time::timeout(backoff, WAKE.notified()).await;
                backoff = (backoff * 2).min(BACKOFF_MAX);
                continue;
            }
            backoff = POLL;
            let wait = if paired {
                take_interval(CARD_UP.load(Ordering::Relaxed), since(&PHONE_SPOKE))
            } else {
                PAIR_WAIT
            };
            let _ = tokio::time::timeout(wait, WAKE.notified()).await;
        }
    });
```

4. In `update_settings` (Task 2.1), add `wake();` as its last line.

5. In `finish_pair`, right after `update_settings(app, |s| { … });`, add:

```rust
    *PAIRING_SINCE.lock().unwrap() = Some(Instant::now());
    wake();
```

6. In `claimed`, inside the `if reply.get("paired") … == Some(true) {` block, add `*PAIRING_SINCE.lock().unwrap() = None;`.

7. In `take`, after the `if out.is_empty() { return Ok(()); }` line, add `*PHONE_SPOKE.lock().unwrap() = Some(Instant::now());`.

8. At the top of `push_state` (before `let now = …`), add:

```rust
    // A card on screen: the phone's answer is read at the quick pace.
    let card_up = payload.get("awaiting").is_some_and(|a| !a.is_null());
    if CARD_UP.swap(card_up, Ordering::Relaxed) != card_up && card_up {
        wake();
    }
```

9. Replace the client construction in `post_async` with a cached client:

```rust
/// One HTTP client per relay address, kept: a fresh one per call meant a new
/// TLS handshake every poll.
fn client_for(worker: &str) -> Result<reqwest::Client, String> {
    static CLIENT: Mutex<Option<(String, reqwest::Client)>> = Mutex::new(None);
    let mut slot = CLIENT.lock().unwrap();
    if let Some((addr, client)) = slot.as_ref() {
        if addr == worker {
            return Ok(client.clone());
        }
    }
    let client = crate::net::client(&crate::net::normalise_server_url(worker)?, HTTP)?;
    *slot = Some((worker.to_string(), client.clone()));
    Ok(client)
}

async fn post_async(worker: &str, action: &str, body: &Value) -> Result<Value, String> {
    let worker = worker.trim_end_matches('/');
    let url = format!("{worker}{WORKER_PATH}/{action}");
    let client = client_for(worker)?;
    let resp = client.post(&url).json(body).send().await.map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        return Err(format!("relay {}", resp.status()));
    }
    resp.json::<Value>().await.map_err(|e| e.to_string())
}
```

- [ ] **Step 4: Run tests**

Run: `cd windows && cargo test -p coucou --lib phone::tests && cargo check -p coucou`
Expected: PASS.

- [ ] **Step 5: Manual check**

With no phone ever paired, run Coucou for a minute and confirm that `coucou.log` and a process monitor (Process Explorer → Threads) show no 3 s wakeups from the phone loop. Pair a phone, put a card up, and tap Allow on the phone: the PC picks it up within 3 s. With nothing going on, a chat typed on the phone arrives within 10 s.

- [ ] **Step 6: Commit**

```bash
git add windows/src-tauri/src/phone.rs
git commit -m "Windows/Linux: phone loop sleeps until set up, polls slowly when idle, reuses its client"
```

---

### Task 2.5: Keychain answers are cached (V5)

`secrets::get` asks the Credential Manager or Secret Service on every call: every poller tick, every phone loop pass, every push. The Mac caches at launch (`ClaudeService.swift:56-104`).

**Files:**
- Modify: `windows/src-tauri/src/secrets.rs`

**Interfaces:**
- Produces: unchanged public API (`get`, `set`, `clear`, `present`). Private `struct Cache` with `get_or` and `put`.

- [ ] **Step 1: Write the failing tests**

Append to `secrets.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_key_is_asked_of_the_keychain_once() {
        let cache = Cache::new();
        let mut asked = 0;
        for _ in 0..3 {
            let v = cache.get_or("github-token", || {
                asked += 1;
                Ok(Some("ghp_x".into()))
            });
            assert_eq!(v.as_deref(), Some("ghp_x"));
        }
        assert_eq!(asked, 1);
    }

    #[test]
    fn a_keychain_that_could_not_answer_is_asked_again() {
        // A locked Secret Service at login must not hide the key until restart.
        let cache = Cache::new();
        assert_eq!(cache.get_or("vercel-token", || Err(())), None);
        assert_eq!(cache.get_or("vercel-token", || Ok(Some("v".into()))).as_deref(), Some("v"));
    }

    #[test]
    fn set_and_clear_replace_what_was_cached() {
        let cache = Cache::new();
        let _ = cache.get_or("n8n-url", || Ok(None));
        cache.put("n8n-url", Some("https://n8n.example".into()));
        assert_eq!(cache.get_or("n8n-url", || panic!("cached")).as_deref(), Some("https://n8n.example"));
        cache.put("n8n-url", None);
        assert_eq!(cache.get_or("n8n-url", || panic!("cached")), None);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd windows && cargo test -p coucou --lib secrets::tests`
Expected: FAIL to compile, `cannot find type Cache`.

- [ ] **Step 3: Write minimal implementation**

Replace the body of `secrets.rs` below `KNOWN_KEYS` with:

```rust
use std::collections::BTreeMap;
use std::sync::Mutex;

/// What the keychain answered, by key: pollers and the phone loop ask every
/// few seconds, and only `set` and `clear` (both below) change a key. An answer
/// the keychain could not give (locked, unreachable) is not kept.
struct Cache(Mutex<BTreeMap<&'static str, Option<String>>>);

impl Cache {
    const fn new() -> Self {
        Self(Mutex::new(BTreeMap::new()))
    }

    fn get_or(&self, key: &'static str, load: impl FnOnce() -> Result<Option<String>, ()>) -> Option<String> {
        if let Some(v) = self.0.lock().unwrap_or_else(|e| e.into_inner()).get(key) {
            return v.clone();
        }
        let v = load().ok()?;
        self.0.lock().unwrap_or_else(|e| e.into_inner()).insert(key, v.clone());
        v
    }

    fn put(&self, key: &'static str, value: Option<String>) {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).insert(key, value);
    }
}

static CACHE: Cache = Cache::new();

fn known(key: &str) -> Option<&'static str> {
    KNOWN_KEYS.iter().copied().find(|k| *k == key)
}

fn entry(key: &'static str) -> Option<Entry> {
    Entry::new(SERVICE, key).ok()
}

pub fn get(key: &str) -> Option<String> {
    let key = known(key)?;
    CACHE.get_or(key, || match entry(key).ok_or(())?.get_password() {
        Ok(v) => Ok(Some(v).filter(|v| !v.is_empty())),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(_) => Err(()),
    })
}

pub fn set(key: &str, value: &str) -> Result<(), String> {
    let key = known(key).ok_or_else(|| format!("unknown key {key}"))?;
    let entry = entry(key).ok_or_else(|| format!("unknown key {key}"))?;
    if value.is_empty() {
        let _ = entry.delete_credential();
        CACHE.put(key, None);
        return Ok(());
    }
    entry.set_password(value).map_err(|e| e.to_string())?;
    CACHE.put(key, Some(value.to_string()));
    Ok(())
}

pub fn clear(key: &str) -> Result<(), String> {
    let key = known(key).ok_or_else(|| format!("unknown key {key}"))?;
    let entry = entry(key).ok_or_else(|| format!("unknown key {key}"))?;
    match entry.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => {
            CACHE.put(key, None);
            Ok(())
        }
        Err(e) => Err(e.to_string()),
    }
}

pub fn present(key: &str) -> bool {
    get(key).is_some()
}
```

- [ ] **Step 4: Run tests**

Run: `cd windows && cargo test -p coucou --lib secrets::tests && cargo check -p coucou`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add windows/src-tauri/src/secrets.rs
git commit -m "Windows/Linux: cache keychain answers; refresh them on set and clear"
```

---

### Task 2.6: One HTTP client for the integration pollers, with its timeout (V5)

`integrations.rs:50-55` builds a new `reqwest::Client` for every poll. If the build fails, `.unwrap_or_default()` silently returns a client with no timeout, which could hang a poller forever.

**Files:**
- Modify: `windows/src-tauri/src/integrations.rs` (`client()` and its call sites)

**Interfaces:**
- Produces: `fn client() -> Option<&'static reqwest::Client>`.

- [ ] **Step 1: Write the change**

There is no behaviour a unit test can observe here (the pollers talk to real services). The guard is the compiler plus the existing integration tests. Replace `fn client()` with:

```rust
/// One client for every poller, built once with the 10 s timeout. A client that
/// cannot be built (no TLS backend) means no polling at all, said once in the
/// log, rather than a client without a timeout.
fn client() -> Option<&'static reqwest::Client> {
    static CLIENT: std::sync::LazyLock<Option<reqwest::Client>> = std::sync::LazyLock::new(|| {
        reqwest::Client::builder()
            .timeout(TIMEOUT)
            .build()
            .map_err(|err| log::line(format!("integrations: no HTTP client: {err}")))
            .ok()
    });
    CLIENT.as_ref()
}
```

- [ ] **Step 2: Fix every call site the compiler flags**

Run: `cd windows && cargo check -p coucou`
Expected: errors at each `client()` use. Fix each with this pattern:
- `let http = client();` → `let Some(http) = client() else { return };`
- `client().get(…)` / `client().post(…)` inside a function returning `()` → put `let Some(http) = client() else { return };` before it and use `http.get(…)`.
- In `github_graphql` (returns `Option<Value>`): `let response = client()?.post(…)`.

- [ ] **Step 3: Run tests**

Run: `cd windows && cargo test -p coucou --lib && cargo check -p coucou`
Expected: PASS, no errors.

- [ ] **Step 4: Commit**

```bash
git add windows/src-tauri/src/integrations.rs
git commit -m "Windows/Linux: one HTTP client for the pollers, never one without a timeout"
```

---

### Task 2.7: The log keeps the previous megabyte (V6)

`log.rs:19-22` deletes the whole log at 1 MB, so the lines leading up to a problem are lost exactly when they are needed.

**Files:**
- Modify: `windows/src-tauri/src/log.rs`

**Interfaces:**
- Produces: private `fn append(path: &Path, stamp: &str, message: &str)`; `pub fn line` is unchanged.

- [ ] **Step 1: Write the failing test**

Append to `log.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_full_log_rolls_over_instead_of_vanishing() {
        let dir = std::env::temp_dir().join(format!("coucou-log-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("coucou.log");
        std::fs::write(&path, vec![b'x'; (MAX_LOG + 1) as usize]).unwrap();

        append(&path, "2026-10-11 10:00:00", "after the rollover");

        let old = std::fs::metadata(dir.join("coucou.log.1")).unwrap().len();
        assert_eq!(old, MAX_LOG + 1, "the previous megabyte is kept");
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            "2026-10-11 10:00:00 after the rollover\n"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd windows && cargo test -p coucou --lib log::tests`
Expected: FAIL to compile, `cannot find function append` / `MAX_LOG`.

- [ ] **Step 3: Write minimal implementation**

Replace `log.rs` below the header comment with:

```rust
use std::io::Write;
use std::path::Path;

use crate::{platform, settings};

/// Past this size the log becomes coucou.log.1 (replacing the one before).
const MAX_LOG: u64 = 1_000_000;

pub fn line(message: impl AsRef<str>) {
    let t = platform::local_time();
    let stamp = format!(
        "{:04}-{:02}-{:02} {:02}:{:02}:{:02}",
        t.year, t.month, t.day, t.hour, t.minute, t.second
    );
    let dir = settings::local_dir();
    if platform::ensure_private_dir(&dir).is_err() {
        return;
    }
    append(&dir.join("coucou.log"), &stamp, message.as_ref());
}

/// One line at the end of `path`. A full log rolls over to `<name>.1` rather
/// than being deleted: the lines leading up to a problem are the ones wanted.
fn append(path: &Path, stamp: &str, message: &str) {
    if std::fs::metadata(path).map(|m| m.len() > MAX_LOG).unwrap_or(false) {
        let _ = std::fs::rename(path, path.with_extension("log.1"));
    }
    let mut options = std::fs::OpenOptions::new();
    options.create(true).append(true);
    // Readable by us only, like the macOS log.
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    if let Ok(mut file) = options.open(path) {
        let _ = writeln!(file, "{stamp} {message}");
    }
}
```

- [ ] **Step 4: Run tests**

Run: `cd windows && cargo test -p coucou --lib log::tests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add windows/src-tauri/src/log.rs
git commit -m "Windows/Linux: the log rolls over to coucou.log.1 instead of vanishing"
```

---

### Task 2.8: Session ids from the phone are checked, and a prompt can never become an option (C9, C10)

Problems today:
- `claude_sessions.rs:61,64` joins a phone-sent id into a path: `../…` or an absolute path reads any `*.jsonl`.
- All four `resume()` functions pass the prompt as a bare argument (`claude_sessions.rs:341`, `codex_sessions.rs:317`, `opencode_sessions.rs:161`, `devin_sessions.rs:268`), so a prompt starting with `-` is parsed as an option (Codex has `-c key=value`).
- Rust refuses to start a `.cmd`/`.bat` with a line break in an argument (verified on rustc 1.99: `InvalidInput "batch file arguments are invalid"`), and `find_on_path` (`platform/windows.rs:125`) returns npm's `.cmd` shims.
- The three `resume()` tails are copies of each other.

**Files:**
- Create: `windows/src-tauri/src/cli_sessions.rs`
- Modify: `windows/src-tauri/src/lib.rs` (add `mod cli_sessions;` after `mod cli_chat;`)
- Modify: `windows/src-tauri/src/claude_sessions.rs` (`find_file`, `resume`)
- Modify: `windows/src-tauri/src/codex_sessions.rs` (`resume`)
- Modify: `windows/src-tauri/src/opencode_sessions.rs` (`resume`, `transcript`)
- Modify: `windows/src-tauri/src/devin_sessions.rs` (`resume`, `transcript`)

**Interfaces:**
- Produces in `cli_sessions`:
  - `pub fn valid_id(id: &str) -> bool`
  - `pub fn prompt_arg(query: &str, cli: &Path) -> String`
  - `pub fn answer(out: &std::process::Output, who: &str) -> Result<String, String>`
  - `pub fn log_once(what: &'static str, err: &str)` (used by Task 2.10)

- [ ] **Step 1: Write the failing tests**

Create `windows/src-tauri/src/cli_sessions.rs` containing only the tests for now:

```rust
// What the four CLI session readers (claude_, codex_, opencode_, devin_sessions)
// share: what a session id may be, how a prompt is handed to a CLI, what a
// resumed run answered, and reading their history files.

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    #[test]
    fn ids_that_could_be_paths_or_options_are_refused() {
        for ok in ["0f9c2a8e-1b2c-4d5e-8f90-123456789abc", "ses_abc123", "abcd"] {
            assert!(valid_id(ok), "{ok}");
        }
        for bad in ["", "../../etc/passwd", r"C:\x", "a/b", "a b", "--dangerously-skip-permissions", "-r"] {
            assert!(!valid_id(bad), "{bad}");
        }
        assert!(!valid_id(&"a".repeat(129)));
    }

    #[test]
    fn a_prompt_never_reads_as_an_option() {
        let exe = Path::new("/usr/local/bin/claude");
        assert_eq!(prompt_arg("--model x run it", exe), " --model x run it");
        assert_eq!(prompt_arg("-c approval_policy=never", exe), " -c approval_policy=never");
        assert_eq!(prompt_arg("répare le test", exe), "répare le test");
        assert_eq!(prompt_arg("line one\nline two", exe), "line one\nline two");
        // npm's launcher cannot take a line break at all: it becomes a space.
        let shim = Path::new(r"C:\Users\Zoé\AppData\Roaming\npm\codex.CMD");
        assert_eq!(prompt_arg("line one\r\nline two\n", shim), "line one line two");
        assert_eq!(prompt_arg("-x\nmore", shim), " -x more");
    }

    #[cfg(windows)]
    fn status(ok: bool) -> std::process::ExitStatus {
        std::os::windows::process::ExitStatusExt::from_raw(if ok { 0 } else { 1 })
    }
    #[cfg(unix)]
    fn status(ok: bool) -> std::process::ExitStatus {
        std::os::unix::process::ExitStatusExt::from_raw(if ok { 0 } else { 256 })
    }

    fn output(ok: bool, stdout: &str, stderr: &str) -> std::process::Output {
        std::process::Output { status: status(ok), stdout: stdout.into(), stderr: stderr.into() }
    }

    #[test]
    fn a_run_answers_with_its_output_or_its_first_error_line() {
        assert_eq!(answer(&output(true, "\u{1b}[32mDone.\u{1b}[0m\n", ""), "The Codex CLI"), Ok("Done.".into()));
        assert_eq!(answer(&output(true, "  \n", ""), "The Codex CLI"), Err("No response text.".into()));
        assert_eq!(answer(&output(false, "", "\nError: not logged in\nmore"), "The Codex CLI"), Err("Error: not logged in".into()));
        assert_eq!(answer(&output(false, "", ""), "The Codex CLI"), Err("The Codex CLI failed.".into()));
    }
}
```

Add `mod cli_sessions;` to `lib.rs` after `mod cli_chat;`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd windows && cargo test -p coucou --lib cli_sessions::tests`
Expected: FAIL to compile, `cannot find function valid_id`.

- [ ] **Step 3: Write minimal implementation**

At the top of `cli_sessions.rs`, after the header comment and before `#[cfg(test)]`, add:

```rust
use std::collections::BTreeSet;
use std::path::Path;
use std::sync::Mutex;

use crate::cli_chat;

/// A session id as the CLIs write them — UUIDs, OpenCode's `ses_…`, Devin's
/// prefixes: letters, digits, `-` and `_`, at most 128, and not starting with
/// `-`. The id comes from the phone: anything else (a path, an option) never
/// reaches a file name or a command line.
pub fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && !id.starts_with('-')
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// The prompt as one argument the CLI cannot take for an option: one starting
/// with `-` gets a leading space. A `.cmd`/`.bat` launcher (npm's shims on
/// Windows) cannot be given a line break at all — Rust refuses to start it —
/// so there, and only there, line breaks become spaces.
pub fn prompt_arg(query: &str, cli: &Path) -> String {
    let batch = cli
        .extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| e.eq_ignore_ascii_case("cmd") || e.eq_ignore_ascii_case("bat"));
    let mut prompt = if batch {
        query.split(['\r', '\n']).filter(|l| !l.is_empty()).collect::<Vec<_>>().join(" ")
    } else {
        query.to_string()
    };
    if prompt.starts_with('-') {
        prompt.insert(0, ' ');
    }
    prompt
}

/// What a resumed run answered: its output, or the first line of its error.
/// `who` names the CLI ("The Codex CLI") in the fallback message.
pub fn answer(out: &std::process::Output, who: &str) -> Result<String, String> {
    if out.status.success() {
        let text = cli_chat::strip_ansi(&String::from_utf8_lossy(&out.stdout)).trim().to_string();
        return if text.is_empty() { Err("No response text.".into()) } else { Ok(text) };
    }
    let stderr = cli_chat::strip_ansi(&String::from_utf8_lossy(&out.stderr));
    Err(stderr
        .lines()
        .find(|l| !l.trim().is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| format!("{who} failed.")))
}

/// Logs `what` failing, once per run: a CLI whose store changed shape must show
/// up in coucou.log, not flood it every minute the picker is open.
pub fn log_once(what: &'static str, err: &str) {
    static SEEN: Mutex<BTreeSet<&'static str>> = Mutex::new(BTreeSet::new());
    if SEEN.lock().unwrap_or_else(|e| e.into_inner()).insert(what) {
        crate::log::line(format!("{what}: {err}"));
    }
}
```

Then wire it in:

`claude_sessions.rs` — at the top of `find_file`, add `if !crate::cli_sessions::valid_id(session_id) { return None; }`. Replace `resume` with:

```rust
pub async fn resume(session_id: &str, query: &str) -> Result<String, String> {
    if !crate::cli_sessions::valid_id(session_id) {
        return Err("Unknown session".into());
    }
    let cli = cli_chat::find_cli(&["claude", "claude-code"])
        .ok_or("Claude CLI not found. Install Claude Code, then run `claude` once.")?;
    let file = find_file(session_id).ok_or("Unknown session")?;
    let dir = session_dir(&file).ok_or("No folder to run the session in")?;
    let prompt = crate::cli_sessions::prompt_arg(query, &cli);
    let mut cmd = cli_chat::command(&cli);
    cmd.current_dir(&dir).args(["-p", prompt.as_str(), "--resume", session_id]);
    let out = cli_chat::run(cmd, "the Claude CLI").await?;
    crate::cli_sessions::answer(&out, "The Claude CLI")
}
```

`codex_sessions.rs` — replace `resume` with:

```rust
pub async fn resume(session_id: &str, query: &str) -> Result<String, String> {
    if !crate::cli_sessions::valid_id(session_id) {
        return Err("Unknown session".into());
    }
    let cli = cli_chat::find_cli(&["codex", "codex-cli"])
        .ok_or("Codex CLI not found. Install it, then run `codex login`.")?;
    let file = file_for(session_id).ok_or("Unknown session")?;
    let dir = session_dir(&file).ok_or("No folder to run the session in")?;
    let prompt = crate::cli_sessions::prompt_arg(query, &cli);
    let mut cmd = cli_chat::command(&cli);
    cmd.current_dir(&dir).args(["exec", "resume", session_id, prompt.as_str()]);
    let out = cli_chat::run(cmd, "the Codex CLI").await?;
    crate::cli_sessions::answer(&out, "The Codex CLI")
}
```

`opencode_sessions.rs` — at the top of `transcript`, add `if !crate::cli_sessions::valid_id(session_id) { return Vec::new(); }`. Replace `resume` with:

```rust
pub async fn resume(session_id: &str, query: &str) -> Result<String, String> {
    if !crate::cli_sessions::valid_id(session_id) {
        return Err("Unknown session".into());
    }
    let cli = cli_chat::find_cli(&["opencode"])
        .ok_or("OpenCode CLI not found. Install it, then run `opencode` once.")?;
    let conn = open()?;
    let dir = session_dir(&conn, session_id).ok_or("No folder to run the session in")?;
    let prompt = crate::cli_sessions::prompt_arg(query, &cli);
    let mut cmd = cli_chat::command(&cli);
    cmd.current_dir(&dir).args(["run", "-s", session_id, prompt.as_str()]);
    let out = cli_chat::run(cmd, "the OpenCode CLI").await?;
    crate::cli_sessions::answer(&out, "The OpenCode CLI")
}
```

`devin_sessions.rs` — at the top of `transcript` and `resume`, add the same `valid_id` guard (`return Vec::new()` and `return Err("Unknown session".into())` respectively). In `resume`, replace the `cmd.current_dir(&dir).args(["-p", query, "-r", session_id]);` line with:

```rust
    let prompt = crate::cli_sessions::prompt_arg(query, &cli);
    cmd.current_dir(&dir).args(["-p", prompt.as_str(), "-r", session_id]);
```

- [ ] **Step 4: Run tests**

Run: `cd windows && cargo test -p coucou --lib cli_sessions:: && cargo check -p coucou`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add windows/src-tauri/src/cli_sessions.rs windows/src-tauri/src/lib.rs windows/src-tauri/src/claude_sessions.rs windows/src-tauri/src/codex_sessions.rs windows/src-tauri/src/opencode_sessions.rs windows/src-tauri/src/devin_sessions.rs
git commit -m "Windows/Linux: check phone session ids; a prompt never becomes a CLI option"
```

---

### Task 2.9: Transcripts read the end of the file and survive torn writes; Codex readers never panic (C13)

Problems today:
- `claude_sessions.rs:168` and `codex_sessions.rs:166` use `fs::read_to_string`: a multi-byte character torn mid-write fails the whole transcript, and a 100 MB session is read every 5 s.
- `codex_sessions.rs:69` reads 64 KiB for the `session_meta` line, which carries AGENTS.md and can be longer, so such a session vanishes from the picker.
- `codex_sessions.rs:152-154` slices `&s[5..7]` before validating, which panics on non-ASCII names, and `panic = "abort"` kills the app.

(`file_for`, `codex_sessions.rs:74-78`, stays as it is. It already stops at the first matching rollout, newest first, so caching its answer would risk serving an older file once a newer fork exists.)

**Files:**
- Modify: `windows/src-tauri/src/cli_sessions.rs` (add `read_tail_lossy`, `first_line`, `TRANSCRIPT_TAIL`)
- Modify: `windows/src-tauri/src/claude_sessions.rs` (`transcript` → `transcript_at`)
- Modify: `windows/src-tauri/src/codex_sessions.rs` (`session_id_of`, `session_dir`, `file_stamp`, `transcript`; delete `meta_head`)

**Interfaces:**
- Produces: `pub const TRANSCRIPT_TAIL: u64`, `pub fn read_tail_lossy(path: &Path, max: u64) -> Option<String>`, `pub fn first_line(path: &Path, max: u64) -> Option<String>`; `claude_sessions::transcript_at(path: &Path) -> Vec<ChatLine>`; `codex_sessions::file_stamp(path: &Path) -> String`.

- [ ] **Step 1: Write the failing tests**

Add to `cli_sessions.rs` `mod tests`:

```rust
    fn temp(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("coucou-cli-{name}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn a_long_session_is_read_from_its_end() {
        let path = temp("tail").join("s.jsonl");
        let mut text = String::new();
        for i in 0..200_000 {
            text.push_str(&format!("{{\"n\":{i}}}\n"));
        }
        std::fs::write(&path, &text).unwrap();
        let tail = read_tail_lossy(&path, 64 * 1024).unwrap();
        assert!(tail.len() <= 64 * 1024);
        assert!(tail.starts_with("{\"n\":"), "the first, partial line is dropped");
        assert!(tail.trim_end().ends_with("{\"n\":199999}"));
    }

    #[test]
    fn a_torn_character_at_the_end_does_not_lose_the_transcript() {
        let path = temp("torn").join("s.jsonl");
        let mut bytes = "{\"a\":\"café\"}\n".to_string().into_bytes();
        bytes.extend_from_slice(&[0xE2, 0x82]); // the CLI is mid-write
        std::fs::write(&path, bytes).unwrap();
        assert!(read_tail_lossy(&path, 1024).unwrap().contains("café"));
    }

    #[test]
    fn a_huge_session_meta_line_still_names_the_session() {
        let path = temp("meta").join("rollout.jsonl");
        let line = format!("{{\"payload\":{{\"id\":\"abc\",\"instructions\":\"{}\"}}}}", "i".repeat(200_000));
        std::fs::write(&path, format!("{line}\n{{\"x\":1}}\n")).unwrap();
        assert_eq!(first_line(&path, 4 * 1024 * 1024).unwrap(), line);
    }
```

Add to `claude_sessions.rs` (new module at the end):

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_transcript_keeps_prompts_answers_and_tool_calls() {
        let dir = std::env::temp_dir().join(format!("coucou-claude-tr-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("s.jsonl");
        let mut bytes = concat!(
            r#"{"type":"user","message":{"content":"fix the bug"}}"#, "\n",
            r#"{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}"#, "\n",
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"Done — café"},{"type":"tool_use","name":"Bash","input":{"command":"cargo test"}}]}}"#, "\n",
            r#"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"side"}]}}"#, "\n",
        )
        .to_string()
        .into_bytes();
        bytes.extend_from_slice(&[0xE2, 0x82]);
        std::fs::write(&path, bytes).unwrap();

        let got: Vec<(String, String)> = transcript_at(&path).into_iter().map(|l| (l.role, l.text)).collect();
        assert_eq!(
            got,
            vec![
                ("user".into(), "fix the bug".into()),
                ("assistant".into(), "Done — café".into()),
                ("tool".into(), "cargo test".into()),
            ]
        );
    }
}
```

Add to `codex_sessions.rs` (new module at the end):

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    #[test]
    fn rollout_names_become_short_titles_and_odd_names_never_panic() {
        assert_eq!(file_stamp(Path::new("rollout-2026-10-10T21-57-47-0199a.jsonl")), "Codex 10/10 21:57");
        assert_eq!(file_stamp(Path::new("rollout-éééééééééé.jsonl")), "Codex éééééééééé");
        assert_eq!(file_stamp(Path::new("rollout-short.jsonl")), "Codex short");
    }

    #[test]
    fn a_session_whose_meta_line_is_huge_keeps_its_id() {
        let dir = std::env::temp_dir().join(format!("coucou-codex-meta-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("rollout-2026-01-01T00-00-00-aaa.jsonl");
        let meta = format!(r#"{{"payload":{{"id":"aaa","cwd":"/p","instructions":"{}"}}}}"#, "i".repeat(150_000));
        std::fs::write(&path, format!("{meta}\n")).unwrap();
        assert_eq!(session_id_of(&path).as_deref(), Some("aaa"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd windows && cargo test -p coucou --lib cli_sessions:: claude_sessions:: codex_sessions::`
Expected: FAIL. `read_tail_lossy`, `first_line` and `transcript_at` are missing, `file_stamp` takes `&PathBuf`, and the huge-meta test fails because 64 KiB cuts the line.

- [ ] **Step 3: Write minimal implementation**

In `cli_sessions.rs`, add (above `log_once`):

```rust
/// How much of a session file's end a transcript reads: 40 chat lines, even
/// with long tool calls between them, without loading a 100 MB history.
pub const TRANSCRIPT_TAIL: u64 = 8 * 1024 * 1024;

/// The last `max` bytes of a JSONL file as text. A multi-byte character torn
/// by the CLI writing right now becomes U+FFFD instead of failing the whole
/// read, and the first, partial line of a tail is dropped.
pub fn read_tail_lossy(path: &Path, max: u64) -> Option<String> {
    use std::io::{Read, Seek, SeekFrom};
    let mut file = std::fs::File::open(path).ok()?;
    let len = file.metadata().ok()?.len();
    let start = len.saturating_sub(max);
    file.seek(SeekFrom::Start(start)).ok()?;
    let mut bytes = Vec::with_capacity((len - start) as usize);
    file.read_to_end(&mut bytes).ok()?;
    let text = String::from_utf8_lossy(&bytes).into_owned();
    if start == 0 {
        return Some(text);
    }
    Some(text.split_once('\n').map(|(_, rest)| rest.to_string()).unwrap_or_default())
}

/// The first line of a file, read up to `max` bytes.
pub fn first_line(path: &Path, max: u64) -> Option<String> {
    use std::io::{BufRead, BufReader, Read};
    let file = std::fs::File::open(path).ok()?;
    let mut line = Vec::new();
    BufReader::new(file).take(max).read_until(b'\n', &mut line).ok()?;
    Some(String::from_utf8_lossy(&line).trim_end().to_string())
}
```

In `claude_sessions.rs`, replace `pub fn transcript` with the wrapper and a `transcript_at` that holds the existing loop:

```rust
pub fn transcript(session_id: &str) -> Vec<ChatLine> {
    find_file(session_id).map(|path| transcript_at(&path)).unwrap_or_default()
}

/// The tail of a session file: user prompts, assistant answers, tool calls.
/// Sidechains (sub-agent Task branches) and local-command chatter are left out.
fn transcript_at(path: &std::path::Path) -> Vec<ChatLine> {
    let Some(raw) = crate::cli_sessions::read_tail_lossy(path, crate::cli_sessions::TRANSCRIPT_TAIL) else {
        return Vec::new();
    };
    let mut lines: Vec<ChatLine> = Vec::new();
    for line in raw.lines() {
        // … the existing loop body from `let Ok(v) = serde_json::from_str::<Value>(line)` to the end of the match, unchanged …
    }
    lines.split_at(lines.len().saturating_sub(40)).1.to_vec()
}
```

Move the existing `for line in raw.lines() { … }` body into this function verbatim, and remove the old `find_file` / `read_to_string` lines at the top of the old `transcript`.

In `codex_sessions.rs`:

1. Delete `fn meta_head`. Add near the top: `const META_MAX: u64 = 4 * 1024 * 1024;`.

2. Replace `session_id_of`:

```rust
/// The rollout's session id — what `codex exec resume` takes. Forks carry
/// their parent's session_id, so a session is listed once (newest file wins).
fn session_id_of(path: &Path) -> Option<String> {
    let v = serde_json::from_str::<Value>(&crate::cli_sessions::first_line(path, META_MAX)?).ok()?;
    v.pointer("/payload/session_id")
        .or_else(|| v.pointer("/payload/id"))
        .and_then(|s| s.as_str())
        .map(str::to_string)
}
```

3. Replace `session_dir`:

```rust
fn session_dir(path: &Path) -> Option<PathBuf> {
    let line = crate::cli_sessions::first_line(path, META_MAX)?;
    let dir = serde_json::from_str::<Value>(&line)
        .ok()?
        .pointer("/payload/cwd")
        .and_then(|c| c.as_str())
        .map(PathBuf::from);
    dir.filter(|p| p.is_dir()).or_else(|| cli_chat::workdir("codex-chat").ok())
}
```

4. Replace `file_stamp`:

```rust
/// Fallback title for sessions with no plain-text prompt: "Codex 10/10 21:57"
/// from `rollout-2026-10-10T21-57-47-<id>`. Any other name is shown as it is.
fn file_stamp(path: &Path) -> String {
    let stem = path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or_default()
        .trim_start_matches("rollout-");
    let b = stem.as_bytes();
    let dated = b.len() >= 16
        && b[..16].iter().enumerate().all(|(i, c)| match i {
            4 | 7 | 13 => *c == b'-',
            10 => *c == b'T',
            _ => c.is_ascii_digit(),
        });
    if dated {
        format!("Codex {}/{} {}:{}", &stem[5..7], &stem[8..10], &stem[11..13], &stem[14..16])
    } else {
        format!("Codex {stem}")
    }
}
```

5. In `transcript`, replace `let Ok(raw) = std::fs::read_to_string(&path) else { return Vec::new(); };` with:

```rust
    let Some(raw) = crate::cli_sessions::read_tail_lossy(&path, crate::cli_sessions::TRANSCRIPT_TAIL) else {
        return Vec::new();
    };
```

6. Add `use std::path::Path;` next to `use std::path::PathBuf;`. Where `session_id_of`, `session_dir` and `file_stamp` are called with a `&PathBuf`, nothing changes because `&PathBuf` derefs to `&Path`.

- [ ] **Step 4: Run tests**

Run: `cd windows && cargo test -p coucou --lib cli_sessions:: claude_sessions:: codex_sessions::`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add windows/src-tauri/src/cli_sessions.rs windows/src-tauri/src/claude_sessions.rs windows/src-tauri/src/codex_sessions.rs
git commit -m "Windows/Linux: transcripts read the file's end and survive torn writes; Codex readers never panic"
```

---

### Task 2.10: Devin and OpenCode readers keep NULL rows, read a bounded tail, and log schema changes (C13)

Problems today:
- `devin_sessions.rs:80-88` reads `title`, `working_directory` and `last_activity_at` as non-`Option`, and `.flatten()` then silently drops any row with a NULL.
- `opencode_sessions.rs:66-76` loads every message and part of a session, repeating `m.data` for each part, every 5 s.
- `devin_sessions.rs:123-140` pulls up to 500 full blobs, tool results included.
- A schema change empties the picker with no log line.

**Files:**
- Modify: `windows/src-tauri/src/devin_sessions.rs` (`list_recent` → `list_recent_in`, `transcript` → `transcript_in`)
- Modify: `windows/src-tauri/src/opencode_sessions.rs` (`list_recent`, `transcript` → `transcript_in`)

**Interfaces:**
- Produces: `devin_sessions::list_recent_in(&Connection) -> Vec<SessionMeta>`, `devin_sessions::transcript_in(&Connection, &str) -> Vec<ChatLine>`, `opencode_sessions::transcript_in(&Connection, &str) -> Vec<ChatLine>`.

- [ ] **Step 1: Write the failing tests**

Append to `devin_sessions.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            r#"
            CREATE TABLE sessions (id TEXT, title TEXT, working_directory TEXT, model TEXT,
                                   last_activity_at INTEGER, hidden INTEGER, main_chain_id INTEGER);
            CREATE TABLE message_nodes (node_id INTEGER, parent_node_id INTEGER, session_id TEXT, chat_message TEXT);
            INSERT INTO sessions VALUES ('s-1', NULL, NULL, NULL, NULL, 0, 4);
            INSERT INTO message_nodes VALUES (1, NULL, 's-1', '{"role":"user","content":"list files"}');
            INSERT INTO message_nodes VALUES (2, 1, 's-1', '{"role":"assistant","content":"","tool_calls":[{"name":"exec","arguments":{"command":"ls"}}]}');
            INSERT INTO message_nodes VALUES (3, 2, 's-1', '{"role":"tool","content":"a.txt b.txt"}');
            INSERT INTO message_nodes VALUES (4, 3, 's-1', '{"role":"assistant","content":"Two files."}');
            "#,
        )
        .unwrap();
        conn
    }

    #[test]
    fn a_session_without_a_title_is_still_listed() {
        let list = list_recent_in(&db());
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].id, "s-1");
        assert_eq!(list[0].title, "s-1");
        assert_eq!(list[0].dir, "");
        assert_eq!(list[0].last_activity_at, 0);
    }

    #[test]
    fn tool_results_stay_out_of_the_transcript() {
        let got: Vec<(String, String)> =
            transcript_in(&db(), "s-1").into_iter().map(|l| (l.role, l.text)).collect();
        assert_eq!(
            got,
            vec![
                ("user".into(), "list files".into()),
                ("tool".into(), "ls".into()),
                ("assistant".into(), "Two files.".into()),
            ]
        );
    }
}
```

Append to `opencode_sessions.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::params;

    #[test]
    fn only_the_last_parts_are_read() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            r#"
            CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, data TEXT);
            CREATE TABLE part (id TEXT, message_id TEXT, time_created INTEGER, data TEXT);
            INSERT INTO message VALUES ('m1','ses_1',1,'{"role":"user"}'), ('m2','ses_1',2,'{"role":"assistant"}');
            INSERT INTO part VALUES ('p1','m1',1,'{"type":"text","text":"run the tests"}');
            INSERT INTO part VALUES ('p2','m2',2,'{"type":"tool","tool":"bash","state":{"title":"npm test"}}');
            INSERT INTO part VALUES ('p3','m2',3,'{"type":"text","text":"All green."}');
            "#,
        )
        .unwrap();
        let got: Vec<(String, String)> =
            transcript_in(&conn, "ses_1").into_iter().map(|l| (l.role, l.text)).collect();
        assert_eq!(
            got,
            vec![
                ("user".into(), "run the tests".into()),
                ("tool".into(), "npm test".into()),
                ("assistant".into(), "All green.".into()),
            ]
        );

        // A long session: still answers, still ends on its newest line.
        for i in 0..450 {
            conn.execute(
                "INSERT INTO part VALUES (?1, 'm2', ?2, ?3)",
                params![format!("x{i}"), 10 + i, format!(r#"{{"type":"text","text":"line {i}"}}"#)],
            )
            .unwrap();
        }
        let lines = transcript_in(&conn, "ses_1");
        assert_eq!(lines.len(), 40);
        assert_eq!(lines.last().unwrap().text, "line 449");
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd windows && cargo test -p coucou --lib devin_sessions:: opencode_sessions::`
Expected: FAIL to compile, `cannot find function list_recent_in / transcript_in`.

- [ ] **Step 3: Write minimal implementation**

`devin_sessions.rs`:

```rust
pub fn list_recent() -> Vec<SessionMeta> {
    match open() {
        Ok(conn) => list_recent_in(&conn),
        Err(_) => Vec::new(), // no Devin installed: nothing to say
    }
}

fn list_recent_in(conn: &Connection) -> Vec<SessionMeta> {
    let mut stmt = match conn.prepare(
        "SELECT id, title, working_directory, model, last_activity_at \
         FROM sessions WHERE hidden = 0 ORDER BY last_activity_at DESC LIMIT 96",
    ) {
        Ok(s) => s,
        Err(err) => {
            crate::cli_sessions::log_once("devin sessions", &err.to_string());
            return Vec::new();
        }
    };
    let rows = stmt.query_map([], |r| {
        let id: String = r.get(0)?;
        Ok(SessionMeta {
            title: r.get::<_, Option<String>>(1)?.filter(|t| !t.trim().is_empty()).unwrap_or_else(|| id.clone()),
            dir: r.get::<_, Option<String>>(2)?.unwrap_or_default(),
            model: r.get::<_, Option<String>>(3)?.unwrap_or_default(),
            last_activity_at: r.get::<_, Option<i64>>(4)?.unwrap_or(0),
            id,
        })
    });
    match rows {
        Ok(it) => it.flatten().collect(),
        Err(_) => Vec::new(),
    }
}
```

Split `transcript` the same way: `pub fn transcript(session_id)` keeps the `valid_id` guard from Task 2.8, opens the DB, and returns `transcript_in(&conn, session_id)`. Move the body into `fn transcript_in(conn: &Connection, session_id: &str) -> Vec<ChatLine>`, and in the SQL replace the final line `SELECT chat_message FROM chain ORDER BY depth DESC` with:

```sql
         SELECT chat_message FROM chain \
         WHERE json_extract(chat_message, '$.role') IN ('user', 'assistant') \
         ORDER BY depth DESC
```

On `prepare` error, call `crate::cli_sessions::log_once("devin transcript", &err.to_string());` before returning.

`opencode_sessions.rs`: in `list_recent`'s `prepare` error branch, add `crate::cli_sessions::log_once("opencode sessions", &err.to_string());` (bind the error as `Err(err)`). Split `transcript` into `pub fn transcript(session_id)` (guard, open, delegate) and:

```rust
fn transcript_in(conn: &Connection, session_id: &str) -> Vec<ChatLine> {
    // The newest parts first, a bounded number, with only the role of their
    // message: a long session's thousands of parts and tool outputs stay in the DB.
    let mut stmt = match conn.prepare(
        "SELECT json_extract(m.data, '$.role'), p.data FROM part p \
         JOIN message m ON m.id = p.message_id \
         WHERE m.session_id = ?1 \
         ORDER BY m.time_created DESC, p.time_created DESC \
         LIMIT 400",
    ) {
        Ok(s) => s,
        Err(err) => {
            crate::cli_sessions::log_once("opencode transcript", &err.to_string());
            return Vec::new();
        }
    };
    let rows = stmt.query_map([session_id], |r| Ok((r.get::<_, Option<String>>(0)?, r.get::<_, String>(1)?)));
    let Ok(it) = rows else { return Vec::new() };
    let rows: Vec<(Option<String>, String)> = it.flatten().collect();
    let mut lines: Vec<ChatLine> = Vec::new();
    for (role, praw) in rows.into_iter().rev() {
        let role = role.unwrap_or_default();
        let Ok(part) = serde_json::from_str::<Value>(&praw) else { continue };
        // … the existing `match part.get("type")…` block, unchanged, using `role.as_str()` where it used `role` …
    }
    lines.split_at(lines.len().saturating_sub(40)).1.to_vec()
}
```

Move the existing `match part.get("type").and_then(|t| t.as_str()) { … }` block verbatim into the loop, with `let role = role.as_str();` before it so the inner code compiles unchanged.

- [ ] **Step 4: Run tests**

Run: `cd windows && cargo test -p coucou --lib devin_sessions:: opencode_sessions::`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add windows/src-tauri/src/devin_sessions.rs windows/src-tauri/src/opencode_sessions.rs
git commit -m "Windows/Linux: Devin/OpenCode readers keep untitled sessions and read a bounded tail"
```

---

### Task 2.11: The hook never waits on stdin, gives fire-and-forget events 500 ms, and stamps events with its clock (C15, contract 4)

Problems today:
- `hook/src/main.rs:113` reads stdin to the end before any deadline.
- `:38` gives every PreToolUse/PostToolUse 2 s against a wedged pipe.
- `:81,108` use `std::env::args()`, which panics on a non-UTF-8 argument (abort).
- The island cannot tell a late event from a new one.

**Files:**
- Modify: `windows/hook/src/main.rs`
- Modify: `windows/hook/src/statusline.rs:40-45`

**Interfaces:**
- Produces: `pub fn read_all_within(input: impl Read + Send + 'static, budget: Duration) -> Option<Vec<u8>>`, `pub const STDIN_BUDGET: Duration`, and `prepare(raw, args, env, cwd, now_ms: u64)`, which adds `coucou_ts`.

- [ ] **Step 1: Write the failing tests**

In `hook/src/main.rs` `mod tests`:

1. Change the `run` helper's `prepare(...)` call to `prepare(raw.as_bytes(), &args, &|_| None, "/home/me/here", 1234)`.
2. In `what_cannot_be_read_is_not_forwarded`, add `, 1234` as the last argument to both `prepare(...)` calls.
3. Add:

```rust
    #[test]
    fn every_forwarded_event_carries_the_relays_clock() {
        let (v, _) = run(r#"{"hook_event_name":"PreToolUse","tool_name":"Bash"}"#, "", "");
        assert_eq!(v["coucou_ts"], 1234);
    }

    #[test]
    fn an_agent_that_never_closes_stdin_does_not_hold_the_relay() {
        let (reader, writer) = std::io::pipe().unwrap();
        let started = std::time::Instant::now();
        assert!(read_all_within(reader, Duration::from_millis(200)).is_none());
        assert!(started.elapsed() < Duration::from_secs(1));
        drop(writer);
    }

    #[test]
    fn a_closed_stdin_is_read_whole() {
        let (reader, mut writer) = std::io::pipe().unwrap();
        writer.write_all(br#"{"a":1}"#).unwrap();
        drop(writer);
        assert_eq!(read_all_within(reader, Duration::from_secs(2)).unwrap(), br#"{"a":1}"#);
    }

    #[test]
    fn fire_and_forget_events_get_half_a_second() {
        assert!(FIRE_AND_FORGET_BUDGET <= Duration::from_millis(500));
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd windows && cargo test -p coucou-hook`
Expected: FAIL to compile (`prepare` takes 4 arguments; `read_all_within` is missing).

- [ ] **Step 3: Write minimal implementation**

In `hook/src/main.rs`:

1. `use std::time::{Duration, SystemTime, UNIX_EPOCH};` (replacing `use std::time::Duration;`).

2. Change `const FIRE_AND_FORGET_BUDGET: Duration = Duration::from_secs(2);` to:

```rust
/// Whole-run budget for an event nobody waits on: connect and write, no more.
/// Claude Code waits for this on every tool call, twice.
const FIRE_AND_FORGET_BUDGET: Duration = Duration::from_millis(500);
/// Longest wait for the agent to finish writing the event on stdin.
pub const STDIN_BUDGET: Duration = Duration::from_secs(2);
```

3. Add below `fn print`:

```rust
/// All of `input`, read on a helper thread; `None` if it is still open after
/// `budget` (an agent that never closes our stdin must not hold its own turn).
pub fn read_all_within(mut input: impl Read + Send + 'static, budget: Duration) -> Option<Vec<u8>> {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let mut raw = Vec::new();
        let _ = input.read_to_end(&mut raw);
        let _ = tx.send(raw);
    });
    rx.recv_timeout(budget).ok()
}

/// The arguments as text; one that is not valid Unicode is read lossily
/// instead of aborting the relay (`std::env::args` panics on it).
fn arg_list() -> Vec<String> {
    std::env::args_os().skip(1).map(|a| a.to_string_lossy().into_owned()).collect()
}
```

4. In `fn args()`, replace `let mut it = std::env::args().skip(1);` with `let mut it = arg_list().into_iter();`.

5. In `main()`:
   - `if std::env::args().skip(1).any(|a| a == "--statusline")` → `if arg_list().iter().any(|a| a == "--statusline")`.
   - Replace `let mut raw = Vec::new(); let _ = std::io::stdin().read_to_end(&mut raw);` with:

```rust
    let raw = read_all_within(std::io::stdin(), STDIN_BUDGET).unwrap_or_default();
    let now_ms = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0);
```

   - `prepare(&raw, &args, &env, &cwd)` → `prepare(&raw, &args, &env, &cwd, now_ms)`.

6. Change `fn prepare` to take `now_ms: u64` as its last parameter, and right after `map.insert("hook_event_name".into(), Value::String(name.clone()));` add:

```rust
    // When this relay saw the event: the island orders by it, since separate
    // relay processes can reach it out of order (a PostToolUse after the Stop).
    map.insert("coucou_ts".into(), Value::from(now_ms));
```

7. Remove `use std::io::{Read, Write};` only if unused. `Read` is still needed by `read_all_within` and `Write` by `print`, so keep it.

In `hook/src/statusline.rs`:
- Change `use crate::{talk, truncate_strings, CONNECT_TIMEOUT};` to `use crate::{read_all_within, talk, truncate_strings, CONNECT_TIMEOUT, STDIN_BUDGET};`.
- In `run()`, replace `let mut raw = Vec::new(); let _ = std::io::stdin().read_to_end(&mut raw);` with `let mut raw = read_all_within(std::io::stdin(), STDIN_BUDGET).unwrap_or_default();`.

- [ ] **Step 4: Run tests**

Run: `cd windows && cargo test -p coucou-hook`
Expected: PASS (34 existing + 4 new).

- [ ] **Step 5: Commit**

```bash
git add windows/hook/src/main.rs windows/hook/src/statusline.rs
git commit -m "coucou-hook: bounded stdin, 500 ms for fire-and-forget, coucou_ts on every event"
```

---

### Task 2.12: The pipe tells the island when a held request goes away, and takes no snapshot before the island has the event (C17, C19, contract 5)

Problems today:
- `wait_for_decision` (`pipe.rs:279-312`) never notices the relay leaving (the user answered in the terminal, or the agent gave up), so the card stays up until its own 110 s timer.
- `note_session_window` (`pipe.rs:217`, `:260-276`) takes a full process snapshot before the event is emitted, which delays it behind later events from faster relays.

**Files:**
- Modify: `windows/src-tauri/Cargo.toml` (tokio features)
- Modify: `windows/src-tauri/src/pipe.rs` (`handle`, `wait_for_decision`, new `Outcome`, `peer_closed`, `remember_session_window`; delete `note_session_window`; new `mod tests`)

**Interfaces:**
- Produces: emit `approval-released` with `{ "requestId": id }` on `Outcome::TimedOut | Outcome::Gone`. `async fn wait_for_decision(id: &str, rx: &mut mpsc::Receiver<Reply>, gone: impl Future<Output = ()>) -> Outcome`.

- [ ] **Step 1: Write the failing tests**

Append to `pipe.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn block_on<T>(f: impl std::future::Future<Output = T>) -> T {
        tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(f)
    }

    #[test]
    fn a_relay_that_goes_away_releases_its_card() {
        block_on(async {
            let (_tx, mut rx) = mpsc::channel::<Reply>(4);
            let gone = tokio::time::sleep(Duration::from_millis(20));
            assert_eq!(wait_for_decision("t1", &mut rx, gone).await, Outcome::Gone);
        });
    }

    #[test]
    fn an_acknowledged_card_waits_for_the_click() {
        block_on(async {
            let (tx, mut rx) = mpsc::channel::<Reply>(4);
            tx.send(Reply::Ack).await.unwrap();
            tx.send(Reply::Decision("allow".into())).await.unwrap();
            let outcome = wait_for_decision("t2", &mut rx, std::future::pending::<()>()).await;
            assert_eq!(outcome, Outcome::Decision("allow".into()));
        });
    }

    #[test]
    fn answered_in_the_terminal_after_the_card_was_up() {
        block_on(async {
            let (tx, mut rx) = mpsc::channel::<Reply>(4);
            tx.send(Reply::Ack).await.unwrap();
            let gone = tokio::time::sleep(Duration::from_millis(20));
            assert_eq!(wait_for_decision("t3", &mut rx, gone).await, Outcome::Gone);
        });
    }

    #[test]
    fn a_decline_is_no_decision() {
        block_on(async {
            let (tx, mut rx) = mpsc::channel::<Reply>(4);
            tx.send(Reply::Decline).await.unwrap();
            assert_eq!(wait_for_decision("t4", &mut rx, std::future::pending::<()>()).await, Outcome::Declined);
        });
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd windows && cargo test -p coucou --lib pipe::tests`
Expected: FAIL to compile (`Outcome` is missing; `wait_for_decision` takes 2 arguments).

- [ ] **Step 3: Write minimal implementation**

In `windows/src-tauri/Cargo.toml`, change the tokio line to:

```toml
tokio = { version = "1", features = ["net", "io-util", "sync", "time", "rt", "process", "macros"] }
```

In `pipe.rs`:

1. Replace `wait_for_decision` with:

```rust
/// How a held permission request ended.
#[derive(Debug, PartialEq)]
enum Outcome {
    /// A human clicked: what goes back to the relay.
    Decision(String),
    /// The island said nobody can act on it (paused, full queue, "answer in terminal").
    Declined,
    /// No ack, or no click before the deadline.
    TimedOut,
    /// The relay hung up: the agent stopped waiting (answered in the terminal, gave up).
    Gone,
}

/// Two waits: a short one for "the card is up", then the long one for a human —
/// either cut short by the relay going away.
async fn wait_for_decision(
    id: &str,
    rx: &mut mpsc::Receiver<Reply>,
    gone: impl std::future::Future<Output = ()>,
) -> Outcome {
    tokio::pin!(gone);
    let first = tokio::select! {
        r = tokio::time::timeout(ACK_TIMEOUT, rx.recv()) => r,
        () = &mut gone => {
            log::line(format!("hook id={id} relay gone before the card was up"));
            return Outcome::Gone;
        }
    };
    match first {
        Ok(Some(Reply::Ack)) => {}
        // A click that beats the ack is still a click.
        Ok(Some(Reply::Decision(d))) => {
            log::line(format!("hook id={id} answered {}", loggable(&d)));
            return Outcome::Decision(d);
        }
        Ok(Some(Reply::Decline)) | Ok(None) => {
            log::line(format!("hook id={id} not shown — terminal takes over"));
            return Outcome::Declined;
        }
        Err(_) => {
            log::line(format!("hook id={id} island never acknowledged — terminal takes over"));
            return Outcome::TimedOut;
        }
    }
    tokio::select! {
        r = tokio::time::timeout(DECISION_TIMEOUT, rx.recv()) => match r {
            Ok(Some(Reply::Decision(d))) => {
                log::line(format!("hook id={id} answered {}", loggable(&d)));
                Outcome::Decision(d)
            }
            Ok(Some(Reply::Decline)) => {
                log::line(format!("hook id={id} released without a decision"));
                Outcome::Declined
            }
            _ => {
                log::line(format!("hook id={id} timed out — terminal takes over"));
                Outcome::TimedOut
            }
        },
        () = &mut gone => {
            log::line(format!("hook id={id} relay gone — answered in the terminal"));
            Outcome::Gone
        }
    }
}

/// Resolves when the relay closed its end. It never sends anything after its
/// event, so any read that returns is either nothing (closed) or noise.
async fn peer_closed(pipe: &mut impl Relay) {
    let mut buf = [0u8; 64];
    loop {
        match pipe.read(&mut buf).await {
            Ok(0) | Err(_) => return,
            Ok(_) => {}
        }
    }
}
```

2. Replace `fn note_session_window(…)` with:

```rust
/// Finds, once per session, the window it runs in (session_window.rs). The
/// process snapshot runs on the blocking pool after the island has the event:
/// taken before, it held the event back while a later one from a faster relay
/// went ahead.
fn remember_session_window(relay: Option<u32>, session: Option<String>, event: &str) {
    let Some(session) = session else { return };
    if event == "SessionEnd" {
        session_window::forget(&session);
        return;
    }
    if session_window::known(&session) {
        return;
    }
    let Some(relay) = relay else { return };
    tauri::async_runtime::spawn_blocking(move || {
        let ancestors = crate::platform::process_ancestors(relay);
        // No ancestors: the relay was already gone, so try again next time.
        // Some, but none with a window (a classic console): settled.
        if !ancestors.is_empty() {
            session_window::remember(&session, crate::platform::window_owners(&ancestors));
        }
    });
}
```

3. In `handle`, replace everything from `note_session_window(&pipe, &payload, &event);` to the end of the function with:

```rust
    let session = payload.get("session_id").and_then(Value::as_str).map(str::to_string);
    let relay_pid = pipe.client_pid();
    // Counts for the weekly recap — never the command, path or prompt itself.
    crate::recap::observe(&app, &payload);

    if event != "PermissionRequest" {
        // The status line relay calls in with every Claude Code update: not log-worthy.
        if event != "StatusLine" {
            log::line(format!("hook {event}"));
        }
        let _ = app.emit_to(WINDOW_LABEL, "hook", payload);
        pipe.finish();
        remember_session_window(relay_pid, session, &event);
        return;
    }

    let id = format!("{}-{}", std::process::id(), COUNTER.fetch_add(1, Ordering::Relaxed));
    let (tx, mut rx) = mpsc::channel::<Reply>(4);
    {
        let pending = app.state::<Pending>();
        pending.0.lock().unwrap().insert(id.clone(), tx);
    }
    crate::recap::note_request(&app, &id, &payload);
    payload["request_id"] = json!(id);
    log::line(format!("hook PermissionRequest id={id}"));
    let _ = app.emit_to(WINDOW_LABEL, "hook", payload);
    remember_session_window(relay_pid, session, &event);

    let outcome = wait_for_decision(&id, &mut rx, peer_closed(&mut pipe)).await;
    app.state::<Pending>().0.lock().unwrap().remove(&id);

    match outcome {
        // What we write is a bare word or the answers line; coucou-hook turns it into the agent's JSON.
        Outcome::Decision(d) => {
            let _ = pipe.write_all(format!("{d}\n").as_bytes()).await;
            let _ = pipe.flush().await;
        }
        // The island said so itself. No decision: say nothing at all, and the
        // agent asks in its terminal exactly as if Coucou were closed.
        Outcome::Declined => {}
        // The card may still be up for a request nobody waits on any more.
        Outcome::TimedOut | Outcome::Gone => {
            let _ = app.emit_to(WINDOW_LABEL, "approval-released", json!({ "requestId": id }));
        }
    }
    pipe.finish();
```

- [ ] **Step 4: Run tests**

Run: `cd windows && cargo test -p coucou --lib pipe::tests && cargo check -p coucou`
Expected: PASS.

- [ ] **Step 5: Manual check (after Phase 3 Task 3.3 lands)**

Trigger a Bash permission in Claude Code and answer it in the terminal. The island's card disappears within a second.

- [ ] **Step 6: Commit**

```bash
git add windows/src-tauri/Cargo.toml windows/src-tauri/src/pipe.rs
git commit -m "Windows/Linux: release a card whose relay went away; snapshot after the event is out"
```

---

### Task 2.13: Commands that wait leave the UI thread (C18)

`ingest_file` copies a dropped file of any size on the main thread (`lib.rs:737`, `files.rs:98`). On Windows, `open_session` enumerates every top-level window and takes a process snapshot on it (`lib.rs:300-306`).

**Files:**
- Modify: `windows/src-tauri/src/lib.rs` (`ingest_file`, `open_session`)

**Interfaces:**
- Produces: `async fn ingest_file(path: String) -> Result<DroppedFile, String>` (the front end already awaits a Promise; no TS change).

- [ ] **Step 1: Write the change**

There is nothing to unit-test (Tauri command threading). Replace `ingest_file` with:

```rust
/// Copies a dropped file into the inbox and reports its name back — on the
/// blocking pool: a large file must not freeze the island while it copies.
#[tauri::command]
async fn ingest_file(path: String) -> Result<DroppedFile, String> {
    tauri::async_runtime::spawn_blocking(move || files::ingest(&path))
        .await
        .map_err(|e| e.to_string())?
}
```

In `open_session`, replace everything from `#[cfg(windows)]` to the end of the function with:

```rust
    // Finding and raising the window asks the OS about every top-level window
    // (on Linux the display server, KWin or the terminal): never on the UI
    // thread a sync command runs on. The editor still opens when nothing could
    // bring the window forward.
    std::thread::spawn(move || {
        if !platform::focus_session_window(&owners, &folder) {
            open_editor(path);
        }
    });
    true
```

- [ ] **Step 2: Run tests and check**

Run: `cd windows && cargo test -p coucou --lib && cargo check -p coucou`
Expected: PASS.

- [ ] **Step 3: Manual check (Windows)**

Drop a 2 GB file on the island: the island keeps animating during the copy. Click "Open terminal" on a running session: its Windows Terminal window comes forward.

- [ ] **Step 4: Commit**

```bash
git add windows/src-tauri/src/lib.rs
git commit -m "Windows/Linux: file drops and Open terminal no longer block the UI thread"
```

---

### Task 2.14: The drop-zone watch sleeps while the island is open and slows down while nothing is held (V3)

`island.rs:355-363` wakes every 50 ms forever: 20 wakeups a second while hidden, and also while the island is open, where it only checks a flag. The cursor poll's `PollGate` already says "a hidden island costs literally nothing".

**Files:**
- Modify: `windows/src-tauri/src/island.rs` (`PollGate::wait_until_inactive`; `spawn_drop_zone_watch`; new `fn watch_period`; test in `mod display_tests` or a new `mod tests`)

**Interfaces:**
- Produces: `pub(crate) fn wait_until_inactive(&self)` on `PollGate`, and `fn watch_period(button_down: bool, zone_up: bool) -> Duration`.

- [ ] **Step 1: Write the failing test**

Add to `island.rs`:

```rust
#[cfg(test)]
mod drop_watch_tests {
    use super::*;

    #[test]
    fn the_watch_only_hurries_while_a_button_is_held() {
        assert_eq!(watch_period(true, false), Duration::from_millis(50));
        assert_eq!(watch_period(false, true), Duration::from_millis(50));
        assert_eq!(watch_period(false, false), Duration::from_millis(120));
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd windows && cargo test -p coucou --lib island::drop_watch_tests`
Expected: FAIL to compile, `cannot find function watch_period`.

- [ ] **Step 3: Write minimal implementation**

In `impl PollGate`, add:

```rust
    /// Blocks while the island is open (the cursor poll is active): what only
    /// matters to a hidden island waits here at no cost.
    pub(crate) fn wait_until_inactive(&self) {
        let mut guard = self.active.lock().unwrap();
        while *guard {
            guard = self.cv.wait(guard).unwrap();
        }
    }
```

Add above `spawn_drop_zone_watch`:

```rust
/// How long the hidden island's watch sleeps between looks at the mouse
/// button: quickly while one is held (a drag may be under way), otherwise
/// slower — a drag needs longer than this to reach the top of the screen.
fn watch_period(button_down: bool, zone_up: bool) -> Duration {
    if button_down || zone_up { Duration::from_millis(50) } else { Duration::from_millis(120) }
}
```

In `spawn_drop_zone_watch`'s loop, replace:

```rust
        loop {
            std::thread::sleep(Duration::from_millis(50));
            if !gate.collapsed.load(Ordering::Relaxed) {
                zone_up = false; // the island took over
                was_down = false;
                armed_at = None;
                continue;
            }
```

with:

```rust
        loop {
            if !gate.collapsed.load(Ordering::Relaxed) {
                zone_up = false; // the island took over
                was_down = false;
                armed_at = None;
                // Open, the island takes drops itself: nothing to watch until it hides.
                gate.wait_until_inactive();
                continue;
            }
            std::thread::sleep(watch_period(was_down, zone_up));
```

Update the doc comment of `spawn_drop_zone_watch` to say: "One GetAsyncKeyState every 120 ms while hidden (50 ms while a button is held); parked while the island is open."

- [ ] **Step 4: Run tests**

Run: `cd windows && cargo test -p coucou --lib island:: && cargo check -p coucou`
Expected: PASS.

- [ ] **Step 5: Manual check (Windows)**

With the island hidden, drag a file from Explorer to the top centre of the screen: the island wakes and accepts it. Open the island, then check Process Explorer: the watch thread shows no context switches while it is open.

- [ ] **Step 6: Commit**

```bash
git add windows/src-tauri/src/island.rs
git commit -m "Windows: the drop watch parks while the island is open and slows while idle"
```

---

## Phase 2 done when

- [ ] `cd windows && cargo test --workspace` passes.
- [ ] `cd windows && cargo check --workspace --all-targets` has no warnings.
- [ ] The manual checks in Tasks 2.1, 2.2, 2.4, 2.13 and 2.14 were done on Windows, and on Linux where they apply.
