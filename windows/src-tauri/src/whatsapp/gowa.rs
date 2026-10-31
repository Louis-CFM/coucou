// GOWA on this computer — port of WhatsAppGOWAInstaller.swift and
// WhatsAppGOWAProcess.swift, plus the webhook listener (WhatsAppWebhook.swift).
//
// "Install WhatsApp" downloads GOWA's own latest Windows build from its GitHub
// releases, checks its SHA-256 against the checksums GOWA publishes, and puts
// the program in Coucou's GOWA folder, next to the WhatsApp session it keeps.
// Coucou then starts it on 127.0.0.1 only, without downloading media, and
// stops it when Coucou quits. The only network call is to GitHub, once, after
// the click; no message ever goes there.

use std::io::{Read, Write};
use std::net::{Ipv4Addr, SocketAddrV4, TcpListener, TcpStream};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::gateway::{gowa, release};
use super::models::{parse_request, response, HttpRequest, Parse};

/// Where GOWA lives with its WhatsApp session (its database, not Coucou's).
pub fn folder() -> PathBuf {
    crate::platform::local_dir().join("GOWA")
}

pub fn binary() -> PathBuf {
    folder().join("gowa.exe")
}

fn arch() -> &'static str {
    if cfg!(target_arch = "x86") { "386" } else { "amd64" }
}

// ── Install ───────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, serde::Serialize)]
#[serde(tag = "step", rename_all = "camelCase")]
pub enum Step {
    Idle,
    Checking,
    Downloading { megabytes: u64 },
    Verifying,
    Installing,
    Done { version: String },
    Failed { message: String },
}

/// Downloads, checks and unpacks GOWA; `progress` hears each step. Returns the version.
pub async fn install(progress: impl Fn(Step)) -> Result<String, String> {
    use crate::i18n::t;
    // Only GitHub serves the files (its assets redirect to githubusercontent.com).
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::custom(|attempt| {
            if attempt.previous().len() < 5 && release::allowed_host(attempt.url().host_str()) {
                attempt.follow()
            } else {
                attempt.stop()
            }
        }))
        .user_agent("Coucou")
        .timeout(Duration::from_secs(600))
        .build()
        .map_err(|e| e.to_string())?;
    let failed = || t("The download didn't go through. Check your connection and try again.");

    // 1. Which build: GOWA's latest release, the zip for this computer.
    progress(Step::Checking);
    let meta = client
        .get(release::LATEST)
        .header("Accept", "application/vnd.github+json")
        .send()
        .await
        .map_err(|_| failed())?;
    if !meta.status().is_success() {
        return Err(failed());
    }
    let meta = meta.bytes().await.map_err(|_| failed())?;
    let no_build = || t("No GOWA build for this computer was found on GitHub. Try again later, or set your own gateway under Advanced.");
    let (version, assets) = release::parse(&meta).ok_or_else(no_build)?;
    let (zip, sums) = release::pick(&assets, arch()).ok_or_else(no_build)?;
    let checksums = match sums {
        Some(s) => client.get(&s.url).send().await.ok().and_then(|r| r.status().is_success().then_some(r)),
        None => None,
    };
    let checksums = match checksums {
        Some(r) => r.text().await.ok(),
        None => None,
    };
    let expected = release::expected_sha256(&zip, checksums.as_deref())
        .ok_or_else(|| t("GOWA's release has no checksum to check the download against: nothing was installed."))?;

    // 2. Download.
    progress(Step::Downloading { megabytes: (zip.size / 1_000_000).max(1) });
    let response = client.get(&zip.url).send().await.map_err(|_| failed())?;
    if !response.status().is_success() {
        return Err(failed());
    }
    let bytes = response.bytes().await.map_err(|_| failed())?;

    // 3. Verify: exactly the file GOWA published.
    progress(Step::Verifying);
    let digest = super::models::hex(ring::digest::digest(&ring::digest::SHA256, &bytes).as_ref());
    if digest != expected {
        return Err(t("The download doesn't match the file GOWA published: it was deleted, nothing was installed."));
    }

    // 4. Unzip the program into place (an older one gives way first).
    progress(Step::Installing);
    stop();
    let program = unpack(&bytes).ok_or_else(|| t("The download couldn't be unzipped. Try again."))?;
    std::fs::create_dir_all(folder()).map_err(|e| e.to_string())?;
    let target = binary();
    let fresh = target.with_extension("new");
    std::fs::write(&fresh, &program).map_err(|e| e.to_string())?;
    let _ = std::fs::remove_file(&target);
    std::fs::rename(&fresh, &target).map_err(|e| e.to_string())?;
    crate::log::line(format!("whatsapp: GOWA {version} installed ({})", arch()));
    progress(Step::Done { version: version.clone() });
    Ok(version)
}

