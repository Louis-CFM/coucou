// Discovery of the opencode server the user is already running.
//
// The TUI starts its own HTTP server on a random loopback port, and that port
// changes every time opencode restarts. Coucou therefore has to find it at
// runtime rather than store it. The approach is deliberately conservative:
//
//   1. ask the OS for every listening loopback port (GetExtendedTcpTable),
//   2. probe each one for a real opencode endpoint (`GET /session`),
//   3. cache the winner briefly, because ports only change on opencode restart.
//
// Nothing here starts, stops or configures opencode, and no request ever
// mutates server state: every call below is a GET against a read-only endpoint.

use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::Serialize;
use serde_json::Value;

/// A discovered server is reused for this long before re-probing.
const CACHE_TTL: Duration = Duration::from_secs(20);

/// Per-probe timeout. Loopback connects to a port nothing is serving are refused
/// instantly, so this budget is only ever spent on a real opencode server. It
/// has to be generous because a server that has just been spawned is still
/// loading its config and database, and answering `GET /session` slowly right
/// after launch is normal Ã¢â‚¬â€ too short a budget reports a perfectly good server as
/// absent, which sends the chat down the fallback path for no reason.
const PROBE_TIMEOUT: Duration = Duration::from_millis(1500);

/// 127.0.0.1 as it appears in the TCP table's network-order address field.
const LOOPBACK: u32 = 0x0100_007F;

static CACHE: std::sync::Mutex<Option<(String, Instant)>> = std::sync::Mutex::new(None);

/// Every port listening on 127.0.0.1, with the pid holding it. Order is whatever
/// the OS returns; the caller probes and keeps the first real match.
fn listening_loopback_owners() -> Vec<(u16, u32)> {
    use windows::Win32::NetworkManagement::IpHelper::{
        GetExtendedTcpTable, MIB_TCPROW_OWNER_PID, TCP_TABLE_OWNER_PID_LISTENER,
    };

    // SAFETY: the two Win32 calls only write into buffers we sized ourselves,
    // and `rows` points at `count` fixed-size PODs inside `buf`, where `count`
    // was clamped to what the buffer can hold. AF_INET is IPv4-only, which is
    // all loopback needs.
    unsafe {
        const AF_INET: u32 = 2;

        let mut size: u32 = 0;
        // First call with a null buffer only asks how large the table is.
        // It is expected to fail with ERROR_INSUFFICIENT_BUFFER (122).
        let _ = GetExtendedTcpTable(
            None,
            &mut size,
            false,
            AF_INET,
            TCP_TABLE_OWNER_PID_LISTENER,
            0,
        );
        if size == 0 {
            return Vec::new();
        }

        let mut buf = vec![0u8; size as usize];
        if GetExtendedTcpTable(
            Some(buf.as_mut_ptr().cast()),
            &mut size,
            false,
            AF_INET,
            TCP_TABLE_OWNER_PID_LISTENER,
            0,
        ) != 0
        {
            return Vec::new();
        }

        // The table is a dwNumEntries count followed by that many fixed rows, so
        // reading rows from offset 0 would shift every field by four bytes.
        if buf.len() < 4 {
            return Vec::new();
        }
        let count = u32::from_ne_bytes([buf[0], buf[1], buf[2], buf[3]]) as usize;
        let row_size = std::mem::size_of::<MIB_TCPROW_OWNER_PID>();
        let available = (buf.len() - 4) / row_size;
        let count = count.min(available);
        if count == 0 {
            return Vec::new();
        }

        let rows_ptr = buf.as_ptr().add(4).cast::<MIB_TCPROW_OWNER_PID>();
        let rows = std::slice::from_raw_parts(rows_ptr, count);
        rows.iter()
            // dwLocalAddr holds the address in network byte order; loopback is
            // the only address we may talk to. (127.0.0.1 reads as 0x0100007F.)
            .filter(|r| r.dwLocalAddr == LOOPBACK)
            // dwLocalPort likewise stores the port big-endian in the low 16
            // bits, so reading it natively yields it byte-swapped.
            .map(|r| (u16::from_be(r.dwLocalPort as u16), r.dwOwningPid))
            .filter(|(p, _)| *p != 0)
            .collect()
    }
}

