//! Opt-in check of the voice brain's app-server dynamic tool bridge, without audio.
use coucou_codex_rpc_tests::{Client, TurnOptions};
use serde_json::json;
use std::{path::PathBuf, time::Duration};

fn main() -> Result<(), String> {
    let exe = std::env::args_os()
        .nth(1)
        .map(PathBuf::from)
        .ok_or("Pass the absolute Codex path.")?;
    let cwd = std::env::temp_dir().join(format!("coucou-voice-smoke-{}", std::process::id()));
    std::fs::create_dir_all(&cwd).map_err(|e| e.to_string())?;
    let result = (|| {
        let mut client = Client::start(&exe, &cwd, Duration::from_secs(180), true)?;
        let tools = vec![
            json!({ "type":"function", "name":"service_info", "description":"Read the song currently playing in Mochi.", "inputSchema":{"type":"object","properties":{}} }),
        ];
        let mut called = false;
        let reply = client.answer(TurnOptions {
            model: "", system: "You are Mochi, a voice assistant. Reply in one short Portuguese sentence. You must call service_info before answering about music. Do not use shell or subagents.",
            history: &[], query: "Que música está a tocar?", tools: &tools, session_id: None, full_access: false,
        }, |name, _| {
            assert_eq!(name, "service_info");
            called = true;
            ("{\"song\":\"Grândola, Vila Morena\",\"artist\":\"Zeca Afonso\"}".into(), false)
        }, |_, _| None, |_| {}, |_| {})?;
        println!("Voice brain: {}", reply.text);
        if !called || !reply.text.contains("Grândola") {
            return Err("Voice tool call failed.".into());
        }
        Ok(())
    })();
    let _ = std::fs::remove_dir_all(cwd);
    result
}