/// The one .exe in GOWA's zip.
fn unpack(zip: &[u8]) -> Option<Vec<u8>> {
    let mut archive = zip::ZipArchive::new(std::io::Cursor::new(zip)).ok()?;
    for i in 0..archive.len() {
        let mut file = archive.by_index(i).ok()?;
        if file.is_file() && file.name().to_lowercase().ends_with(".exe") {
            let mut out = Vec::with_capacity(file.size() as usize);
            file.read_to_end(&mut out).ok()?;
            return Some(out);
        }
    }
    None
}

// ── Running it ────────────────────────────────────────────────────────────────

struct Running {
    child: Child,
    /// What it was started with: changed, it is restarted; same, left alone.
    signature: String,
}

static PROCESS: Mutex<Option<Running>> = Mutex::new(None);
static LAST_START: Mutex<Option<Instant>> = Mutex::new(None);

pub fn is_running() -> bool {
    let mut guard = PROCESS.lock().unwrap();
    match guard.as_mut() {
        Some(r) => matches!(r.child.try_wait(), Ok(None)),
        None => false,
    }
}

/// Brings GOWA in line with the settings: started on `port` (this computer only)
/// with `credential`, restarted only when those changed, started again at most
/// once a minute when it keeps dying. False when it can't run.
pub fn sync(port: u16, credential: &str) -> bool {
    let program = binary();
    if !program.is_file() {
        crate::log::line("whatsapp: GOWA is not installed".to_string());
        return false;
    }
    let signature = format!("{}\u{1f}{port}\u{1f}{credential}", program.display());
    {
        let mut guard = PROCESS.lock().unwrap();
        if let Some(r) = guard.as_mut() {
            let alive = matches!(r.child.try_wait(), Ok(None));
            if alive && r.signature == signature {
                return true;
            }
            if !alive && r.signature == signature && LAST_START.lock().unwrap().is_some_and(|t| t.elapsed() < Duration::from_secs(60)) {
                return true;
            }
        }
    }
    stop();
    let _ = std::fs::create_dir_all(folder());
    let mut cmd = Command::new(&program);
    cmd.args(gowa::launch_arguments(port))
        .current_dir(folder())
        // GOWA's own web dashboard is not needed (Coucou is the interface).
        .env("APP_UI_ENABLED", "false")
        // Its output may name contacts or quote messages: it goes nowhere.
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    // The credential goes through the environment, not the command line.
    if credential.contains(':') {
        cmd.env("APP_BASIC_AUTH", credential);
    }
    crate::platform::no_console(&mut cmd);
    match cmd.spawn() {
        Ok(child) => {
            crate::log::line(format!("whatsapp: GOWA started (pid {})", child.id()));
            *PROCESS.lock().unwrap() = Some(Running { child, signature });
            *LAST_START.lock().unwrap() = Some(Instant::now());
            true
        }
        Err(err) => {
            crate::log::line(format!("whatsapp: GOWA could not start: {err}"));
            false
        }
    }
}

/// Stops GOWA if Coucou started it (Coucou quits, or before starting it again
/// so two never share its database).
pub fn stop() {
    if let Some(mut r) = PROCESS.lock().unwrap().take() {
        let _ = r.child.kill();
        let _ = r.child.wait();
        crate::log::line("whatsapp: GOWA stopped".to_string());
    }
}

// ── The webhook listener ──────────────────────────────────────────────────────

/// The local door GOWA knocks on with each new message: HTTP on 127.0.0.1 only
/// (never reachable from another machine). Each request is handed over whole;
/// nothing of it is logged.
pub struct Listener {
    stop: Arc<AtomicBool>,
}

