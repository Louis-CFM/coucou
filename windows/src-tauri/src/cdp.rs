// A minimal Chrome DevTools Protocol client for the robot's hidden browser on
// 127.0.0.1:9222: plain HTTP for /json/version and /json/list, and a bare
// WebSocket (RFC 6455, client side only) for one command at a time.
//
// It only ever talks to that local address. It reads (is the browser up,
// screenshot of the active page) and sets where downloads go; it never
// clicks, types or navigates.

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::time::Duration;

use serde_json::{json, Value};

pub const HOST: &str = "127.0.0.1:9222";
const MAX_FRAME: u64 = 32 * 1024 * 1024;
const MAX_HTTP: usize = 4 * 1024 * 1024;

fn connect(timeout: Duration) -> Result<TcpStream, String> {
    let addr: SocketAddr = HOST.parse().map_err(|e| format!("{e}"))?;
    let s = TcpStream::connect_timeout(&addr, timeout).map_err(|e| format!("The hidden browser is not reachable: {e}"))?;
    let _ = s.set_read_timeout(Some(timeout));
    let _ = s.set_write_timeout(Some(timeout));
    let _ = s.set_nodelay(true);
    Ok(s)
}

fn header_end(buf: &[u8]) -> Option<usize> {
    buf.windows(4).position(|w| w == b"\r\n\r\n").map(|p| p + 4)
}

fn content_length(head: &str) -> Option<usize> {
    head.lines().find_map(|l| {
        let (k, v) = l.split_once(':')?;
        k.trim().eq_ignore_ascii_case("content-length").then(|| v.trim().parse().ok())?
    })
}

/// Body of a complete `HTTP/1.1 200` response, or why not.
pub fn parse_http_response(raw: &[u8]) -> Result<String, String> {
    let end = header_end(raw).ok_or("Incomplete HTTP response.")?;
    let head = String::from_utf8_lossy(&raw[..end]);
    let status = head.lines().next().unwrap_or("");
    if status.split_whitespace().nth(1) != Some("200") {
        return Err(format!("Browser answered: {}", status.trim()));
    }
    let mut body = &raw[end..];
    if let Some(n) = content_length(&head) {
        body = &body[..n.min(body.len())];
    }
    Ok(String::from_utf8_lossy(body).into_owned())
}

pub fn http_get(path: &str, timeout: Duration) -> Result<String, String> {
    let mut s = connect(timeout)?;
    s.write_all(format!("GET {path} HTTP/1.1\r\nHost: {HOST}\r\nConnection: close\r\n\r\n").as_bytes())
        .map_err(|e| e.to_string())?;
    let mut buf = Vec::new();
    let mut chunk = [0u8; 16 * 1024];
    loop {
        let n = match s.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) if buf.is_empty() => return Err(e.to_string()),
            Err(_) => break,
        };
        buf.extend_from_slice(&chunk[..n]);
        if buf.len() > MAX_HTTP {
            return Err("Browser response too large.".into());
        }
        if let Some(end) = header_end(&buf) {
            if let Some(len) = content_length(&String::from_utf8_lossy(&buf[..end])) {
                if buf.len() >= end + len {
                    break;
                }
            }
        }
    }
    parse_http_response(&buf)
}

/// The DevTools endpoint answers: the hidden browser is running.
pub fn alive() -> bool {
    http_get("/json/version", Duration::from_millis(1500)).is_ok_and(|b| b.contains("webSocketDebuggerUrl"))
}

/// `ws://127.0.0.1:9222/devtools/...` → `/devtools/...`. Anything not on the
/// local DevTools port is refused.
pub fn ws_path(url: &str) -> Option<String> {
    let rest = url.strip_prefix("ws://127.0.0.1:9222").or_else(|| url.strip_prefix("ws://localhost:9222"))?;
    (rest.starts_with('/') && !rest.contains(['\r', '\n', ' '])).then(|| rest.to_string())
}

