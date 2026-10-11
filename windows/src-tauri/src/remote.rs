// Claude Code sessions on other machines, over SSH (Linux).
//
// Per host in Settings → Remote hosts:
//
//   remote: claude → coucou-hook → <runtime dir>/coucou.sock
//                                         │  ssh -R (the user's own ssh, keys and config)
//   here:  $XDG_RUNTIME_DIR/coucou-remote/<host>.sock → pipe::serve → island
//
// SSH is the only authentication: nothing listens on the network. Events that
// arrive on a host's socket are tagged with the host and never looked up
// locally (no window, no folder: they are not on this machine).
//
// Every script sent to a host avoids ', \ and !, so whichever login shell the
// host has (sh, bash, zsh, fish) passes it to `sh -c` unchanged.

use std::collections::{HashMap, HashSet};
use std::sync::Mutex;

use serde::Serialize;
use serde_json::Value;
use tauri::AppHandle;

use crate::config_file;
use crate::hooks::HookPreview;

/// Sessions whose events came over a tunnel: nothing local may be opened for them.
static REMOTE_SESSIONS: Mutex<Option<HashSet<String>>> = Mutex::new(None);

/// Claude Code's ids are UUIDs: a longer one is not a session.
const MAX_SESSION_ID: usize = 128;
/// Remote sessions at once, all hosts together: past it, a new one is dropped.
const MAX_REMOTE_SESSIONS: usize = 256;
/// The one `coucou_` field a host's relay may set; the rest are this machine's to say.
const HOST_FIELDS: &[&str] = &["coucou_diff_truncated"];

/// A remote host's event as this machine takes it, tagged with the host.
/// False: drop it. A host never speaks for a local agent's pill or the plan gauge.
pub fn admit(payload: &mut Value, event: &str, host: &str) -> bool {
    if event == "StatusLine" {
        return false;
    }
    let id = payload.get("session_id").and_then(Value::as_str).unwrap_or_default();
    if id.len() > MAX_SESSION_ID {
        return false;
    }
    if !id.is_empty() && !note(REMOTE_SESSIONS.lock().unwrap().get_or_insert_with(HashSet::new), id, event) {
        return false;
    }
    if !id.is_empty() {
        remember(PLACES.lock().unwrap().get_or_insert_with(HashMap::new), id, event, host, payload);
    }
    let Some(fields) = payload.as_object_mut() else { return false };
    fields.retain(|k, _| !k.starts_with("coucou_") || HOST_FIELDS.contains(&k.as_str()));
    fields.insert("coucou_remote".into(), Value::String(host.to_string()));
    true
}

/// Where a remote session runs: what Open terminal attaches to from here.
#[derive(Clone, Debug, Default, PartialEq)]
struct Place {
    host: String,
    cwd: String,
    tmux: String,
    machine_id: String,
    /// On this same machine: our process the session runs under, and its start time.
    local: Option<(u32, u64)>,
}

/// Kept for the sessions REMOTE_SESSIONS admits, so it is bounded the same way.
static PLACES: Mutex<Option<HashMap<String, Place>>> = Mutex::new(None);

fn remember(places: &mut HashMap<String, Place>, id: &str, event: &str, host: &str, payload: &Value) {
    if event == "SessionEnd" {
        places.remove(id);
        return;
    }
    let place = places.entry(id.to_string()).or_default();
    place.host = host.to_string();
    if let Some(cwd) = payload.get("cwd").and_then(Value::as_str).filter(|c| c.starts_with('/')) {
        place.cwd = cwd.to_string();
    }
    if let Some(tmux) = payload.get("tmux_session").and_then(Value::as_str).filter(|t| is_tmux_name(t)) {
        place.tmux = tmux.to_string();
    }
    if let Some(id) = payload.get("machine_id").and_then(Value::as_str).filter(|m| is_machine_id(m)) {
        place.machine_id = id.to_string();
    }
    let ppid = payload.get("hook_ppid").and_then(Value::as_u64).and_then(|p| u32::try_from(p).ok());
    if let Some(ppid) = ppid.filter(|_| place.local.is_none() && is_this_machine(&place.machine_id)) {
        place.local = own_ancestor(ppid);
    }
}

/// Hex digits and dashes: a Linux machine-id or a Mac's IOPlatformUUID.
fn is_machine_id(s: &str) -> bool {
    (1..=64).contains(&s.len()) && s.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-')
}

#[cfg(target_os = "linux")]
fn is_this_machine(id: &str) -> bool {
    static OURS: std::sync::OnceLock<Option<String>> = std::sync::OnceLock::new();
    OURS.get_or_init(crate::platform::machine_id).as_deref().is_some_and(|ours| same_machine(ours, id))
}

#[cfg(not(target_os = "linux"))]
fn is_this_machine(_id: &str) -> bool {
    false
}

#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn same_machine(ours: &str, theirs: &str) -> bool {
    is_machine_id(ours) && ours.eq_ignore_ascii_case(theirs)
}

/// Walked as the event arrives, while the relay's parent still runs; the start time kept
/// with it tells a later reuse of the pid apart.
#[cfg(target_os = "linux")]
fn own_ancestor(pid: u32) -> Option<(u32, u64)> {
    crate::platform::own_ancestor(pid)
}

#[cfg(not(target_os = "linux"))]
fn own_ancestor(_pid: u32) -> Option<(u32, u64)> {
    None
}