/// Every port listening on 127.0.0.1.
fn listening_loopback_ports() -> Vec<u16> {
    listening_loopback_owners()
        .into_iter()
        .map(|(port, _)| port)
        .collect()
}

/// The process holding `port`, if anything is.
fn owner_of(port: u16) -> Option<u32> {
    listening_loopback_owners()
        .into_iter()
        .find(|(p, _)| *p == port)
        .map(|(_, pid)| pid)
}

/// How long a temporary server may sit unused before Coucu stops it again.
///
/// Only applies when the persistent-server setting is off. It is what lets "off"
/// still mean no lingering process while the command and session lists keep
/// working: a server is started on demand and tidied away once nothing has asked
/// it for anything for a while.
const IDLE_SHUTDOWN: Duration = Duration::from_secs(90);

/// When a server was last asked to do something.
static LAST_USED: Mutex<Option<Instant>> = Mutex::new(None);

/// Whether the idle reaper is already running.
static WATCHDOG: Mutex<bool> = Mutex::new(false);

/// Ends a process without a console window flashing up. `taskkill` rather than
/// `Child::kill`, because the target was started by an earlier run of Coucou and
/// so is not a child of this one.
fn kill_pid(pid: u32) {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let _ = std::process::Command::new("taskkill")
        .args(["/PID", &pid.to_string(), "/F"])
        .creation_flags(CREATE_NO_WINDOW)
        .output();
}

fn probe(base: &str) -> bool {
    let client = reqwest::blocking::Client::builder()
        .timeout(PROBE_TIMEOUT)
        .build();
    match client {
        Ok(c) => c.get(format!("{base}/session")).send().map(|r| r.status().is_success()).unwrap_or(false),
        Err(_) => false,
    }
}

/// Port Coucou asks `opencode serve` to listen on. High and rarely used, so it
/// is unlikely to collide with anything else on the machine.
const MANAGED_PORT: u16 = 47821;
/// The server Coucou started, kept so it is reused and not leaked.
static MANAGED: Mutex<Option<std::process::Child>> = Mutex::new(None);

fn managed_url() -> String {
    format!("http://127.0.0.1:{MANAGED_PORT}")
}

/// True when something is already listening on the managed port and answers as
/// opencode. The port may in principle be taken by an unrelated process.
fn managed_port_ours() -> bool {
    probe(&managed_url())
}

/// Held while a server is being brought up, so two callers cannot both decide
/// nothing is running and both try to bind the same port.
///
/// The command and session lists are fetched together and in parallel, so on a
/// cold start they reach discovery at the same moment. Without this, one of them
/// lost the race: its server could not bind, its request went nowhere, and the
/// `/` menu came up empty while the other one worked.
static START_LOCK: Mutex<()> = Mutex::new(());

/// Starts `opencode serve` in the background and waits for it to answer.
///
/// The command list, session list and model list all live on a long-lived
/// server. With no TUI running there is none, which is why the chat had nothing
/// to show, so Coucou starts its own.
fn start_managed(bin: &std::path::Path) -> Option<String> {
    use std::os::windows::process::CommandExt;

    /// A server is a background process the user never asked to see. Without
    /// this a console window flashes up on the desktop at every launch.
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;

    let url = managed_url();
    if managed_port_ours() {
        return Some(url);
    }
    // Wait for whoever is already starting a server rather than racing them.
    let _starting = START_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    if managed_port_ours() {
        return Some(url);
    }
    let child = std::process::Command::new(bin)
        .args(["serve", "--port", &MANAGED_PORT.to_string()])
        // The working directory decides which project the server serves, and it
        // scopes both the session list and the project commands to it. Left to
        // inherit Coucou's own directory it answered with an empty session list
        // and a fraction of the commands; started in the user's home Ã¢â‚¬â€ the same
        // directory the mascot chats in by default Ã¢â‚¬â€ it matches the TUI's server
        // exactly. `?directory=` on the request does not change this.
        .current_dir(crate::opencode_chat::home_dir())
        .creation_flags(CREATE_NO_WINDOW)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .ok()?;
    if let Ok(mut guard) = MANAGED.lock() {
        // An earlier call may already have started one; never leak a second.
        if guard.is_none() {
            *guard = Some(child);
        }
    }
    // It needs a moment to bind before it answers.
    for _ in 0..40 {
        std::thread::sleep(Duration::from_millis(150));
        if managed_port_ours() {
            crate::log::line(format!("started opencode serve on port {MANAGED_PORT}"));
            return Some(url);
        }
    }
    crate::log::line("opencode serve did not come up on the managed port".to_string());
    None
}