/// The page the robot is most likely working in: DevTools lists the most
/// recently active target first. Internal pages are skipped.
pub fn pick_page(list_json: &str) -> Option<String> {
    let list: Value = serde_json::from_str(list_json).ok()?;
    list.as_array()?.iter().find_map(|t| {
        if t.get("type").and_then(Value::as_str) != Some("page") {
            return None;
        }
        let url = t.get("url").and_then(Value::as_str).unwrap_or("");
        if ["devtools://", "chrome://", "chrome-extension://", "chrome-untrusted://"].iter().any(|p| url.starts_with(p)) {
            return None;
        }
        t.get("webSocketDebuggerUrl").and_then(Value::as_str).map(str::to_string)
    })
}

/// One client frame: FIN set, masked, as RFC 6455 requires of clients.
pub fn encode_frame(opcode: u8, payload: &[u8], mask: [u8; 4]) -> Vec<u8> {
    let mut out = Vec::with_capacity(payload.len() + 14);
    out.push(0x80 | (opcode & 0x0f));
    let len = payload.len();
    if len < 126 {
        out.push(0x80 | len as u8);
    } else if len <= 0xffff {
        out.push(0x80 | 126);
        out.extend_from_slice(&(len as u16).to_be_bytes());
    } else {
        out.push(0x80 | 127);
        out.extend_from_slice(&(len as u64).to_be_bytes());
    }
    out.extend_from_slice(&mask);
    out.extend(payload.iter().enumerate().map(|(i, b)| b ^ mask[i % 4]));
    out
}

fn mask_key() -> [u8; 4] {
    let n = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0x5a5a_5a5a)
        ^ std::process::id().rotate_left(13);
    n.to_le_bytes()
}

/// Reads one frame: (fin, opcode, payload).
pub fn read_frame<R: Read>(r: &mut R) -> Result<(bool, u8, Vec<u8>), String> {
    let mut head = [0u8; 2];
    r.read_exact(&mut head).map_err(|e| e.to_string())?;
    let fin = head[0] & 0x80 != 0;
    let opcode = head[0] & 0x0f;
    let masked = head[1] & 0x80 != 0;
    let mut len = u64::from(head[1] & 0x7f);
    if len == 126 {
        let mut b = [0u8; 2];
        r.read_exact(&mut b).map_err(|e| e.to_string())?;
        len = u64::from(u16::from_be_bytes(b));
    } else if len == 127 {
        let mut b = [0u8; 8];
        r.read_exact(&mut b).map_err(|e| e.to_string())?;
        len = u64::from_be_bytes(b);
    }
    if len > MAX_FRAME {
        return Err("DevTools frame too large.".into());
    }
    let mut mask = [0u8; 4];
    if masked {
        r.read_exact(&mut mask).map_err(|e| e.to_string())?;
    }
    let mut payload = vec![0u8; len as usize];
    r.read_exact(&mut payload).map_err(|e| e.to_string())?;
    if masked {
        for (i, b) in payload.iter_mut().enumerate() {
            *b ^= mask[i % 4];
        }
    }
    Ok((fin, opcode, payload))
}

pub struct Ws {
    s: TcpStream,
    next_id: u64,
}

impl Ws {
    pub fn open(url: &str, timeout: Duration) -> Result<Ws, String> {
        let path = ws_path(url).ok_or("Refusing a DevTools address that is not 127.0.0.1:9222.")?;
        let mut s = connect(timeout)?;
        let req = format!(
            "GET {path} HTTP/1.1\r\nHost: {HOST}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\
             Sec-WebSocket-Key: Y291Y291LXJvYm90LWtleQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
        );
        s.write_all(req.as_bytes()).map_err(|e| e.to_string())?;
        // Byte by byte so nothing past the handshake is swallowed.
        let mut head = Vec::new();
        let mut b = [0u8; 1];
        while header_end(&head).is_none() {
            s.read_exact(&mut b).map_err(|e| format!("DevTools handshake: {e}"))?;
            head.push(b[0]);
            if head.len() > 8192 {
                return Err("DevTools handshake too long.".into());
            }
        }
        let status = String::from_utf8_lossy(&head);
        if status.lines().next().and_then(|l| l.split_whitespace().nth(1)) != Some("101") {
            return Err(format!("DevTools refused the connection: {}", status.lines().next().unwrap_or("")));
        }
        Ok(Ws { s, next_id: 1 })
    }