fn is_tmux_name(s: &str) -> bool {
    (1..=64).contains(&s.len()) && s.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
}

fn sh_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

/// `ssh` into the session's host: its tmux session when it has one, else a shell in its folder.
fn ssh_argv(place: &Place) -> Option<Vec<String>> {
    if !valid_host(&place.host) {
        return None;
    }
    let remote = if !place.tmux.is_empty() {
        format!("tmux attach -t {}", sh_quote(&place.tmux))
    } else if !place.cwd.is_empty() {
        format!("cd {} && exec \"$SHELL\" -l", sh_quote(&place.cwd))
    } else {
        "exec \"$SHELL\" -l".to_string()
    };
    Some(["ssh", "-t", "--", &place.host, &remote].map(String::from).to_vec())
}

/// The terminal and the arguments that run `command` in a new window of it.
fn terminal_argv(terminal: &str, command: &[String]) -> Vec<String> {
    let name = std::path::Path::new(terminal).file_name().and_then(|n| n.to_str()).unwrap_or(terminal);
    let lead: &[&str] = match name {
        "foot" | "kitty" => &[],
        "wezterm" => &["start", "--"],
        "gnome-terminal" => &["--"],
        _ => &["-e"],
    };
    std::iter::once(terminal.to_string())
        .chain(lead.iter().map(|a| a.to_string()))
        .chain(command.iter().cloned())
        .collect()
}

/// Who and where an ssh destination connects to. None: what ssh's config says.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
#[derive(Debug, PartialEq)]
struct Destination {
    user: Option<String>,
    host: String,
    port: Option<u16>,
}

/// `host`, `user@host` or `ssh://[user@]host[:port]`, read as ssh reads it.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn destination(text: &str) -> Option<Destination> {
    let (rest, uri) = match text.strip_prefix("ssh://") {
        Some(rest) => (rest, true),
        None => (text, false),
    };
    let (user, mut host) = match rest.rsplit_once('@') {
        Some((user, host)) => (Some(user.to_string()), host),
        None => (None, rest),
    };
    let mut port = None;
    if uri {
        let (bare, tail) = match host.strip_prefix('[') {
            Some(v6) => v6.split_once(']')?,
            None => host.split_once(':').unwrap_or((host, "")),
        };
        let tail = tail.strip_prefix(':').unwrap_or(tail);
        if !tail.is_empty() {
            port = Some(tail.parse().ok()?);
        }
        host = bare;
    }
    let host = host.trim_start_matches('[').trim_end_matches(']').to_ascii_lowercase();
    (!host.is_empty() && !host.starts_with('-')).then_some(Destination { user, host, port })
}

/// OpenSSH's options that take a value (its getopt string).
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
const SSH_VALUE_OPTIONS: &[u8] = b"BDEFIJLOPQRSWbceilmopw";
/// An ssh with one of these holds no terminal session: a tunnel, in the background, a stdio forward, a control command.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
const SSH_NO_SESSION: &[u8] = b"NfWO";

/// An `ssh` command line: where it connects and its remote command. None when it holds no session.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn ssh_call(argv: &[String]) -> Option<(Destination, String)> {
    let (mut user, mut port): (Option<String>, Option<u16>) = (None, None);
    let mut dest = None;
    let mut command = Vec::new();
    let mut options = true;
    let mut args = argv.iter().skip(1);
    while let Some(arg) = args.next() {
        if !options || !arg.starts_with('-') || arg == "-" {
            if dest.is_some() {
                command.push(arg.as_str());
                command.extend(args.map(String::as_str));
                break;
            }
            let found = destination(arg)?;
            user = user.or(found.user.clone());
            port = port.or(found.port);
            dest = Some(found);
            continue;
        }
        if arg == "--" {
            options = false;
            continue;
        }
        for (i, opt) in arg.bytes().enumerate().skip(1) {
            if SSH_NO_SESSION.contains(&opt) {
                return None;
            }
            if !SSH_VALUE_OPTIONS.contains(&opt) {
                continue;
            }
            let value = if i + 1 < arg.len() { &arg[i + 1..] } else { args.next()?.as_str() };
            let (key, value) = match opt {
                b'o' => value.split_once(|c: char| c == '=' || c.is_whitespace()).unwrap_or((value, "")),
                b'l' => ("user", value),
                b'p' => ("port", value),
                _ => ("", ""),
            };
            let value = value.trim_start_matches(|c: char| c == '=' || c.is_whitespace());
            // The first value given wins, as in ssh.
            if key.eq_ignore_ascii_case("user") && user.is_none() {
                user = Some(value.to_string());
            } else if key.eq_ignore_ascii_case("port") && port.is_none() {
                port = value.parse().ok();
            }
            break;
        }
    }
    let mut found = dest?;
    (found.user, found.port) = (user, port);
    Some((found, command.join(" ")))
}

/// The same host, and the same port and user where both name one. Ports
/// differ when only one names one: `localhost:2222` is not `localhost`.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn same_destination(a: &Destination, b: &Destination) -> bool {
    let users = match (&a.user, &b.user) {
        (Some(x), Some(y)) => x == y,
        _ => true,
    };
    a.host == b.host && a.port == b.port && users
}