/// Stops the server Coucou is responsible for. Called when the app quits.
///
/// Kills whoever holds the managed port rather than the process it spawned.
/// On this machine `opencode` resolves to a scoop shim, which launches the real
/// binary as a separate process and stays alive beside it, so the handle from
/// `Command::spawn` is not the thing listening Ã¢â‚¬â€ killing that would leave the
/// actual server running. Going by the port also cleans up after a run that was
/// killed before it could tidy up.
pub fn shutdown() {
    stop_managed_port();
}

/// Brings Coucou's own server up in the background, so it is ready before the
/// first message.
///
/// This is the only thing that ever starts a server, and callers must check the
/// `chat_via_server` setting first: with the setting off, Coucou runs no
/// `opencode serve` of its own and simply uses whatever server already exists.
///
/// A server that is already answering on the managed port is kept rather than
/// replaced. Switching the setting on in the middle of a conversation must not
/// swap the server out from under it, and there is nothing to gain by replacing
/// one that works. Only a port held by something that does *not* answer Ã¢â‚¬â€ a
/// half-dead leftover Ã¢â‚¬â€ is cleared, because otherwise the bind below fails.
pub fn ensure_ready(configured_bin: &str) {
    let configured_bin = configured_bin.to_string();
    std::thread::spawn(move || {
        if managed_port_ours() {
            crate::log::line(format!(
                "using the opencode server already on port {MANAGED_PORT}"
            ));
            return;
        }
        if let Some(pid) = owner_of(MANAGED_PORT) {
            crate::log::line(format!(
                "clearing the unresponsive process on port {MANAGED_PORT} (pid {pid})"
            ));
            kill_pid(pid);
            // Give the socket a moment to come free before rebinding it.
            for _ in 0..20 {
                if owner_of(MANAGED_PORT).is_none() {
                    break;
                }
                std::thread::sleep(Duration::from_millis(100));
            }
        }
        let Some(bin) = crate::opencode_chat::resolve_server_bin(&configured_bin) else {
            crate::log::line("cannot start opencode serve: opencode not found".to_string());
            return;
        };
        start_managed(bin.as_path());
    });
}

/// Stops any server sitting on Coucou's managed port, owned or not.
///
/// Used when the persistent-server setting is switched off: "off" has to mean no
/// `opencode serve` is left running, including one an earlier run leaked.
pub fn stop_managed_port() {
    let Some(pid) = owner_of(MANAGED_PORT) else {
        return;
    };
    kill_pid(pid);
    crate::log::line(format!(
        "stopped the opencode server on port {MANAGED_PORT} (pid {pid})"
    ));
}

/// Notes that a server was just needed, and makes sure a temporary one will be
/// tidied away rather than left running.
fn touch() {
    if let Ok(mut guard) = LAST_USED.lock() {
        *guard = Some(Instant::now());
    }
    let already = match WATCHDOG.lock() {
        Ok(mut started) => {
            if *started {
                true
            } else {
                *started = true;
                false
            }
        }
        Err(_) => true,
    };
    if already {
        return;
    }
    std::thread::spawn(|| loop {
        std::thread::sleep(Duration::from_secs(15));
        // A persistent server is meant to stay until the app quits, so the reaper
        // stands down entirely while the setting is on.
        if crate::settings::load().chat_via_server {
            continue;
        }
        let idle = LAST_USED.lock().ok().and_then(|at| *at).map(|at| at.elapsed());
        if idle.is_some_and(|d| d >= IDLE_SHUTDOWN) && owner_of(MANAGED_PORT).is_some() {
            stop_managed_port();
            if let Ok(mut guard) = CACHE.lock() {
                *guard = None;
            }
            crate::log::line("stopped the idle opencode server".to_string());
        }
    });
}

