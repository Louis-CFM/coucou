// A scripted stdio peer, compiled by the protocol tests. Never calls a model.
use std::io::{self, BufRead, Write};

fn main() {
    let mode = std::env::current_exe()
        .unwrap()
        .file_stem()
        .unwrap()
        .to_string_lossy()
        .into_owned();
    for line in io::stdin().lock().lines() {
        let line = line.unwrap();
        let Some(at) = line.find("\"id\":") else {
            continue;
        };
        let id: String = line[at + 5..]
            .chars()
            .take_while(|c| c.is_ascii_digit())
            .collect();
        if line.contains("\"initialize\"") {
            if mode.contains("hang") {
                std::thread::sleep(std::time::Duration::from_secs(60));
            }
            if mode.contains("closed") {
                return;
            }
            println!("{{\"id\":{id},\"result\":{{}}}}");
        } else if line.contains("\"account/read\"") {
            println!("{{\"id\":{id},\"result\":{{\"account\":{{\"type\":\"chatgpt\",\"planType\":\"plus\"}},\"requiresOpenaiAuth\":true}}}}");
        } else if line.contains("\"turn/start\"") {
            // Notifications may arrive before the response to turn/start.
            println!("{{\"method\":\"item/agentMessage/delta\",\"params\":{{\"threadId\":\"t\",\"turnId\":\"u\",\"itemId\":\"a\",\"delta\":\"hello\"}}}}");
            println!("{{\"method\":\"turn/completed\",\"params\":{{\"threadId\":\"t\",\"turn\":{{\"id\":\"u\",\"status\":\"completed\"}}}}}}");
            println!("{{\"id\":{id},\"result\":{{\"turn\":{{\"id\":\"u\"}}}}}}");
        } else {
            println!("{{\"id\":{id},\"error\":{{\"message\":\"scripted failure\"}}}}");
        }
        io::stdout().flush().unwrap();
    }
}
