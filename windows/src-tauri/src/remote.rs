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

/// Called by the pipe for every event from a remote host.
pub fn note_session(payload: &Value, event: &str) {
    let Some(id) = payload.get("session_id").and_then(Value::as_str) else { return };
    let mut set = REMOTE_SESSIONS.lock().unwrap();
    let set = set.get_or_insert_with(HashSet::new);
    if event == "SessionEnd" {
        set.remove(id);
    } else {
        set.insert(id.to_string());
    }
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

/// The host as a file name for its local socket.
fn socket_name(host: &str) -> String {
    let safe: String = host.chars().map(|c| if c.is_ascii_alphanumeric() || "._-".contains(c) { c } else { '_' }).collect();
    format!("{safe}.sock")
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
const PUT_RELAY: &str = r#"set -e; d=$HOME/.local/share/coucou/bin; mkdir -p "$d"; t=$d/coucou-hook.new; trap "rm -f $t" EXIT
cat > "$t"; chmod 755 "$t"; e=$("$t" < /dev/null 2>&1 > /dev/null) || true; if [ -n "$e" ]; then echo "$e" >&2; exit 1; fi
mv -f "$t" "$d/coucou-hook""#;

/// Takes the new settings.json on stdin; backs up the old one first (printing
/// where) and writes through a symlink, keeping the file's mode.
fn put_settings(stamp: &str) -> String {
    format!(
        r#"set -e; f=$HOME/.claude/settings.json; if [ -L "$f" ]; then f=$(readlink -f "$f"); fi; mkdir -p "$(dirname "$f")"
t=$f.coucou-new; trap "rm -f $t" EXIT
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

/// Holds `ssh -R` open until it ends; returns why it ended.
#[cfg(target_os = "linux")]
async fn forward(app: &AppHandle, host: &str, remote: &str, local: &std::path::Path, settled: std::time::Duration) -> String {
    use tokio::io::AsyncReadExt;
    let child = tokio::process::Command::new("ssh")
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
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true)
        .spawn();
    let mut child = match child {
        Ok(c) => c,
        Err(e) => return format!("ssh: {e}"),
    };
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

    #[test]
    fn socket_names_stay_plain() {
        assert_eq!(socket_name("me@[::1]:22"), "me____1__22.sock");
        assert_eq!(socket_name("devbox"), "devbox.sock");
    }
}