impl Listener {
    /// Listens on `port`; `on_request` returns the HTTP status to answer. Err
    /// when the port is taken.
    pub fn start(port: u16, on_request: impl Fn(HttpRequest) -> u16 + Send + Sync + 'static) -> std::io::Result<Listener> {
        let socket = TcpListener::bind(SocketAddrV4::new(Ipv4Addr::LOCALHOST, port))?;
        socket.set_nonblocking(true)?;
        let stop = Arc::new(AtomicBool::new(false));
        let flag = stop.clone();
        let handler = Arc::new(on_request);
        std::thread::Builder::new().name("coucou-whatsapp-webhook".into()).spawn(move || {
            while !flag.load(Ordering::Relaxed) {
                match socket.accept() {
                    Ok((stream, peer)) => {
                        // Only the loopback: the socket is bound to it, this is a second lock.
                        if !peer.ip().is_loopback() {
                            continue;
                        }
                        let handler = handler.clone();
                        std::thread::spawn(move || serve(stream, &*handler));
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => std::thread::sleep(Duration::from_millis(100)),
                    Err(_) => std::thread::sleep(Duration::from_millis(250)),
                }
            }
        })?;
        Ok(Listener { stop })
    }
}

impl Drop for Listener {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

fn serve(mut stream: TcpStream, handler: &(dyn Fn(HttpRequest) -> u16 + Send + Sync)) {
    let _ = stream.set_nonblocking(false);
    // A request that never finishes is dropped.
    let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
    let mut buffer = Vec::new();
    let mut chunk = [0u8; 65_536];
    let answer = loop {
        match stream.read(&mut chunk) {
            Ok(0) => break response(400, "Bad Request"),
            Ok(n) => {
                buffer.extend_from_slice(&chunk[..n]);
                match parse_request(&buffer, 1_000_000) {
                    Parse::Incomplete => continue,
                    Parse::Invalid => break response(400, "Bad Request"),
                    Parse::Done(request) => {
                        let status = handler(request);
                        let reason = match status {
                            200 => "OK",
                            401 => "Unauthorized",
                            404 => "Not Found",
                            _ => "Error",
                        };
                        break response(status, reason);
                    }
                }
            }
            Err(_) => return,
        }
    };
    let _ = stream.write_all(&answer);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_listener_answers_a_signed_post_on_the_loopback() {
        // A free port, then the listener on it.
        let port = TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
        let got = Arc::new(Mutex::new(Vec::new()));
        let seen = got.clone();
        let _l = Listener::start(port, move |r| {
            seen.lock().unwrap().push((r.method.clone(), r.path.clone(), r.body.clone()));
            if r.path == "/whatsapp" { 200 } else { 404 }
        })
        .unwrap();
        let send = |path: &str| {
            let mut s = TcpStream::connect(("127.0.0.1", port)).unwrap();
            write!(s, "POST {path} HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\nhi").unwrap();
            let mut out = String::new();
            s.read_to_string(&mut out).unwrap();
            out
        };
        assert!(send("/whatsapp").starts_with("HTTP/1.1 200 OK"));
        assert!(send("/other").starts_with("HTTP/1.1 404"));
        assert_eq!(got.lock().unwrap()[0], ("POST".to_string(), "/whatsapp".to_string(), b"hi".to_vec()));
        // The port is now taken.
        assert!(Listener::start(port, |_| 200).is_err());
    }

    #[test]
    fn the_program_is_found_in_gowas_zip() {
        let mut buf = std::io::Cursor::new(Vec::new());
        {
            let mut w = zip::ZipWriter::new(&mut buf);
            let opts = zip::write::SimpleFileOptions::default();
            w.start_file("README.md", opts).unwrap();
            w.write_all(b"readme").unwrap();
            w.start_file("windows-amd64.exe", opts).unwrap();
            w.write_all(b"MZ program").unwrap();
            w.finish().unwrap();
        }
        assert_eq!(unpack(buf.get_ref()), Some(b"MZ program".to_vec()));
        assert_eq!(unpack(b"not a zip"), None);
    }
}
