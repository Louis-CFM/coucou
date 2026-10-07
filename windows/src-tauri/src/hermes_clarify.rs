//! Answers a Hermes `clarify` question from the island.
//!
//! The `coucou-clarify` Hermes plugin (resources/hermes-plugin) starts a
//! loopback HTTP server inside each Hermes process that asks one, and writes
//! `{port, token, pid}` to `%LOCALAPPDATA%\Coucou\hermes-clarify\<pid>.json`.
//! Coucou reads those files, skips any whose process is gone or is not Hermes'
//! Python, and talks to the server on 127.0.0.1 with the bearer token. The
//! question still shows in Telegram / Hermes Desktop; the first answer wins.

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::{Deserialize, Serialize};

const TIMEOUT: Duration = Duration::from_millis(1500);
const MAX_FILES: usize = 32;
const MAX_FILE_BYTES: u64 = 4096;
const MAX_BODY_BYTES: usize = 256 * 1024;

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Endpoint {
    pub port: u16,
    pub token: String,
    pub pid: u32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Question {
    pub qid: String,
    pub question: String,
    pub choices: Vec<String>,
    #[serde(alias = "multi_select")]
    pub multi_select: bool,
}

/// One open question set: a gateway (Telegram) entry asks one question, a
/// desktop request may ask several.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Pending {
    pub kind: String,
    pub id: String,
    pub questions: Vec<Question>,
    /// "session" when the session matched; "only" when it is the single open
    /// question of a process and the caller must check its text.
    pub matched: String,
    #[serde(default)]
    pub pid: u32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Answered {
    pub ok: bool,
    #[serde(default)]
    pub reason: String,
}

/// What `pending` found: how many Hermes processes run the plugin, and the
/// question sets open for the session. `hermes == 0` means nothing can be
/// answered from Coucou (plugin not installed, or Hermes not restarted).
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct PendingReport {
    pub hermes: usize,
    pub entries: Vec<Pending>,
}

#[derive(Deserialize)]
struct PendingReply {
    #[serde(default)]
    entries: Vec<Pending>,
}

pub fn discovery_dir(local_app_data: &Path) -> PathBuf {
    local_app_data.join("Coucou").join("hermes-clarify")
}

/// The endpoint a discovery file describes, when it is well-formed and named
/// after its own pid.
pub fn parse_endpoint(file_name: &str, text: &str) -> Option<Endpoint> {
    let endpoint: Endpoint = serde_json::from_str(text).ok()?;
    let stem = file_name.strip_suffix(".json")?;
    let token_ok = (16..=256).contains(&endpoint.token.len())
        && endpoint.token.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
    (stem == endpoint.pid.to_string() && endpoint.port != 0 && endpoint.pid != 0 && token_ok)
        .then_some(endpoint)
}

/// Every live endpoint in `dir`; `live(pid)` decides whether the process that
/// wrote a file is still a Hermes process.
pub fn endpoints(dir: &Path, live: impl Fn(u32) -> bool) -> Vec<Endpoint> {
    let Ok(read) = std::fs::read_dir(dir) else { return Vec::new() };
    let mut out = Vec::new();
    for entry in read.flatten().take(MAX_FILES * 4) {
        let name = entry.file_name().to_string_lossy().to_string();
        if !name.ends_with(".json") || entry.metadata().map_or(true, |m| !m.is_file() || m.len() > MAX_FILE_BYTES) {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(entry.path()) else { continue };
        if let Some(endpoint) = parse_endpoint(&name, &text) {
            if live(endpoint.pid) {
                out.push(endpoint);
            }
        }
        if out.len() >= MAX_FILES {
            break;
        }
    }
    out.sort_by_key(|e| e.pid);
    out
}

/// The process is running and its image is Python or Hermes (the plugin runs
/// inside Hermes' Python, or a frozen `hermes.exe`).
pub fn is_hermes_process(pid: u32) -> bool {
    crate::tab::image_path(pid).is_some_and(|path| is_hermes_image(&path))
}

fn is_hermes_image(path: &str) -> bool {
    let name = path.rsplit(['\\', '/']).next().unwrap_or_default().to_ascii_lowercase();
    name.ends_with(".exe") && (name.starts_with("python") || name.starts_with("hermes"))
}

/// Entries matched by session win; a process's lone "only" entry is used when
/// nothing matched anywhere and it is the only one.
pub fn merge(found: Vec<Vec<Pending>>) -> Vec<Pending> {
    let all: Vec<Pending> = found.into_iter().flatten().collect();
    let matched: Vec<Pending> = all.iter().filter(|e| e.matched == "session").cloned().collect();
    if !matched.is_empty() {
        return matched;
    }
    let only: Vec<Pending> = all.into_iter().filter(|e| e.matched == "only").collect();
    if only.len() == 1 { only } else { Vec::new() }
}

fn valid(entry: &Pending) -> bool {
    matches!(entry.kind.as_str(), "gateway" | "desktop")
        && !entry.id.is_empty()
        && entry.id.len() <= 64
        && !entry.questions.is_empty()
        && entry.questions.len() <= 8
        && entry.questions.iter().all(|q| !q.choices.is_empty() && q.choices.len() <= 16)
}

fn client() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .no_proxy()
        .timeout(TIMEOUT)
        .connect_timeout(TIMEOUT)
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|e| e.to_string())
}