/// Of the ssh processes to a host — (pid, start time, remote command) — the
/// one running the session's tmux session, else the newest.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn pick_ssh(found: &[(u32, u64, String)], tmux: &str) -> Option<u32> {
    let names_tmux = |command: &str| {
        !tmux.is_empty() && command.split(|c: char| !(c.is_ascii_alphanumeric() || "._-".contains(c))).any(|w| w == tmux)
    };
    found.iter().max_by_key(|(_, start, command)| (names_tmux(command), *start)).map(|(pid, ..)| *pid)
}

/// Brings forward a local terminal already running ssh to the session's host.
#[cfg(target_os = "linux")]
fn focus_open_ssh(place: &Place) -> bool {
    let Some(want) = destination(&place.host) else { return false };
    let found: Vec<(u32, u64, String)> = crate::platform::terminal_processes("ssh")
        .into_iter()
        .filter_map(|(pid, start, argv)| {
            let (dest, command) = ssh_call(&argv)?;
            same_destination(&dest, &want).then_some((pid, start, command))
        })
        .collect();
    let Some(pid) = pick_ssh(&found, &place.tmux) else { return false };
    let names: Vec<&str> = [place.tmux.as_str(), want.host.as_str()].into_iter().filter(|n| !n.is_empty()).collect();
    crate::platform::focus_process_window(pid, &names)
}

/// Open terminal for a remote session: on this same machine, the terminal it
/// runs in (`sudo su other` in our own tmux); else the local terminal already
/// ssh'd into its host; else a new one attached to it over ssh.
#[cfg(target_os = "linux")]
pub fn open_terminal(id: &str) -> bool {
    let Some(place) = PLACES.lock().unwrap().as_ref().and_then(|p| p.get(id).cloned()) else { return false };
    if let Some((pid, _)) = place.local.filter(|(pid, start)| crate::platform::same_process(*pid, *start)) {
        let folder = crate::session_window::folder_name(&place.cwd);
        if crate::platform::focus_process_window(pid, &[folder]) {
            return true;
        }
    }
    let Some(command) = ssh_argv(&place) else { return false };
    if focus_open_ssh(&place) {
        return true;
    }
    let terminal = std::env::var("TERMINAL")
        .ok()
        .filter(|t| !t.is_empty() && !t.contains(char::is_whitespace))
        .and_then(|t| crate::platform::find_on_path(&t))
        .or_else(|| {
            ["foot", "kitty", "alacritty", "wezterm", "gnome-terminal", "konsole", "xterm"]
                .iter()
                .find_map(|t| crate::platform::find_on_path(t))
        });
    let Some(terminal) = terminal else {
        crate::log::line("open terminal: no terminal emulator found for the remote session");
        return false;
    };
    let argv = terminal_argv(&terminal.to_string_lossy(), &command);
    match std::process::Command::new(&argv[0]).args(&argv[1..]).spawn() {
        Ok(_) => true,
        Err(err) => {
            crate::log::line(format!("open terminal: {err}"));
            false
        }
    }
}

#[cfg(not(target_os = "linux"))]
pub fn open_terminal(_id: &str) -> bool {
    false
}

/// Records `id` as remote. False when the set is full and `id` is new.
fn note(set: &mut HashSet<String>, id: &str, event: &str) -> bool {
    if event == "SessionEnd" {
        set.remove(id);
        return true;
    }
    if set.contains(id) {
        return true;
    }
    if set.len() >= MAX_REMOTE_SESSIONS {
        return false;
    }
    set.insert(id.to_string());
    true
}

pub fn is_remote_session(id: &str) -> bool {
    REMOTE_SESSIONS.lock().unwrap().as_ref().is_some_and(|s| s.contains(id))
}

/// What Settings shows next to a host.
#[derive(Serialize, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct HostStatus {
    pub host: String,
    /// "connecting", "connected" or "error".
    pub state: String,
    /// ssh's own words when it failed, verbatim.
    pub error: String,
}

static STATUS: Mutex<Option<HashMap<String, HostStatus>>> = Mutex::new(None);

pub fn status() -> Vec<HostStatus> {
    STATUS.lock().unwrap().as_ref().map(|m| m.values().cloned().collect()).unwrap_or_default()
}

/// A destination `ssh` takes as a host and nothing else: never an option.
pub fn valid_host(host: &str) -> bool {
    !host.is_empty()
        && host.len() <= 255
        && !host.starts_with('-')
        && host.chars().all(|c| c.is_ascii_alphanumeric() || "@._-:[]/".contains(c))
}

/// The host as a file name for its local socket. A hash of the whole host keeps
/// hosts that clean up alike ("a@b", "a_b") apart; the name is cut to stay short.
fn socket_name(host: &str) -> String {
    let safe: String = host
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || "._-".contains(c) { c } else { '_' })
        .take(32)
        .collect();
    // FNV-1a: stable across runs and Rust versions, unlike std's hasher.
    let hash = host.bytes().fold(0xcbf2_9ce4_8422_2325u64, |h, b| (h ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3));
    format!("{safe}-{:08x}.sock", hash as u32)
}

// ── The remote side, as scripts ───────────────────────────────────────────────

/// Where the relay goes on a host, relative to its $HOME.
const REMOTE_RELAY: &str = ".local/share/coucou/bin/coucou-hook";

