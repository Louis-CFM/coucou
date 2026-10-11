// The real phone link server, run for the Android app's tests.
//
// Not a test of its own: it is `#[ignore]`d, and android/.../RustDesktopInteropTest.kt
// starts it (`cargo test ... -- --ignored --nocapture interop_server`) to try the
// Kotlin client against this implementation. It prints one JSON line (the port,
// the certificate fingerprint, the pairing link), then obeys one command per line
// on stdin and reports what the desktop would do on stdout:
//
//   sessions                 publish two sample sessions
//   approval <id> <command>  a permission request starts waiting
//   clear                    the request was answered at the desk
//   repair <token>           pair again with a new token (phones are kicked)
//   chat on|off              the (fake) chat switch; phones learn of it when they connect
//   details on|off           the "session details" switch, same
//   quit
//
//   DECISION allow|deny <id> printed when a phone's decision is applied

use std::io::BufRead;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use super::chat::{BoxFuture, ChatBackend, ChatConfig, ChatFail, ChatLink, ModelOption};
use super::hub::{ApprovalIn, DiffIn, FileIn, Host, Hub, PlanIn, ServiceIn, ServiceItemIn, SessionIn, UsageIn, WindowIn};
use super::server::Features;
use super::pairing::{self, tests::MemStore};
use super::server;

struct Printing;
impl Host for Printing {
    fn get_diff(&self, sub_id: u64, pill_id: &str, file_id: u64) {
        // The Kotlin test hears this and answers with the command `diff <conn> <file>`.
        println!("GETDIFF {sub_id} {pill_id} {file_id}");
    }

    fn decide(&self, request_id: &str, allow: bool) {
        println!("DECISION {} {request_id}", if allow { "allow" } else { "deny" });
    }
}

struct Switches {
    details: AtomicBool,
    diffs: AtomicBool,
    usage: AtomicBool,
    services: std::sync::Mutex<Vec<String>>,
}
impl Features for Switches {
    fn details(&self) -> bool {
        self.details.load(Ordering::SeqCst)
    }
    fn diffs(&self) -> bool {
        self.diffs.load(Ordering::SeqCst)
    }
    fn usage(&self) -> bool {
        self.usage.load(Ordering::SeqCst)
    }
    fn services(&self) -> Vec<String> {
        self.services.lock().unwrap().clone()
    }
}

/// A stand-in provider for the Kotlin client to talk to: no key, no network, no cost.
/// `/error` fails like a provider error, `/auth` like a refused key, `/slow` never ends.
struct FakeChat {
    on: AtomicBool,
}

impl ChatBackend for FakeChat {
    fn config(&self) -> ChatConfig {
        ChatConfig {
            enabled: self.on.load(Ordering::SeqCst),
            allowed: vec![
                ModelOption { id: "anthropic/fake-claude".into(), provider: "anthropic".into(), label: "Anthropic · fake-claude".into() },
                ModelOption { id: "openai/fake-gpt".into(), provider: "openai".into(), label: "OpenAI · fake-gpt".into() },
            ],
        }
    }

