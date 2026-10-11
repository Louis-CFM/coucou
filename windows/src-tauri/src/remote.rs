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
    let Some(fields) = payload.as_object_mut() else { return false };
    fields.retain(|k, _| !k.starts_with("coucou_") || HOST_FIELDS.contains(&k.as_str()));
    fields.insert("coucou_remote".into(), Value::String(host.to_string()));
    true
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

// ── This install on a host ────────────────────────────────────────────────────
//
// Any number of Coucous can share a host: each has its own socket there,
// `~/.coucou/<id>.sock`, and its own hook entries, which name that socket in
// COUCOU_SOCKET. An install only ever touches entries naming its own socket.

static CLIENT_ID: Mutex<String> = Mutex::new(String::new());

/// Eight lowercase hex digits, as `new_client_id` makes them.
pub fn valid_client_id(id: &str) -> bool {
    id.len() == 8 && id.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

pub fn new_client_id() -> String {
    use std::hash::{BuildHasher, Hasher};
    // RandomState is seeded from the OS's randomness.
    format!("{:08x}", std::collections::hash_map::RandomState::new().build_hasher().finish() as u32)
}

fn client_id() -> Result<String, String> {
    let id = CLIENT_ID.lock().unwrap().clone();
    if valid_client_id(&id) { Ok(id) } else { Err("no remote client id".into()) }
}

// ── The remote side, as scripts ───────────────────────────────────────────────

/// Where the relays go on a host, relative to its $HOME: the static binary on
/// Linux, the Python one (hook/coucou-hook.py) on macOS.
const RELAY_DIR: &str = ".local/share/coucou/bin";
const LINUX_RELAY: &str = "coucou-hook";
const MAC_RELAY: &str = "coucou-hook.py";
const PY_RELAY: &str = include_str!("../../hook/coucou-hook.py");

/// Makes ~/.coucou private, clears this install's socket a dead tunnel left there
/// (sshd will not bind over it) and prints its path. Nothing else there is touched.
fn probe(id: &str) -> String {
    format!(
        r#"d=$HOME/.coucou; mkdir -p "$d"; if [ -L "$d" ]; then echo "$d is a symlink" >&2; exit 1; fi; chmod 700 "$d"
[ -d "$d" ] && [ -O "$d" ] || {{ echo "$d is not a private directory" >&2; exit 1; }}
rm -f "$d/{id}.sock"; echo "$d/{id}.sock""#
    )
}

/// Prints $HOME and the OS, then settings.json; exit 3 when there is none.
const READ_SETTINGS: &str = r#"echo "$HOME"; uname -s; f=$HOME/.claude/settings.json; if [ -e "$f" ]; then cat "$f"; else exit 3; fi"#;

/// Takes the relay on stdin, checks it runs cleanly on this host (a glibc too old
/// only warns, a missing python3 only complains), then puts it in place.
fn put_relay(name: &str) -> String {
    format!(
        r#"set -e; d=$HOME/{RELAY_DIR}; mkdir -p "$d"; t=$d/{name}.new; cleanup() {{ rm -f "$t"; }}; trap cleanup EXIT
cat > "$t"; chmod 755 "$t"; e=$("$t" < /dev/null 2>&1 > /dev/null) || true; if [ -n "$e" ]; then echo "$e" >&2; exit 1; fi
mv -f "$t" "$d/{name}""#
    )
}

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

/// A host as an install sees it: its settings.json, and where this install's
/// relay and socket sit there.
struct Remote {
    bytes: Option<Vec<u8>>,
    relay: String,
    socket: String,
    mac: bool,
}

async fn read_remote(host: &str, id: &str) -> Result<Remote, String> {
    let (out, code) = run(host, READ_SETTINGS, b"").await?;
    let mut lines = out.splitn(3, |b| *b == b'\n');
    let home = String::from_utf8_lossy(lines.next().unwrap_or_default()).trim().to_string();
    let mac = String::from_utf8_lossy(lines.next().unwrap_or_default()).trim() == "Darwin";
    if !home.starts_with('/') {
        return Err(format!("{host}: no home directory"));
    }
    let bytes = (code != 3).then(|| lines.next().unwrap_or_default().to_vec());
    let name = if mac { MAC_RELAY } else { LINUX_RELAY };
    Ok(Remote { bytes, relay: format!("{home}/{RELAY_DIR}/{name}"), socket: format!("{home}/.coucou/{id}.sock"), mac })
}

/// settings.json before and after, and how many other Coucou entries it keeps.
fn change(remote: &Remote, install: bool, id: &str) -> Result<(String, String, usize), String> {
    let bytes = remote.bytes.as_deref();
    let current = config_file::parse_json(bytes, "settings.json")?;
    let next = crate::hooks::remote_settings(&current, install, &remote.relay, &remote.socket, id)?;
    let others = crate::hooks::other_coucou_entries(&current, crate::hooks::Owner::Remote(id));
    let before = if bytes.is_some() { config_file::pretty(&current) } else { String::new() };
    Ok((before, config_file::pretty(&next), others))
}

fn fingerprint(bytes: Option<&[u8]>) -> String {
    bytes.map(config_file::fingerprint).unwrap_or_else(|| "none".into())
}

pub async fn preview(host: &str, install: bool) -> Result<HookPreview, String> {
    if !valid_host(host) {
        return Err(format!("{host}: not a host name"));
    }
    let id = client_id()?;
    let remote = read_remote(host, &id).await?;
    let (before, after, others) = change(&remote, install, &id)?;
    let mut diff = config_file::unified_diff(&before, &after);
    if others > 0 {
        let note = crate::i18n::tf(
            "{count} hooks of other Coucou installs stay as they are: this host's own Coucou, other computers, or an older install.",
            &[("count", &others.to_string())],
        );
        diff = format!("{note}\n{diff}");
    }
    let path = format!("{host}:~/.claude/settings.json");
    Ok(HookPreview {
        diff,
        backup: if remote.bytes.is_some() { format!("{path}.bak-{}", config_file::stamp()) } else { String::new() },
        settings_path: path,
        fingerprint: fingerprint(remote.bytes.as_deref()),
    })
}

/// Puts the relay on the host (when installing), then writes what the preview
/// showed, unless settings.json changed since. Returns the backup's path.
pub async fn apply(host: &str, install: bool, expected: &str) -> Result<String, String> {
    if !valid_host(host) {
        return Err(format!("{host}: not a host name"));
    }
    let id = client_id()?;
    let remote = read_remote(host, &id).await?;
    if fingerprint(remote.bytes.as_deref()) != expected {
        return Err(crate::i18n::tf(
            "{path} changed since the preview. Nothing was written — review the new diff.",
            &[("path", &format!("{host}:~/.claude/settings.json"))],
        ));
    }
    let (_, mut after, _) = change(&remote, install, &id)?;
    after.push('\n');
    if install && remote.mac {
        run(host, &put_relay(MAC_RELAY), PY_RELAY.as_bytes()).await?;
    } else if install {
        let exe = std::fs::read(crate::settings::hook_exe_path()).map_err(|e| format!("coucou-hook: {e}"))?;
        run(host, &put_relay(LINUX_RELAY), &exe).await?;
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
pub fn sync(app: &AppHandle, hosts: &[String], id: &str) {
    *CLIENT_ID.lock().unwrap() = id.to_string();
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
pub fn sync(_app: &AppHandle, _hosts: &[String], id: &str) {
    *CLIENT_ID.lock().unwrap() = id.to_string();
}

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
        let probed = match client_id() {
            Ok(id) => run(&host, &probe(&id), b"").await,
            Err(err) => Err(err),
        };
        let error = match probed {
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
        for script in [&probe("0a1b2c3d"), READ_SETTINGS, &put_relay(LINUX_RELAY), &put_relay(MAC_RELAY), &put_settings("20260102-030405")] {
            assert!(!script.contains(['\'', '\\', '!']), "{script}");
        }
    }

    /// Against a real host: COUCOU_TEST_HOST=<ssh destination> [COUCOU_TEST_ID=<id>]
    /// [COUCOU_TEST_REMOVE=1] cargo test -p coucou remote -- --ignored
    #[test]
    #[ignore]
    fn installs_on_a_real_host() {
        let host = std::env::var("COUCOU_TEST_HOST").expect("COUCOU_TEST_HOST");
        let id = std::env::var("COUCOU_TEST_ID").unwrap_or_else(|_| "0a1b2c3d".into());
        let install = std::env::var_os("COUCOU_TEST_REMOVE").is_none();
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        rt.block_on(async {
            *CLIENT_ID.lock().unwrap() = id.clone();
            let socket = run(&host, &probe(&id), b"").await.unwrap();
            eprintln!("socket: {}", String::from_utf8_lossy(&socket.0).trim());
            let plan = preview(&host, install).await.unwrap();
            eprintln!("diff:\n{}\nbackup: {:?}", plan.diff, plan.backup);
            match apply(&host, install, &plan.fingerprint).await {
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
        for script in [put_relay(LINUX_RELAY), put_settings("20261011-0100")] {
            assert!(!script.contains(r#"trap "rm -f $t""#), "{script}");
            assert!(script.contains(r#"rm -f "$t""#), "{script}");
        }
    }
}