async fn body(response: reqwest::Response) -> Option<Vec<u8>> {
    if response.content_length().is_some_and(|n| n as usize > MAX_BODY_BYTES) {
        return None;
    }
    let bytes = response.bytes().await.ok()?;
    (bytes.len() <= MAX_BODY_BYTES).then(|| bytes.to_vec())
}

async fn pending_at(client: &reqwest::Client, endpoint: &Endpoint, session_id: &str) -> Vec<Pending> {
    let Ok(mut url) = reqwest::Url::parse(&format!("http://127.0.0.1:{}/pending", endpoint.port)) else {
        return Vec::new();
    };
    url.query_pairs_mut().append_pair("session", session_id);
    let Ok(response) = client.get(url).bearer_auth(&endpoint.token).send().await else { return Vec::new() };
    if !response.status().is_success() {
        return Vec::new();
    }
    let Some(bytes) = body(response).await else { return Vec::new() };
    let Ok(reply) = serde_json::from_slice::<PendingReply>(&bytes) else { return Vec::new() };
    reply
        .entries
        .into_iter()
        .filter(valid)
        .map(|mut e| {
            e.pid = endpoint.pid;
            e
        })
        .collect()
}

pub async fn pending_in(dir: &Path, session_id: &str, live: impl Fn(u32) -> bool) -> Result<PendingReport, String> {
    let client = client()?;
    let endpoints = endpoints(dir, live);
    let mut found = Vec::new();
    for endpoint in &endpoints {
        found.push(pending_at(&client, endpoint, session_id).await);
    }
    Ok(PendingReport { hermes: endpoints.len(), entries: merge(found) })
}

pub async fn answer_in(
    dir: &Path,
    pid: u32,
    kind: &str,
    id: &str,
    answers: &[Vec<String>],
    live: impl Fn(u32) -> bool,
) -> Result<Answered, String> {
    if !matches!(kind, "gateway" | "desktop") || id.is_empty() || answers.is_empty() {
        return Err("Invalid Hermes answer".into());
    }
    let Some(endpoint) = endpoints(dir, live).into_iter().find(|e| e.pid == pid) else {
        return Ok(Answered { ok: false, reason: "expired".into() });
    };
    let response = client()?
        .post(format!("http://127.0.0.1:{}/answer", endpoint.port))
        .bearer_auth(&endpoint.token)
        .json(&serde_json::json!({ "kind": kind, "id": id, "answers": answers }))
        .send()
        .await
        .map_err(|_| "Hermes did not answer".to_string())?;
    let bytes = body(response).await.ok_or("Hermes sent an unreadable reply")?;
    serde_json::from_slice(&bytes).map_err(|_| "Hermes sent an unreadable reply".into())
}