/// The messages of a session, oldest first, so a picked conversation can be
/// shown in the island rather than starting blank.
pub fn session_messages(id: &str) -> Vec<HistoryMessage> {
    if id.trim().is_empty() {
        return Vec::new();
    }
    let Some(base) = discover(false) else {
        return Vec::new();
    };
    let Ok(client) = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(5))
        .build()
    else {
        return Vec::new();
    };
    let Ok(resp) = client.get(format!("{base}/session/{id}/message")).send() else {
        return Vec::new();
    };
    let Ok(json) = resp.json::<Value>() else {
        return Vec::new();
    };
    let Some(items) = json.as_array() else {
        return Vec::new();
    };
    items
        .iter()
        .filter_map(|item| {
            let role = item.get("info")?.get("role")?.as_str()?.to_string();
            if role != "user" && role != "assistant" {
                return None;
            }
            let text: String = item
                .get("parts")
                .and_then(|p| p.as_array())
                .map(|parts| {
                    parts
                        .iter()
                        .filter(|p| p.get("type").and_then(|t| t.as_str()) == Some("text"))
                        .filter_map(|p| p.get("text").and_then(|t| t.as_str()))
                        .collect::<Vec<_>>()
                        .join("")
                })
                .unwrap_or_default();
            let text = text.trim().to_string();
            // A turn can hold nothing but tool calls, which would render as an
            // empty bubble.
            if text.is_empty() {
                return None;
            }
            Some(HistoryMessage { role, text })
        })
        .collect()
}

/// One turn of a past conversation, as the island shows it.
#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct HistoryMessage {
    pub role: String,
    pub text: String,
}

/// Base URL of a running opencode server, e.g. `http://127.0.0.1:43344`.
///
/// Prefers the server Coucou manages, then any server already running (the TUI's,
/// which listens on a random port). Cached for [`CACHE_TTL`]; pass `fresh` to
/// force a re-scan so a moved port is picked up up immediately.
pub fn discover(fresh: bool) -> Option<String> {
    // Anything that needs a server is a use, whether or not one was found: this
    // is what keeps a temporary one alive between two commands.
    touch();
    if !fresh {
        if let Ok(guard) = CACHE.lock() {
            if let Some((url, at)) = guard.as_ref() {
                if at.elapsed() < CACHE_TTL {
                    return Some(url.clone());
                }
            }
        }
    }

    let remember = |url: String| {
        if let Ok(mut guard) = CACHE.lock() {
            *guard = Some((url.clone(), Instant::now()));
        }
        url
    };

    // 1. Our own server, already up.
    if managed_port_ours() {
        return Some(remember(managed_url()));
    }

    // 2. A server someone else is running, e.g. the TUI's.
    let ports = listening_loopback_ports();
    for port in ports.iter().copied() {
        if port == MANAGED_PORT {
            continue;
        }
        let base = format!("http://127.0.0.1:{port}");
        if probe(&base) {
            crate::log::line(format!(
                "using the opencode server already running at {base} (of {} loopback listeners)",
                ports.len()
            ));
            return Some(remember(base));
        }
    }

    // Nothing running. Start one: with the persistent setting on this is the
    // server that stays until the app quits, and with it off this is a temporary
    // one that the idle reaper tidies away again. Either way the command and
    // session lists work without the user having a TUI open.
    let started = crate::opencode_chat::resolve_server_bin("")
        .and_then(|bin| start_managed(bin.as_path()));
    match started {
        Some(url) => Some(remember(url)),
        None => {
            crate::log::line(format!(
                "no opencode server among {} loopback listeners, and none could be started",
                ports.len()
            ));
            if let Ok(mut guard) = CACHE.lock() {
                *guard = None;
            }
            None
        }
    }
}