    fn send(&self, model_id: &str, text: String, deltas: tokio::sync::mpsc::UnboundedSender<String>) -> BoxFuture<Result<String, ChatFail>> {
        let model = model_id.to_string();
        Box::pin(async move {
            if text.starts_with("/error") {
                return Err(ChatFail::Provider);
            }
            if text.starts_with("/auth") {
                return Err(ChatFail::Auth);
            }
            if text.starts_with("/slow") {
                let mut so_far = String::new();
                loop {
                    so_far.push_str("slow ");
                    let _ = deltas.send(so_far.clone());
                    tokio::time::sleep(Duration::from_millis(100)).await;
                }
            }
            let answer = format!("echo from {model}: {text}");
            let mut so_far = String::new();
            for word in answer.split_inclusive(' ') {
                so_far.push_str(word);
                let _ = deltas.send(so_far.clone());
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
            Ok(answer)
        })
    }

    fn reset(&self) {
        println!("CHAT reset");
    }
}

#[test]
#[ignore = "driven by android/app/src/test/.../RustDesktopInteropTest.kt"]
fn interop_server() {
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    runtime.block_on(async {
        let identity = pairing::load_or_create_identity(&MemStore::default()).unwrap();
        let token = std::env::var("COUCOU_INTEROP_TOKEN").unwrap_or_else(|_| "interop-token-0123456789abcdef".into());
        let hub = Hub::new(Arc::new(Printing));
        let fake = Arc::new(FakeChat { on: AtomicBool::new(false) });
        let switches = Arc::new(Switches { details: AtomicBool::new(false), diffs: AtomicBool::new(false), usage: AtomicBool::new(false), services: std::sync::Mutex::new(Vec::new()) });
        let shared = server::Shared::with_features(
            hub.clone(), token.clone(), "Rust desktop".into(), Some(ChatLink::new(fake.clone())), switches.clone(),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let handle = server::serve(listener, server::tls_acceptor(&identity).unwrap(), shared.clone());
        let link = pairing::pairing_link("127.0.0.1", port, &identity.fingerprint, &token, "Rust desktop");
        println!("{}", serde_json::json!({ "listening": port, "fp": identity.fingerprint, "link": link }));

        let (tx, rx) = std::sync::mpsc::channel::<String>();
        std::thread::spawn(move || {
            for line in std::io::stdin().lock().lines().map_while(Result::ok) {
                if tx.send(line).is_err() {
                    break;
                }
            }
        });

        loop {
            let Ok(line) = rx.try_recv() else {
                tokio::time::sleep(Duration::from_millis(20)).await;
                continue;
            };
            let mut words = line.splitn(3, ' ');
            match (words.next(), words.next(), words.next()) {
                (Some("sessions"), _, _) => hub.publish(
                    vec![
                        SessionIn { pill_id: "integration_claude".into(), agent: "Claude Code".into(), state: "working".into(), status_text: "Editing files".into(), step_index: 2, step_count: 6,
                            steps: vec!["Read · README.md".into(), "Edit · src/app.ts".into()],
                            final_line: Some("Fixed the bug".into()),
                            // a full path, to prove only the folder's name leaves the computer
                            project: Some("/home/someone/private/proj".into()),
                            color: Some("#2DD4BF".into()),
                            // a full path: only the file's name leaves the computer
                            files: vec![FileIn { id: 7, name: "/home/someone/private/proj/src/app.ts".into(), added: 3, removed: 1, ..Default::default() }],
                        },
                        SessionIn { pill_id: "agent_gemini".into(), agent: "Gemini CLI".into(), state: "sleeping".into(), ..Default::default() },
                    ],
                    None,
                    server::now_ms(),
                ),
                (Some("approval"), Some(id), Some(command)) => hub.publish(
                    vec![],
                    Some(ApprovalIn { request_id: id.into(), session_id: "interop".into(), pill_id: "integration_claude".into(), tool: "Bash".into(), command: command.into() }),
                    server::now_ms(),
                ),
                (Some("clear"), _, _) => hub.publish(vec![], None, server::now_ms()),
                (Some("repair"), Some(new_token), _) => {
                    *shared.token.lock().unwrap() = new_token.to_string();
                    hub.kick_all("auth", "unpaired");
                }
                (Some("chat"), Some(state), _) => fake.on.store(state == "on", Ordering::SeqCst),
                // `services stripe,notion` ticks those (empty: none); `servicecards` publishes a Stripe and a Notion card.
                (Some("services"), ticks, _) => {
                    *switches.services.lock().unwrap() = ticks.unwrap_or("").split(',').filter(|s| !s.is_empty()).map(|s| format!("integration_{s}")).collect();
                }
                (Some("servicecards"), _, _) => hub.publish_services(vec![
                    ServiceIn { id: "integration_stripe".into(), title: "Stripe".into(), headline: "12.50 EUR".into(), reason: Some("Payments".into()), items: vec![ServiceItemIn { label: "Payment".into(), detail: "+9.00 · 2m".into() }] },
                    ServiceIn { id: "integration_notion".into(), title: "Notion".into(), headline: "3".into(), reason: None, items: vec![ServiceItemIn { label: "Private page".into(), detail: "1m".into() }] },
                ]),
                (Some("usage"), Some(state), _) => switches.usage.store(state == "on", Ordering::SeqCst),
                (Some("usagepct"), Some(pct), _) => hub.publish_usage(UsageIn {
                    claude: Some(PlanIn { five_hour: Some(WindowIn { used_pct: pct.parse().unwrap_or(0.0), resets_at: 1_900_000_000_000 }), plan_type: Some("max".into()), ..PlanIn::default() }),
                    codex: None,
                }),
                (Some("diffs"), Some(state), _) => switches.diffs.store(state == "on", Ordering::SeqCst),
                (Some("diff"), Some(conn), Some(lines)) => {
                    // `lines` is how many sample lines to send (to try the limits and the parts).
                    let n: usize = lines.parse().unwrap_or(3);
                    let rows = (0..n).map(|i| (if i % 3 == 0 { "+" } else if i % 3 == 1 { "-" } else { " " }.to_string(), format!("line {i} of the file"))).collect();
                    hub.send_diff(conn.parse().unwrap_or(0), DiffIn { pill_id: "integration_claude".into(), file_id: 7, name: "/private/dir/app.ts".into(), added: 3, removed: 1, lines: rows, ..Default::default() });
                }
                (Some("outfit"), Some(value), _) => hub.publish_outfit(value),
                (Some("details"), Some(state), _) => switches.details.store(state == "on", Ordering::SeqCst),
                (Some("quit"), _, _) => break,
                _ => println!("? {line}"),
            }
            println!("OK {line}");
        }
        handle.stop();
    });
}