    fn send(&mut self, opcode: u8, payload: &[u8]) -> Result<(), String> {
        self.s.write_all(&encode_frame(opcode, payload, mask_key())).map_err(|e| e.to_string())
    }

    fn recv_text(&mut self) -> Result<String, String> {
        let mut msg = Vec::new();
        loop {
            let (fin, opcode, payload) = read_frame(&mut self.s)?;
            match opcode {
                0x0 | 0x1 | 0x2 => {
                    msg.extend_from_slice(&payload);
                    if msg.len() as u64 > MAX_FRAME {
                        return Err("DevTools message too large.".into());
                    }
                    if fin {
                        return Ok(String::from_utf8_lossy(&msg).into_owned());
                    }
                }
                0x8 => return Err("DevTools closed the connection.".into()),
                0x9 => self.send(0xA, &payload)?,
                _ => {}
            }
        }
    }

    /// Sends one command and waits for its answer, skipping events.
    pub fn call(&mut self, method: &str, params: Value) -> Result<Value, String> {
        let id = self.next_id;
        self.next_id += 1;
        let text = json!({ "id": id, "method": method, "params": params }).to_string();
        self.send(0x1, text.as_bytes())?;
        loop {
            let reply: Value = serde_json::from_str(&self.recv_text()?).map_err(|e| e.to_string())?;
            if reply.get("id").and_then(Value::as_u64) != Some(id) {
                continue;
            }
            if let Some(err) = reply.get("error") {
                return Err(format!("{method}: {}", err.get("message").and_then(Value::as_str).unwrap_or("error")));
            }
            return Ok(reply.get("result").cloned().unwrap_or(Value::Null));
        }
    }
}

fn is_base64(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'+' | b'/' | b'='))
}

/// JPEG of the hidden browser's active page as a `data:` URL, or `None` when
/// no page is open. Read-only.
pub fn screenshot() -> Result<Option<String>, String> {
    let list = http_get("/json/list", Duration::from_secs(2))?;
    let Some(url) = pick_page(&list) else { return Ok(None) };
    let mut ws = Ws::open(&url, Duration::from_secs(5))?;
    let result = ws.call("Page.captureScreenshot", json!({ "format": "jpeg", "quality": 55 }))?;
    let data = result.get("data").and_then(Value::as_str).unwrap_or("");
    if !is_base64(data) {
        return Err("The screenshot came back empty.".into());
    }
    Ok(Some(format!("data:image/jpeg;base64,{data}")))
}

/// Holds a browser-level DevTools session that sends downloads to `dir`.
/// Chrome may undo the setting when the session closes, so it is kept open
/// for the length of a robot run and dropped after.
pub struct DownloadGuard {
    _ws: Ws,
}

/// The browser-level DevTools socket (from /json/version).
fn browser_ws() -> Result<Ws, String> {
    let version: Value = serde_json::from_str(&http_get("/json/version", Duration::from_secs(2))?)
        .map_err(|e| e.to_string())?;
    let url = version
        .get("webSocketDebuggerUrl")
        .and_then(Value::as_str)
        .ok_or("No browser DevTools address.")?;
    Ws::open(url, Duration::from_secs(5))
}

/// What to do with the open tabs so exactly one about:blank page remains.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabPlan {
    /// No about:blank page exists: create one first.
    pub create_blank: bool,
    /// Page target ids to close.
    pub close: Vec<String>,
}