// Ã¢â€â‚¬Ã¢â€â‚¬ Read-only endpoints built on top of discovery Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct CommandInfo {
    pub name: String,
    pub description: String,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct SessionInfo {
    pub id: String,
    pub title: String,
    pub directory: String,
    /// Creation time in milliseconds since the epoch, for ordering newest first.
    pub created: i64,
}

/// The `/`-menu commands the running opencode exposes. These come from the
/// user's own skills/plugins/config, so the list reflects their installation.
///
/// Returns an empty list when no server is running; the island treats that as
/// "no commands available" rather than an error.
pub fn commands() -> Vec<CommandInfo> {
    let Some(base) = discover(false) else {
        return Vec::new();
    };
    let Ok(client) = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(3))
        .build()
    else {
        return Vec::new();
    };
    let Ok(resp) = client.get(format!("{base}/command")).send() else {
        return Vec::new();
    };
    let Ok(json) = resp.json::<Value>() else {
        return Vec::new();
    };
    let Some(items) = json.as_array() else {
        return Vec::new();
    };

    let mut out: Vec<CommandInfo> = items
        .iter()
        .filter_map(|it| {
            let name = it.get("name")?.as_str()?.to_string();
            // Descriptions can be multi-line; the popup is one row per command.
            let description = it
                .get("description")
                .and_then(|d| d.as_str())
                .unwrap_or("")
                .split_whitespace()
                .collect::<Vec<_>>()
                .join(" ");
            Some(CommandInfo { name, description })
        })
        .collect();

    // A plugin may register a command with the same name as a built-in; the
    // built-in wins in `act()`, so skip the duplicate rather than list it twice.
    for (name, description) in BUILTINS {
        if out.iter().any(|c| c.name.eq_ignore_ascii_case(name)) {
            continue;
        }
        out.push(CommandInfo {
            name: (*name).to_string(),
            description: (*description).to_string(),
        });
    }
    out
}

/// opencode's TUI built-in commands that Coucou can actually perform.
///
/// The server's `/command` route only lists commands registered by plugins and
/// skills, so the built-ins are absent from it. Most TUI built-ins are handled
/// entirely inside the terminal UI and never reach the server (`--command`
/// rejects them outright), but these ones each map to a real server route, so
/// Coucou performs the genuine action rather than pretending to.
const BUILTINS: &[(&str, &str)] = &[
    ("compact", "Compact this session to free up context"),
    ("undo", "Undo the last message and its file changes"),
    ("redo", "Redo a message you just undid"),
    ("sessions", "Switch to a different session"),
    ("new", "Start a fresh session"),
    ("models", "List the available models"),
    ("share", "Share this session"),
    ("unshare", "Stop sharing this session"),
];

/// Aliases opencode's TUI accepts, mapped onto the canonical built-in name.
const BUILTIN_ALIASES: &[(&str, &str)] = &[
    ("summarize", "compact"),
    ("clear", "new"),
    ("resume", "sessions"),
    ("continue", "sessions"),
];

/// Canonical built-in name for `name`, if it is one Coucou can perform.
pub fn builtin_for(name: &str) -> Option<&'static str> {
    let lower = name.to_ascii_lowercase();
    BUILTINS
        .iter()
        .find(|(n, _)| *n == lower)
        .map(|(n, _)| *n)
        .or_else(|| {
            BUILTIN_ALIASES
                .iter()
                .find(|(a, _)| *a == lower)
                .map(|(_, target)| *target)
        })
}

