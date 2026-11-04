// The local door the WhatsApp gateway knocks on with each new message (port of WhatsAppWebhook.swift):
// an HTTP listener bound to 127.0.0.1 only, never reachable from another machine, on the port set in
// Settings. Each request is handed over whole; nothing of it is logged.

use std::net::{Ipv4Addr, SocketAddr, TcpListener as StdListener};
use std::sync::Arc;
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

use super::model::{parse_request, response, HttpRequest, Parse, MAX_BODY, MAX_HEAD};

/// Called with each complete request; returns the HTTP status to answer.
pub type Handler = Arc<dyn Fn(HttpRequest) -> u16 + Send + Sync>;

/// A request that never finishes is dropped after this.
const DEADLINE: Duration = Duration::from_secs(10);

pub struct Listener {
    task: tauri::async_runtime::JoinHandle<()>,
}

impl Listener {
    /// Starts listening on 127.0.0.1:`port`; Err when the port is taken or invalid.
    pub fn start(port: u16, handler: Handler) -> Result<Listener, ()> {
        if port == 0 {
            return Err(());
        }
        let std = StdListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, port))).map_err(|_| ())?;
        std.set_nonblocking(true).map_err(|_| ())?;
        let task = tauri::async_runtime::spawn(async move {
            let Ok(listener) = tokio::net::TcpListener::from_std(std) else { return };
            loop {
                let Ok((stream, peer)) = listener.accept().await else {
                    tokio::time::sleep(Duration::from_millis(200)).await;
                    continue;
                };
                // Only the loopback: the listener is bound to it, this is a second lock.
                if !peer.ip().is_loopback() {
                    continue;
                }
                let handler = handler.clone();
                tauri::async_runtime::spawn(async move {
                    let _ = tokio::time::timeout(DEADLINE, serve(stream, handler)).await;
                });
            }
        });
        Ok(Listener { task })
    }

    pub fn stop(self) {
        self.task.abort();
    }
}

async fn serve(mut stream: TcpStream, handler: Handler) {
    let mut buffer = Vec::new();
    let mut chunk = [0u8; 65_536];
    let answer = loop {
        let n = match stream.read(&mut chunk).await {
            Ok(n) => n,
            Err(_) => return,
        };
        buffer.extend_from_slice(&chunk[..n]);
        match parse_request(&buffer, MAX_BODY) {
            Parse::Incomplete if n > 0 && buffer.len() <= MAX_HEAD + MAX_BODY => continue,
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
            _ => break response(400, "Bad Request"),
        }
    };
    let _ = stream.write_all(&answer).await;
    let _ = stream.shutdown().await;
}