/// Finds the directory coucou-hook will look in (hook/src/unix.rs: the runtime
/// directory if private, else ~/.coucou), clears a socket a dead tunnel left
/// there (sshd will not bind over it) and prints the socket's path.
const PROBE: &str = r#"u=$(id -u); d=${XDG_RUNTIME_DIR:-/run/user/$u}
case $d in /*) ;; *) d=/run/user/$u ;; esac
ok() { [ -d "$1" ] || return 1; [ -L "$1" ] && return 1; [ "$(stat -c %u "$1")" = "$u" ] || return 1; case $(stat -c %a "$1") in *00) return 0 ;; esac; return 1; }
if ok "$d"; then :; else d=$HOME/.coucou; mkdir -p -m 700 "$d"; ok "$d" || { echo "$d is not a private directory" >&2; exit 1; }; fi
rm -f "$d/coucou.sock"
echo "$d/coucou.sock""#;

/// Prints $HOME, then settings.json; exit 3 when there is none.
const READ_SETTINGS: &str = r#"echo "$HOME"; f=$HOME/.claude/settings.json; if [ -e "$f" ]; then cat "$f"; else exit 3; fi"#;

/// Takes the relay on stdin, checks it runs cleanly on this host (a glibc too old
/// only warns), then puts it in place.
const PUT_RELAY: &str = r#"set -e; d=$HOME/.local/share/coucou/bin; mkdir -p "$d"; t=$d/coucou-hook.new; cleanup() { rm -f "$t"; }; trap cleanup EXIT
cat > "$t"; chmod 755 "$t"; e=$("$t" < /dev/null 2>&1 > /dev/null) || true; if [ -n "$e" ]; then echo "$e" >&2; exit 1; fi
mv -f "$t" "$d/coucou-hook""#;

/// Takes the new settings.json on stdin; backs up the old one first (printing
/// where) and writes through a symlink, keeping the file's mode.
fn put_settings(stamp: &str) -> String {
    format!(
        r#"set -e; f=$HOME/.claude/settings.json; if [ -L "$f" ]; then f=$(readlink -f "$f"); fi; mkdir -p "$(dirname "$f")"
t=$f.coucou-new; cleanup() {{ rm -f "$t"; }}; trap cleanup EXIT
if [ -e "$f" ]; then b=$f.bak-{stamp}; n=0; while [ -e "$b" ]; do n=$((n+1)); b=$f.bak-{stamp}-$n; done; cp -p "$f" "$b"; cp -p "$f" "$t"; echo "$b"; fi
cat > "$t"; mv -f "$t" "$f""#
    )
}

/// Runs `script` on `host` with `input` on its stdin. Ok: stdout and exit code.
/// Err: ssh's own message.
async fn run(host: &str, script: &str, input: &[u8]) -> Result<(Vec<u8>, i32), String> {
    use tokio::io::AsyncWriteExt;
    let mut child = tokio::process::Command::new("ssh")
        .args(["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "--", host])
        .arg(format!("sh -c '{script}'"))
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| format!("ssh: {e}"))?;
    let mut stdin = child.stdin.take().expect("piped");
    let _ = stdin.write_all(input).await;
    drop(stdin);
    let out = child.wait_with_output().await.map_err(|e| format!("ssh: {e}"))?;
    let code = out.status.code().unwrap_or(-1);
    // 255 is ssh itself failing (no route, refused, no key); anything else is the script.
    if code == 255 || (code != 0 && code != 3) {
        return Err(last_line(&out.stderr).unwrap_or_else(|| format!("ssh exited with {code}")));
    }
    Ok((out.stdout, code))
}

fn last_line(bytes: &[u8]) -> Option<String> {
    String::from_utf8_lossy(bytes).lines().rev().map(str::trim).find(|l| !l.is_empty()).map(String::from)
}

// ── Installing the hooks on a host ────────────────────────────────────────────

/// The host's settings.json as it is, and where the relay goes there.
async fn read_remote(host: &str) -> Result<(Option<Vec<u8>>, String), String> {
    let (out, code) = run(host, READ_SETTINGS, b"").await?;
    let split = out.iter().position(|b| *b == b'\n').unwrap_or(out.len());
    let home = String::from_utf8_lossy(&out[..split]).trim().to_string();
    if !home.starts_with('/') {
        return Err(format!("{host}: no home directory"));
    }
    let bytes = (code != 3).then(|| out.get(split + 1..).unwrap_or_default().to_vec());
    Ok((bytes, format!("{home}/{REMOTE_RELAY}")))
}

fn change(bytes: Option<&[u8]>, install: bool, relay: &str) -> Result<(String, String), String> {
    let current = config_file::parse_json(bytes, "settings.json")?;
    let next = crate::hooks::remote_settings(&current, install, relay)?;
    let before = if bytes.is_some() { config_file::pretty(&current) } else { String::new() };
    Ok((before, config_file::pretty(&next)))
}

fn fingerprint(bytes: Option<&[u8]>) -> String {
    bytes.map(config_file::fingerprint).unwrap_or_else(|| "none".into())
}

pub async fn preview(host: &str, install: bool) -> Result<HookPreview, String> {
    if !valid_host(host) {
        return Err(format!("{host}: not a host name"));
    }
    let (bytes, relay) = read_remote(host).await?;
    let (before, after) = change(bytes.as_deref(), install, &relay)?;
    let path = format!("{host}:~/.claude/settings.json");
    Ok(HookPreview {
        diff: config_file::unified_diff(&before, &after),
        backup: if bytes.is_some() { format!("{path}.bak-{}", config_file::stamp()) } else { String::new() },
        settings_path: path,
        fingerprint: fingerprint(bytes.as_deref()),
    })
}

/// Puts the relay on the host (when installing), then writes what the preview
/// showed, unless settings.json changed since. Returns the backup's path.
pub async fn apply(host: &str, install: bool, expected: &str) -> Result<String, String> {
    if !valid_host(host) {
        return Err(format!("{host}: not a host name"));
    }
    let (bytes, relay) = read_remote(host).await?;
    if fingerprint(bytes.as_deref()) != expected {
        return Err(crate::i18n::tf(
            "{path} changed since the preview. Nothing was written — review the new diff.",
            &[("path", &format!("{host}:~/.claude/settings.json"))],
        ));
    }
    let (_, mut after) = change(bytes.as_deref(), install, &relay)?;
    after.push('\n');
    if install {
        let exe = std::fs::read(crate::settings::hook_exe_path()).map_err(|e| format!("coucou-hook: {e}"))?;
        run(host, PUT_RELAY, &exe).await?;
    }
    // ponytail: the file could change between this read and the write (seconds); a remote lock if that ever matters.
    let (out, _) = run(host, &put_settings(&config_file::stamp()), after.as_bytes()).await?;
    Ok(last_line(&out).map(|b| format!("{host}:{b}")).unwrap_or_default())
}

// ── Tunnels ───────────────────────────────────────────────────────────────────

#[cfg(target_os = "linux")]
static TUNNELS: Mutex<Option<HashMap<String, tauri::async_runtime::JoinHandle<()>>>> = Mutex::new(None);

/// Starts a tunnel for each host that has none, and stops those no longer listed.
#[cfg(target_os = "linux")]
pub fn sync(app: &AppHandle, hosts: &[String]) {
    let mut tunnels = TUNNELS.lock().unwrap();
    let tunnels = tunnels.get_or_insert_with(HashMap::new);
    tunnels.retain(|host, task| {
        let keep = hosts.contains(host);
        if !keep {
            // Dropping the task drops its ssh, which kill_on_drop ends.
            task.abort();
            STATUS.lock().unwrap().get_or_insert_with(HashMap::new).remove(host);
        }
        keep
    });
    // Sockets of hosts no longer listed, or left by a Coucou that did not quit cleanly.
    let wanted: Vec<String> = hosts.iter().map(|h| socket_name(h)).collect();
    if let Some(dir) = socket_dir() {
        for entry in std::fs::read_dir(dir).into_iter().flatten().flatten() {
            if !wanted.contains(&entry.file_name().to_string_lossy().to_string()) {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }
    for host in hosts.iter().filter(|h| valid_host(h)) {
        if !tunnels.contains_key(host) {
            let (app, h) = (app.clone(), host.clone());
            tunnels.insert(host.clone(), tauri::async_runtime::spawn(async move { tunnel(app, h).await }));
        }
    }
    emit(app);
}

#[cfg(not(target_os = "linux"))]
pub fn sync(_app: &AppHandle, _hosts: &[String]) {}

fn set_status(app: &AppHandle, host: &str, state: &str, error: String) {
    let status = HostStatus { host: host.to_string(), state: state.to_string(), error };
    STATUS.lock().unwrap().get_or_insert_with(HashMap::new).insert(host.to_string(), status);
    emit(app);
}

fn emit(app: &AppHandle) {
    use tauri::Emitter;
    let _ = app.emit("remote-status", status());
}

#[cfg(target_os = "linux")]
async fn tunnel(app: AppHandle, host: String) {
    use std::time::{Duration, Instant};
    const FIRST_RETRY: Duration = Duration::from_secs(2);
    const LAST_RETRY: Duration = Duration::from_secs(60);
    /// A forward still up after this was accepted: ExitOnForwardFailure exits sooner.
    const SETTLED: Duration = Duration::from_secs(3);

    let local = match listen(&app, &host) {
        Ok(path) => path,
        Err(err) => return set_status(&app, &host, "error", err),
    };
    let mut retry = FIRST_RETRY;
    loop {
        set_status(&app, &host, "connecting", String::new());
        let started = Instant::now();
        let error = match run(&host, PROBE, b"").await {
            Err(err) => err,
            Ok((out, _)) => {
                let remote = String::from_utf8_lossy(&out).trim().to_string();
                if remote.starts_with('/') {
                    forward(&app, &host, &remote, &local, SETTLED).await
                } else {
                    format!("{host}: no socket path from the host")
                }
            }
        };
        crate::log::line(format!("remote {host}: {error}"));
        set_status(&app, &host, "error", error);
        if started.elapsed() > LAST_RETRY {
            retry = FIRST_RETRY;
        }
        tokio::time::sleep(retry).await;
        retry = (retry * 2).min(LAST_RETRY);
    }
}

/// Runs the command after it and ends it with Coucou, even when Coucou is killed
/// outright: the shell watches its stdin, a pipe only Coucou holds, which the kernel
/// closes when Coucou dies. The Mac's TiedProcess runs the same script.
#[cfg(target_os = "linux")]
const TIED: &str = r#"exec 3<&0
"$@" </dev/null & child=$!
(read -r _ <&3; kill $child 2>/dev/null) & watch=$!
trap 'kill $child 2>/dev/null' TERM
wait $child; status=$?
kill $watch 2>/dev/null
exit $status"#;

/// Holds `ssh -R` open until it ends; returns why it ended.
#[cfg(target_os = "linux")]
async fn forward(app: &AppHandle, host: &str, remote: &str, local: &std::path::Path, settled: std::time::Duration) -> String {
    use tokio::io::AsyncReadExt;
    // Tied to Coucou: a forward left behind by a killed Coucou would hold the host's socket.
    let child = tokio::process::Command::new("sh")
        .args(["-c", TIED, "sh", "ssh"])
        .args([
            "-N", "-T",
            "-o", "BatchMode=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2",
            // Its own connection: a shared master would outlive or take down the forward.
            "-o", "ControlPath=none",
            "-R",
        ])
        .arg(format!("{remote}:{}", local.display()))
        .args(["--", host])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true)
        .spawn();
    let mut child = match child {
        Ok(c) => c,
        Err(e) => return format!("ssh: {e}"),
    };
    let _tie = child.stdin.take();
    let mut stderr = child.stderr.take().expect("piped");
    if tokio::time::timeout(settled, child.wait()).await.is_err() {
        set_status(app, host, "connected", String::new());
    }
    let mut err = Vec::new();
    let _ = stderr.read_to_end(&mut err).await;
    let code = child.wait().await.ok().and_then(|s| s.code()).unwrap_or(-1);
    last_line(&err).unwrap_or_else(|| format!("ssh exited with {code}"))
}

#[cfg(target_os = "linux")]
fn socket_dir() -> Option<std::path::PathBuf> {
    crate::platform::relay_socket_path().and_then(|p| p.parent().map(|d| d.join("coucou-remote")))
}

/// The host's socket here, served like the local one but tagged with the host.
#[cfg(target_os = "linux")]
fn listen(app: &AppHandle, host: &str) -> Result<std::path::PathBuf, String> {
    use std::os::unix::fs::PermissionsExt;
    let dir = socket_dir().ok_or("no private runtime directory ($XDG_RUNTIME_DIR)")?;
    crate::platform::ensure_private_dir(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let path = dir.join(socket_name(host));
    let _ = std::fs::remove_file(&path);
    let listener = tokio::net::UnixListener::bind(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    let (app, host) = (app.clone(), host.to_string());
    tauri::async_runtime::spawn(async move { crate::pipe::serve(app, listener, Some(host)).await });
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_remote_session_opens_its_tmux_or_its_folder_over_ssh() {
        let mut places = HashMap::new();
        let start = serde_json::json!({"cwd": "/srv/it's here", "tmux_session": "work-2"});
        remember(&mut places, "s1", "SessionStart", "devbox", &start);
        let argv = ssh_argv(&places["s1"]).unwrap();
        assert_eq!(argv, ["ssh", "-t", "--", "devbox", "tmux attach -t 'work-2'"]);
        let mut no_tmux = places["s1"].clone();
        no_tmux.tmux.clear();
        assert_eq!(ssh_argv(&no_tmux).unwrap()[4], r#"cd '/srv/it'\''s here' && exec "$SHELL" -l"#);
        remember(&mut places, "s1", "PreToolUse", "devbox", &serde_json::json!({"tmux_session": "a;b"}));
        assert_eq!(places["s1"].tmux, "work-2", "an invalid name never replaces a good one");
        no_tmux.host = "-oProxyCommand=x".into();
        assert!(ssh_argv(&no_tmux).is_none());
        remember(&mut places, "s1", "SessionEnd", "devbox", &serde_json::json!({}));
        assert!(places.is_empty());
    }

    #[test]
    fn only_this_machine_finds_the_sessions_process_here() {
        assert!(same_machine("0123abcdef", "0123ABCDEF"));
        assert!(!same_machine("0123abcdef", "0123abcdee"));
        assert!(!same_machine("", ""), "no id here matches nothing");
        for bad in ["", "xyz", "12 34", "../etc", &"a".repeat(65)] {
            assert!(!is_machine_id(bad), "{bad:?}");
        }
        let mut places = HashMap::new();
        let me = u64::from(std::process::id());
        remember(&mut places, "s1", "SessionStart", "devbox", &json!({"machine_id": "0123abcdef", "hook_ppid": me}));
        assert_eq!(places["s1"].machine_id, "0123abcdef");
        assert_eq!(places["s1"].local, None, "another machine's pid is never read here");
        remember(&mut places, "s1", "PreToolUse", "devbox", &json!({"machine_id": "a;b", "hook_ppid": "12"}));
        assert_eq!(places["s1"].machine_id, "0123abcdef", "an invalid id never replaces a good one");
        #[cfg(target_os = "linux")]
        if let Some(here) = crate::platform::machine_id() {
            remember(&mut places, "s2", "SessionStart", "localhost", &json!({"machine_id": here, "hook_ppid": me}));
            assert_eq!(places["s2"].local.map(|(pid, _)| pid), Some(std::process::id()), "our own process, found here");
            remember(&mut places, "s3", "SessionStart", "localhost", &json!({"machine_id": here, "hook_ppid": u64::MAX}));
            assert_eq!(places["s3"].local, None, "not a pid");
        }
    }

    fn argv(line: &str) -> Vec<String> {
        line.split(' ').map(String::from).collect()
    }

    fn dest(user: Option<&str>, host: &str, port: Option<u16>) -> Destination {
        Destination { user: user.map(String::from), host: host.into(), port }
    }

    #[test]
    fn a_destination_is_read_as_ssh_reads_it() {
        assert_eq!(destination("devbox"), Some(dest(None, "devbox", None)));
        assert_eq!(destination("me@Build.Example.org"), Some(dest(Some("me"), "build.example.org", None)));
        assert_eq!(destination("ssh://mastodon@localhost:23456"), Some(dest(Some("mastodon"), "localhost", Some(23456))));
        assert_eq!(destination("ssh://[::1]:2222"), Some(dest(None, "::1", Some(2222))));
        assert_eq!(destination("a@b@host"), Some(dest(Some("a@b"), "host", None)));
        assert_eq!(destination("[fe80::1]"), Some(dest(None, "fe80::1", None)));
        assert_eq!(destination("ssh://host:x"), None);
        assert_eq!(destination("me@"), None);
        assert_eq!(destination("-oProxyCommand=x"), None);
    }

    #[test]
    fn an_ssh_command_line_gives_its_destination_and_command() {
        let call = |line: &str| ssh_call(&argv(line));
        assert_eq!(call("ssh devbox"), Some((dest(None, "devbox", None), String::new())));
        // Values glued or apart, flags clustered with a value option last.
        assert_eq!(call("ssh -p 2222 -i key me@h").unwrap().0, dest(Some("me"), "h", Some(2222)));
        assert_eq!(call("ssh -tp2222 -l me h").unwrap().0, dest(Some("me"), "h", Some(2222)));
        assert_eq!(call("ssh -oPort=2200 -o User=you h").unwrap().0, dest(Some("you"), "h", Some(2200)));
        // A value is never the destination.
        assert_eq!(call("ssh -J jump -F cfg -L 8080:x:80 -E log -b 0.0.0.0 h").unwrap().0, dest(None, "h", None));
        // Options after the destination still count; the first value given wins.
        assert_eq!(call("ssh me@h -p 2222 -l other").unwrap().0, dest(Some("me"), "h", Some(2222)));
        assert_eq!(call("ssh -l me -p 1 ssh://you@h:2").unwrap().0, dest(Some("me"), "h", Some(1)));
        // The rest is the remote command, options and all.
        assert_eq!(call("ssh -t h tmux attach -t main").unwrap().1, "tmux attach -t main");
        assert_eq!(call("ssh -- h -p 1").unwrap(), (dest(None, "h", None), "-p 1".to_string()));
        // No session: a tunnel, in the background, a stdio forward, a control command.
        for line in ["ssh -N -R x:y h", "ssh -fN h", "ssh -W h:22 jump", "ssh -O check h", "ssh -NT -o BatchMode=yes -- h"] {
            assert_eq!(call(line), None, "{line}");
        }
        // Nothing to connect to.
        assert_eq!(call("ssh"), None);
        assert_eq!(call("ssh -p"), None);
        assert_eq!(call("ssh -v"), None);
    }

    #[test]
    fn a_process_matches_the_host_as_it_was_typed() {
        let host = destination("ssh://mastodon@localhost:23456").unwrap();
        let of = |line: &str| ssh_call(&argv(line)).unwrap().0;
        assert!(same_destination(&of("ssh -p 23456 mastodon@localhost"), &host));
        assert!(same_destination(&of("ssh -p 23456 LOCALHOST"), &host));
        assert!(!same_destination(&of("ssh mastodon@localhost"), &host), "another port");
        assert!(!same_destination(&of("ssh -p 23456 root@localhost"), &host), "another user");
        assert!(!same_destination(&of("ssh -p 23456 otherhost"), &host));
        let alias = destination("devbox").unwrap();
        assert!(same_destination(&of("ssh -A me@devbox"), &alias));
        assert!(!same_destination(&of("ssh -p 2222 devbox"), &alias));
    }

    #[test]
    fn the_ssh_running_the_sessions_tmux_wins_else_the_newest() {
        let found = vec![
            (10, 500, String::new()),
            (11, 900, "htop".to_string()),
            (12, 100, "tmux attach -t 'work-2'".to_string()),
            (13, 50, "tmux attach -t work-22".to_string()),
        ];
        assert_eq!(pick_ssh(&found, "work-2"), Some(12));
        assert_eq!(pick_ssh(&found, ""), Some(11));
        assert_eq!(pick_ssh(&found, "other"), Some(11));
        assert_eq!(pick_ssh(&[], "work-2"), None);
    }

    #[test]
    fn each_terminal_gets_its_own_way_to_run_a_command() {
        let cmd: Vec<String> = ["ssh", "-t", "--", "h", "x"].map(String::from).to_vec();
        assert_eq!(terminal_argv("/usr/bin/foot", &cmd)[1], "ssh");
        assert_eq!(terminal_argv("/usr/bin/wezterm", &cmd)[1..3], ["start", "--"]);
        assert_eq!(terminal_argv("/usr/bin/gnome-terminal", &cmd)[1], "--");
        assert_eq!(terminal_argv("/usr/bin/xterm", &cmd)[1], "-e");
    }
    use serde_json::json;

    #[test]
    fn hosts_are_never_options() {
        for ok in ["devbox", "me@build.example.org", "[::1]", "host-2_a", "ssh://me@10.0.0.2:2222"] {
            assert!(valid_host(ok), "{ok}");
        }
        for bad in ["", "-oProxyCommand=x", "a b", "a;b", "a'b", "$(x)", "a\nb"] {
            assert!(!valid_host(bad), "{bad:?}");
        }
    }

    #[test]
    fn scripts_survive_any_login_shell() {
        for script in [PROBE, READ_SETTINGS, PUT_RELAY, &put_settings("20260102-030405")] {
            assert!(!script.contains(['\'', '\\', '!']), "{script}");
        }
    }

    /// Against a real host: COUCOU_TEST_HOST=<ssh destination> cargo test -p coucou remote -- --ignored
    #[test]
    #[ignore]
    fn installs_on_a_real_host() {
        let host = std::env::var("COUCOU_TEST_HOST").expect("COUCOU_TEST_HOST");
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        rt.block_on(async {
            let socket = run(&host, PROBE, b"").await.unwrap();
            eprintln!("socket: {}", String::from_utf8_lossy(&socket.0).trim());
            let plan = preview(&host, true).await.unwrap();
            eprintln!("diff:\n{}\nbackup: {:?}", plan.diff, plan.backup);
            match apply(&host, true, &plan.fingerprint).await {
                Ok(backup) => eprintln!("installed, backup {backup:?}"),
                Err(err) => eprintln!("install failed: {err}"),
            }
            assert!(apply(&host, true, "stale").await.is_err());
        });
    }

    /// The pid of `shell`'s child called `name`.
    #[cfg(target_os = "linux")]
    fn child_named(shell: u32, name: &str) -> Option<i32> {
        for _ in 0..50 {
            let out = std::process::Command::new("pgrep").args(["-P", &shell.to_string(), "-x", name]).output().ok()?;
            if let Some(pid) = String::from_utf8_lossy(&out.stdout).lines().next().and_then(|l| l.trim().parse().ok()) {
                return Some(pid);
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        None
    }

    #[cfg(target_os = "linux")]
    fn gone(pid: i32) -> bool {
        for _ in 0..50 {
            if unsafe { libc::kill(pid, 0) } != 0 {
                return true;
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        false
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn a_tied_command_ends_when_coucou_is_killed() {
        use std::process::{Command, Stdio};
        let mut sh = Command::new("sh")
            .args(["-c", TIED, "sh", "sleep", "300"])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .spawn()
            .unwrap();
        let sleep = child_named(sh.id(), "sleep").expect("the command runs");
        // Coucou killed outright: kill_on_drop's SIGKILL, and the pipe closes with it.
        unsafe { libc::kill(sh.id() as i32, libc::SIGKILL) };
        drop(sh.stdin.take());
        let _ = sh.wait();
        assert!(gone(sleep));
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn a_tied_command_keeps_its_status_and_stderr() {
        use std::process::{Command, Stdio};
        let mut sh = Command::new("sh")
            .args(["-c", TIED, "sh", "sh", "-c", "echo why >&2; exit 3"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        // Held as forward() holds it: closing it is Coucou going away.
        let _tie = sh.stdin.take();
        let out = sh.wait_with_output().unwrap();
        assert_eq!(out.status.code(), Some(3));
        assert_eq!(out.stderr, b"why\n");
    }

    #[test]
    fn socket_names_stay_plain_and_apart() {
        assert!(socket_name("me@[::1]:22").starts_with("me____1__22-"));
        assert!(socket_name("devbox").ends_with(".sock"));
        assert_eq!(socket_name("devbox"), socket_name("devbox"));
        // Hosts that clean up alike still get a socket each.
        assert_ne!(socket_name("a@b"), socket_name("a_b"));
        assert!(socket_name(&"h".repeat(200)).len() <= 46);
    }

    fn event(fields: Value) -> Value {
        let mut payload = json!({ "hook_event_name": "PreToolUse", "session_id": "0f8fad5b-d9cb-469f-a165-70867728950e" });
        payload.as_object_mut().unwrap().extend(fields.as_object().unwrap().clone());
        payload
    }

    #[test]
    fn a_hosts_event_keeps_only_what_a_host_may_say() {
        let mut payload = event(json!({ "coucou_agent": "codex", "coucou_remote": "spoofed", "coucou_diff_truncated": true }));
        assert!(admit(&mut payload, "PreToolUse", "devbox"));
        assert_eq!(payload["coucou_remote"], "devbox");
        assert!(payload.get("coucou_agent").is_none(), "a host never speaks for a local agent's pill");
        assert_eq!(payload["coucou_diff_truncated"], true);
    }

    #[test]
    fn a_hosts_status_line_and_oversized_ids_are_dropped() {
        let mut status = event(json!({ "hook_event_name": "StatusLine" }));
        assert!(!admit(&mut status, "StatusLine", "devbox"), "the plan gauge is this machine's");
        let mut long = event(json!({ "session_id": "x".repeat(MAX_SESSION_ID + 1) }));
        assert!(!admit(&mut long, "PreToolUse", "devbox"));
    }

    #[test]
    fn remote_sessions_are_capped() {
        let mut set = HashSet::new();
        for n in 0..MAX_REMOTE_SESSIONS {
            assert!(note(&mut set, &format!("cap-{n}"), "SessionStart"));
        }
        assert!(!note(&mut set, "cap-one-more", "SessionStart"), "a full set takes no new session");
        assert!(note(&mut set, "cap-0", "PreToolUse"), "a known one still passes");
        assert!(note(&mut set, "cap-0", "SessionEnd"));
        assert!(note(&mut set, "cap-one-more", "SessionStart"), "room again once one ends");
    }

    #[test]
    fn scripts_quote_their_cleanup() {
        for script in [PUT_RELAY.to_string(), put_settings("20261011-0100")] {
            assert!(!script.contains(r#"trap "rm -f $t""#), "{script}");
            assert!(script.contains(r#"rm -f "$t""#), "{script}");
        }
    }
}