fn default_dir() -> PathBuf {
    discovery_dir(&crate::agent_hooks::Profile::from_env().local_app_data)
}

pub async fn pending(session_id: &str) -> Result<PendingReport, String> {
    pending_in(&default_dir(), session_id, is_hermes_process).await
}

pub async fn answer(pid: u32, kind: &str, id: &str, answers: &[Vec<String>]) -> Result<Answered, String> {
    answer_in(&default_dir(), pid, kind, id, answers, is_hermes_process).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader, Read, Write};
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT: AtomicU64 = AtomicU64::new(0);
    const TOKEN: &str = "abcdefghijklmnopqrstuvwxyz012345";

    struct Dir(PathBuf);
    impl Dir {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "coucou-hermes-clarify-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::create_dir_all(&path).unwrap();
            Self(path)
        }
        fn write(&self, name: &str, text: &str) {
            std::fs::write(self.0.join(name), text).unwrap();
        }
    }
    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn file(port: u16, pid: u32) -> String {
        format!(r#"{{"port": {port}, "token": "{TOKEN}", "pid": {pid}, "version": 1}}"#)
    }

    #[test]
    fn discovery_files_must_be_well_formed_and_named_after_their_pid() {
        assert_eq!(
            parse_endpoint("42.json", &file(5000, 42)),
            Some(Endpoint { port: 5000, token: TOKEN.into(), pid: 42 })
        );
        assert_eq!(parse_endpoint("43.json", &file(5000, 42)), None, "renamed file");
        assert_eq!(parse_endpoint("42.json.tmp", &file(5000, 42)), None);
        assert_eq!(parse_endpoint("42.json", &file(0, 42)), None, "no port");
        assert_eq!(parse_endpoint("42.json", r#"{"port":1,"token":"short","pid":42}"#), None);
        assert_eq!(parse_endpoint("42.json", r#"{"port":1,"token":"has spaces in the token value!!","pid":42}"#), None);
        assert_eq!(parse_endpoint("42.json", "not json"), None);
    }

    #[test]
    fn stale_and_foreign_files_are_skipped() {
        let d = Dir::new();
        d.write("10.json", &file(5010, 10));
        d.write("11.json", &file(5011, 11));
        d.write("12.json", &file(5012, 99));
        d.write("13.json.tmp", &file(5013, 13));
        d.write("notes.txt", "x");
        let live = endpoints(&d.0, |pid| pid == 11 || pid == 99);
        assert_eq!(live.iter().map(|e| e.pid).collect::<Vec<_>>(), vec![11]);
        assert!(endpoints(&d.0.join("missing"), |_| true).is_empty());
    }

    #[test]
    fn only_python_or_hermes_images_count_as_hermes() {
        assert!(is_hermes_image(r"C:\Users\x\AppData\Local\hermes\tools\python-3.14\python.exe"));
        assert!(is_hermes_image(r"C:\x\venv\Scripts\pythonw.exe"));
        assert!(is_hermes_image(r"C:\x\hermes.exe"));
        assert!(!is_hermes_image(r"C:\Windows\notepad.exe"));
        assert!(!is_hermes_image(r"C:\x\python"));
        assert!(!is_hermes_image(&std::env::current_exe().unwrap().to_string_lossy()));
        assert!(!is_hermes_process(std::process::id()), "this test binary is not Hermes");
    }

    fn entry(id: &str, matched: &str) -> Pending {
        Pending {
            kind: "gateway".into(),
            id: id.into(),
            questions: vec![Question { qid: "q0".into(), question: "Q?".into(), choices: vec!["a".into()], multi_select: false }],
            matched: matched.into(),
            pid: 1,
        }
    }

    #[test]
    fn session_matches_win_and_a_lone_guess_needs_to_be_unique() {
        assert_eq!(merge(vec![vec![entry("a", "only")], vec![entry("b", "session")]]), vec![entry("b", "session")]);
        assert_eq!(merge(vec![vec![entry("a", "only")], vec![]]), vec![entry("a", "only")]);
        assert!(merge(vec![vec![entry("a", "only")], vec![entry("b", "only")]]).is_empty());
        assert!(merge(vec![vec![entry("a", "weird")]]).is_empty());
    }

    /// A one-request HTTP server on 127.0.0.1 standing in for the plugin;
    /// returns the request it received.
    fn serve_once(reply: &'static str) -> (u16, std::thread::JoinHandle<String>) {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let handle = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut head = String::new();
            let mut length = 0;
            loop {
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                if let Some(v) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                    length = v.trim().parse().unwrap();
                }
                head.push_str(&line);
                if line == "\r\n" {
                    break;
                }
            }
            let mut body = vec![0; length];
            reader.read_exact(&mut body).unwrap();
            let mut stream = stream;
            write!(stream, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{reply}", reply.len()).unwrap();
            head + &String::from_utf8(body).unwrap()
        });
        (port, handle)
    }

    fn block_on<F: std::future::Future>(future: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(future)
    }

    #[test]
    fn pending_asks_each_live_hermes_with_its_token_and_the_session() {
        let d = Dir::new();
        let (port, server) = serve_once(
            r#"{"ok":true,"entries":[{"kind":"gateway","id":"c1","matched":"session","questions":[{"qid":"q0","question":"Where?","choices":["Staging","Prod"],"multi_select":false}]},{"kind":"bogus","id":"x","matched":"session","questions":[]}]}"#,
        );
        d.write("777.json", &file(port, 777));
        let report = block_on(pending_in(&d.0, "agent:main:telegram:dm 1", |pid| pid == 777)).unwrap();
        assert_eq!(report.hermes, 1);
        let found = report.entries;
        let request = server.join().unwrap();
        assert!(request.starts_with("GET /pending?session=agent%3Amain%3Atelegram%3Adm+1 HTTP/1.1\r\n"), "{request}");
        assert!(request.to_ascii_lowercase().contains(&format!("authorization: bearer {TOKEN}")), "{request}");
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].pid, 777);
        assert_eq!(found[0].questions[0].choices, vec!["Staging", "Prod"]);
        let wire = serde_json::to_value(&found[0]).unwrap();
        assert_eq!(wire["questions"][0]["multiSelect"], false);
    }

    #[test]
    fn answer_posts_the_picks_to_the_owning_process_only() {
        let d = Dir::new();
        let (port, server) = serve_once(r#"{"ok":false,"reason":"expired"}"#);
        d.write("778.json", &file(port, 778));
        let answers = vec![vec!["Staging".to_string()]];
        let gone = block_on(answer_in(&d.0, 779, "gateway", "c1", &answers, |_| true)).unwrap();
        assert_eq!(gone, Answered { ok: false, reason: "expired".into() });
        let reply = block_on(answer_in(&d.0, 778, "gateway", "c1", &answers, |_| true)).unwrap();
        assert_eq!(reply, Answered { ok: false, reason: "expired".into() });
        let request = server.join().unwrap();
        assert!(request.starts_with("POST /answer HTTP/1.1\r\n"), "{request}");
        assert!(request.ends_with(r#"{"answers":[["Staging"]],"id":"c1","kind":"gateway"}"#)
            || request.ends_with(r#"{"kind":"gateway","id":"c1","answers":[["Staging"]]}"#), "{request}");
        assert!(block_on(answer_in(&d.0, 778, "other", "c1", &answers, |_| true)).is_err());
        assert!(block_on(answer_in(&d.0, 778, "gateway", "c1", &[], |_| true)).is_err());
    }

    #[test]
    fn unreachable_hermes_reports_nothing_pending() {
        let d = Dir::new();
        let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
        d.write("780.json", &file(port, 780));
        assert_eq!(block_on(pending_in(&d.0, "s", |_| true)).unwrap(), PendingReport { hermes: 1, entries: vec![] });
        assert_eq!(block_on(pending_in(&d.0, "s", |_| false)).unwrap(), PendingReport { hermes: 0, entries: vec![] });
    }
}