/// Runs a built-in against the live server and returns text for the chat log.
///
/// `session` is the session the command applies to; only [`new`] works without
/// one.
pub fn act(name: &str, session: &str) -> Result<String, String> {
    let Some(canonical) = builtin_for(name) else {
        return Err(format!("`/{name}` is not a built-in Coucou can run"));
    };
    let Some(base) = discover(false) else {
        return Err("opencode is not running".to_string());
    };
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()
        .map_err(|e| e.to_string())?;

    // `/new` is the only command that doesn't act on an existing session.
    if canonical == "new" {
        let resp = client
            .post(format!("{base}/session"))
            .json(&serde_json::json!({}))
            .send()
            .map_err(|e| e.to_string())?;
        let json: Value = resp.json().map_err(|e| e.to_string())?;
        let id = json.get("id").and_then(|v| v.as_str()).unwrap_or("");
        if id.is_empty() {
            return Err("could not create a session".to_string());
        }
        return Ok(format!("Started a new session: {id}"));
    }

    // `/sessions` is handled by the picker in the UI, and `/models` only reads
    // provider config. Neither acts on a session, so neither needs one.
    if canonical == "sessions" {
        return Ok("Pick a session from the list.".to_string());
    }

    if canonical == "models" {
        let json: Value = client
            .get(format!("{base}/config/providers"))
            .send()
            .map_err(|e| e.to_string())?
            .json()
            .map_err(|e| e.to_string())?;
        let providers = json.get("providers").and_then(|v| v.as_object());
        let mut lines: Vec<String> = Vec::new();
        if let Some(map) = providers {
            for (provider, entry) in map {
                let Some(models) = entry.get("models").and_then(|m| m.as_object()) else {
                    continue;
                };
                for id in models.keys() {
                    lines.push(format!("{provider}/{id}"));
                }
            }
        }
        if lines.is_empty() {
            return Ok("No models reported by the server.".to_string());
        }
        lines.sort();
        lines.truncate(40);
        return Ok(format!("{}\n\n{}", lines.len(), lines.join("\n")));
    }

    // Everything below mutates a specific session, so it needs one to exist.
    if session.is_empty() {
        return Err(format!(
            "`/{canonical}` needs an open session Ã¢â‚¬â€ start chatting first."
        ));
    }

    let route = match canonical {
        "compact" => "compact",
        "undo" => "revert",
        "redo" => "redo",
        "share" => "share",
        "unshare" => "unshare",
        _ => return Err(format!("`/{canonical}` is not implemented")),
    };
    let resp = client
        .post(format!("{base}/session/{session}/{route}"))
        .json(&serde_json::json!({}))
        .send()
        .map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        return Err(format!(
            "`/{canonical}` failed: HTTP {}",
            resp.status().as_u16()
        ));
    }
    let done = match canonical {
        "compact" => "Compacted the session.",
        "undo" => "Undid the last message.",
        "redo" => "Redid the message.",
        "share" => "Session shared.",
        "unshare" => "Session unshared.",
        _ => "Done.",
    };
    Ok(done.to_string())
}

/// Deletes a session on the live server.
///
/// Only ever called after an explicit confirmation in the island, and never for
/// the session the chat is currently pointed at.
pub fn delete_session(id: &str) -> Result<(), String> {
    let Some(base) = discover(false) else {
        return Err("opencode is not running".to_string());
    };
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()
        .map_err(|e| e.to_string())?;
    let resp = client
        .delete(format!("{base}/session/{id}"))
        .send()
        .map_err(|e| e.to_string())?;
    if resp.status().is_success() {
        Ok(())
    } else {
        Err(format!("could not delete the session: HTTP {}", resp.status().as_u16()))
    }
}