/// From `Target.getTargets` → `targetInfos`: keep the first about:blank page,
/// close every other page. Non-page targets (workers, extensions) are left.
pub fn plan_tabs(target_infos: &Value) -> TabPlan {
    let pages: Vec<(String, String)> = target_infos
        .as_array()
        .map(|a| a.as_slice())
        .unwrap_or(&[])
        .iter()
        .filter(|t| t.get("type").and_then(Value::as_str) == Some("page"))
        .filter_map(|t| {
            let id = t.get("targetId").and_then(Value::as_str)?.to_string();
            let url = t.get("url").and_then(Value::as_str).unwrap_or("").to_string();
            Some((id, url))
        })
        .collect();
    let keep = pages.iter().find(|(_, url)| url == "about:blank").map(|(id, _)| id.clone());
    TabPlan {
        create_blank: keep.is_none(),
        close: pages.into_iter().map(|(id, _)| id).filter(|id| Some(id) != keep.as_ref()).collect(),
    }
}

/// Closes every page of the hidden browser except one about:blank page
/// (created first if missing). Two Telegram Web tabs freeze each other, so
/// this runs before and after every robot task. Returns the number closed.
pub fn reset_tabs() -> Result<usize, String> {
    let mut ws = browser_ws()?;
    let targets = ws.call("Target.getTargets", json!({}))?;
    let plan = plan_tabs(targets.get("targetInfos").unwrap_or(&Value::Null));
    if plan.create_blank {
        ws.call("Target.createTarget", json!({ "url": "about:blank" }))?;
    }
    let mut closed = 0;
    for id in &plan.close {
        match ws.call("Target.closeTarget", json!({ "targetId": id })) {
            Ok(_) => closed += 1,
            Err(e) => crate::log::line(format!("robot could not close a tab: {e}")),
        }
    }
    // closeTarget answers before the tab is gone: wait (≤ 2 s) until only the
    // blank page is left, so the agent never sees a tab that is still closing.
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    loop {
        let now = ws.call("Target.getTargets", json!({}))?;
        let left = plan_tabs(now.get("targetInfos").unwrap_or(&Value::Null));
        if !left.create_blank && left.close.is_empty() {
            break;
        }
        if std::time::Instant::now() >= deadline {
            crate::log::line(format!("robot tabs still closing: {} left", left.close.len()));
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    Ok(closed)
}

impl DownloadGuard {
    pub fn open(dir: &std::path::Path) -> Result<DownloadGuard, String> {
        let mut ws = browser_ws()?;
        ws.call(
            "Browser.setDownloadBehavior",
            json!({ "behavior": "allow", "downloadPath": dir.to_string_lossy(), "eventsEnabled": false }),
        )?;
        let _ = ws.s.set_read_timeout(None);
        Ok(DownloadGuard { _ws: ws })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn http_responses_are_parsed() {
        let ok = b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 4\r\n\r\n{}xyz";
        assert_eq!(parse_http_response(ok).unwrap(), "{}xy");
        let no_len = b"HTTP/1.1 200 OK\r\n\r\n[1]";
        assert_eq!(parse_http_response(no_len).unwrap(), "[1]");
        assert!(parse_http_response(b"HTTP/1.1 404 Not Found\r\n\r\n").unwrap_err().contains("404"));
        assert!(parse_http_response(b"HTTP/1.1 200 OK\r\n").is_err());
    }

    #[test]
    fn only_local_devtools_addresses_are_accepted() {
        assert_eq!(ws_path("ws://127.0.0.1:9222/devtools/page/AB"), Some("/devtools/page/AB".into()));
        assert_eq!(ws_path("ws://localhost:9222/devtools/browser/x"), Some("/devtools/browser/x".into()));
        assert_eq!(ws_path("ws://10.0.0.2:9222/devtools/page/AB"), None);
        assert_eq!(ws_path("ws://127.0.0.1:92220/x"), None);
        assert_eq!(ws_path("ws://127.0.0.1:9222/a\r\nHost: evil"), None);
    }

    #[test]
    fn the_most_recent_real_page_is_picked() {
        let list = r#"[
            {"type":"service_worker","url":"https://web.telegram.org/sw.js","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/page/SW"},
            {"type":"page","url":"chrome://newtab/","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/page/NT"},
            {"type":"page","url":"https://gemini.google.com/app","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/page/GE"},
            {"type":"page","url":"https://web.telegram.org/k/","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/page/TG"}
        ]"#;
        assert_eq!(pick_page(list).as_deref(), Some("ws://127.0.0.1:9222/devtools/page/GE"));
        assert_eq!(pick_page("[]"), None);
        assert_eq!(pick_page("not json"), None);
    }

    #[test]
    fn frames_round_trip_through_encode_and_read() {
        for len in [0usize, 5, 125, 126, 300, 70_000] {
            let payload: Vec<u8> = (0..len).map(|i| (i % 251) as u8).collect();
            let frame = encode_frame(0x1, &payload, [1, 2, 3, 4]);
            let (fin, op, back) = read_frame(&mut frame.as_slice()).unwrap();
            assert!(fin);
            assert_eq!(op, 0x1);
            assert_eq!(back, payload, "len {len}");
        }
        // Server frames are unmasked.
        let server = [0x81u8, 0x02, b'h', b'i'];
        assert_eq!(read_frame(&mut server.as_slice()).unwrap(), (true, 1, b"hi".to_vec()));
    }

    /// Read-only against the real hidden browser: is it up, and does a
    /// screenshot of its active page come back.
    /// `cargo test -p coucou live_preview -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn live_preview_reads_the_hidden_browser() {
        assert!(alive(), "nothing on 127.0.0.1:9222");
        let shot = screenshot().unwrap().expect("no page open");
        println!("screenshot data URL: {} chars", shot.len());
        assert!(shot.starts_with("data:image/jpeg;base64,/9j/"));
    }

    /// CHANGES the real hidden browser: closes every page but one about:blank.
    /// `cargo test -p coucou live_reset_tabs -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn live_reset_tabs_leaves_one_blank_page() {
        let closed = reset_tabs().unwrap();
        let list: Value = serde_json::from_str(&http_get("/json/list", Duration::from_secs(2)).unwrap()).unwrap();
        let pages: Vec<&Value> = list.as_array().unwrap().iter().filter(|t| t["type"] == "page").collect();
        println!("closed {closed}, pages now: {}", pages.len());
        assert_eq!(pages.len(), 1);
        assert_eq!(pages[0]["url"], "about:blank");
    }

    #[test]
    fn tab_plan_keeps_one_blank_page() {
        let infos = json!([
            { "targetId": "TG1", "type": "page", "url": "https://web.telegram.org/k/" },
            { "targetId": "SW", "type": "service_worker", "url": "https://web.telegram.org/sw.js" },
            { "targetId": "B1", "type": "page", "url": "about:blank" },
            { "targetId": "TG2", "type": "page", "url": "https://web.telegram.org/k/" },
            { "targetId": "B2", "type": "page", "url": "about:blank" },
            { "type": "page", "url": "https://no-id" }
        ]);
        assert_eq!(plan_tabs(&infos), TabPlan { create_blank: false, close: vec!["TG1".into(), "TG2".into(), "B2".into()] });

        let no_blank = json!([{ "targetId": "G", "type": "page", "url": "https://gemini.google.com/app" }]);
        assert_eq!(plan_tabs(&no_blank), TabPlan { create_blank: true, close: vec!["G".into()] });

        let only_blank = json!([{ "targetId": "B", "type": "page", "url": "about:blank" }]);
        assert_eq!(plan_tabs(&only_blank), TabPlan { create_blank: false, close: vec![] });
        assert_eq!(plan_tabs(&Value::Null), TabPlan { create_blank: true, close: vec![] });
    }

    #[test]
    fn base64_check_rejects_junk() {
        assert!(is_base64("/9j/4AAQSkZJRg=="));
        assert!(!is_base64(""));
        assert!(!is_base64("abc\"><script>"));
    }
}