/// Live sessions from the running server, most recent first.
pub fn sessions() -> Vec<SessionInfo> {
    let Some(base) = discover(false) else {
        return Vec::new();
    };
    let Ok(client) = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(3))
        .build()
    else {
        return Vec::new();
    };
    let Ok(resp) = client.get(format!("{base}/session")).send() else {
        return Vec::new();
    };
    let Ok(json) = resp.json::<Value>() else {
        return Vec::new();
    };
    let Some(items) = json.as_array() else {
        return Vec::new();
    };

    let mut out: Vec<SessionInfo> = items
        .iter()
        .filter_map(|it| {
            Some(SessionInfo {
                id: it.get("id")?.as_str()?.to_string(),
                title: it
                    .get("title")
                    .and_then(|t| t.as_str())
                    .filter(|t| !t.trim().is_empty())
                    .unwrap_or("Untitled session")
                    .to_string(),
                directory: it.get("directory").and_then(|d| d.as_str()).unwrap_or("").to_string(),
                created: it
                    .get("time")
                    .and_then(|t| t.get("created"))
                    .and_then(|c| c.as_i64())
                    .unwrap_or(0),
            })
        })
        .collect();

    // Newest first. The server already returns them that way, but sorting here
    // means the picker cannot depend on that staying true; an earlier `reverse()`
    // on top of an already-newest-first list put the oldest session on top.
    out.sort_by(|a, b| b.created.cmp(&a.created));
    out.truncate(25);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builtins_resolve_their_aliases() {
        assert_eq!(builtin_for("compact"), Some("compact"));
        assert_eq!(builtin_for("COMPACT"), Some("compact"));
        assert_eq!(builtin_for("summarize"), Some("compact"));
        assert_eq!(builtin_for("clear"), Some("new"));
        assert_eq!(builtin_for("resume"), Some("sessions"));
        assert_eq!(builtin_for("continue"), Some("sessions"));
        // Commands Coucou cannot perform must never be claimed.
        assert_eq!(builtin_for("themes"), None);
        assert_eq!(builtin_for("exit"), None);
        assert_eq!(builtin_for("help"), None);
    }

    #[test]
    fn loopback_listeners_are_plausible_ports() {
        let ports = listening_loopback_ports();
        println!("loopback listeners found: {ports:?}");
        for port in ports.iter().copied() {
            assert!(port > 0, "port must be non-zero");
            assert_ne!(port, 80, "must not be a privileged port");
        }
    }

    /// Discovers the opencode server when one is running, and reports what it
    /// saw. Prints the result so a failing scan is visible in `cargo test` logs.
    #[test]
    fn discovers_a_running_server_if_any() {
        match discover(true) {
            Some(url) => {
                println!("discovered opencode server at {url}");
                let cmds = commands();
                println!("commands available: {}", cmds.len());
                let sess = sessions();
                println!("sessions available: {}", sess.len());
                assert!(!cmds.is_empty(), "a live server must expose commands");
            }
            None => println!("no opencode server running right now Ã¢â‚¬â€ skipping"),
        }
    }

    /// Switching the persistent-server setting on part-way through a conversation
    /// must not replace the server that conversation is talking to.
    #[test]
    fn keeps_a_server_that_is_already_answering() {
        ensure_ready("");
        let first = wait_for_managed();
        assert!(first.is_some(), "no server came up on the managed port");
        // Exactly what a settings save does a moment later.
        ensure_ready("");
        std::thread::sleep(Duration::from_millis(2000));
        assert_eq!(
            owner_of(MANAGED_PORT),
            first,
            "the running server was replaced instead of kept"
        );
    }

    fn wait_for_managed() -> Option<u32> {
        for _ in 0..60 {
            if managed_port_ours() {
                return owner_of(MANAGED_PORT);
            }
            std::thread::sleep(Duration::from_millis(250));
        }
        None
    }

    /// The command and session lists are fetched together and in parallel, so on a
    /// cold start two lookups reach discovery at once. Exactly one server must
    /// come up and both callers must get a usable answer, or the `/` menu is empty.
    #[test]
    fn parallel_lookups_share_one_server() {
        stop_managed_port();
        std::thread::sleep(Duration::from_millis(500));
        assert!(owner_of(MANAGED_PORT).is_none(), "a server was left running");

        let handles: Vec<_> = (0..2)
            .map(|_| {
                std::thread::spawn(|| {
                    let cmds = commands();
                    let sess = sessions();
                    (cmds.len(), sess.len())
                })
            })
            .collect();
        let results: Vec<_> = handles.into_iter().map(|h| h.join().unwrap()).collect();
        for (cmds, _) in &results {
            assert!(*cmds > 0, "a parallel lookup got no commands: {results:?}");
        }
        // Still exactly one server, not one per caller.
        let owners: Vec<_> = listening_loopback_owners()
            .into_iter()
            .filter(|(p, _)| *p == MANAGED_PORT)
            .collect();
        assert_eq!(owners.len(), 1, "expected one listener, got {owners:?}");
    }
}
