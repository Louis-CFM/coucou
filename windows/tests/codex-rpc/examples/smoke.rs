//! Opt-in account and execution smoke test; writes only in its own temp folder.
use coucou_codex_rpc_tests::{gravity, Client, TurnOptions};
use std::{path::PathBuf, time::Duration};

fn main() -> Result<(), String> {
    let args: Vec<_> = std::env::args_os().collect();
    let codex = args
        .get(1)
        .map(PathBuf::from)
        .ok_or("Pass the absolute Codex CLI path.")?;
    let agy = args.get(2).map(PathBuf::from);
    let cwd = std::env::temp_dir().join(format!("coucou-cli-smoke-{}", std::process::id()));
    std::fs::create_dir_all(&cwd).map_err(|e| e.to_string())?;
    let result = (|| {
        let mut client = Client::start(&codex, &cwd, Duration::from_secs(180), true)?;
        let models = client.models()?;
        println!("Codex account connected; {} models offered", models.len());
        let system = "You are Mochi. Reply briefly in Portuguese. Do not delegate or use subagents. Follow only the user's exact requested actions.";
        let reply = client.answer(TurnOptions { model: "", system, history: &[],
            query: "A palavra para recordar é jacarandá. Confirma em poucas palavras. Não uses ferramentas.",
            tools: &[], session_id: None, full_access: false }, |_, _| (String::new(), false), |_, _| None, |_| {}, |_| {})?;
        println!("Codex first turn: {}", reply.text);
        drop(client);
        let mut client = Client::start(&codex, &cwd, Duration::from_secs(180), true)?;
        let followup = client.answer(
            TurnOptions {
                model: "",
                system,
                history: &[],
                query:
                    "Qual foi a palavra? Responde apenas com essa palavra. Não uses ferramentas.",
                tools: &[],
                session_id: Some(&reply.session_id),
                full_access: false,
            },
            |_, _| (String::new(), false),
            |_, _| None,
            |_| {},
            |_| {},
        )?;
        println!("Codex resumed follow-up: {}", followup.text);
        if !followup.text.to_lowercase().contains("jacarandá") {
            return Err("Codex conversation context was lost.".into());
        }
        drop(client);
        let mut client = Client::start(&codex, &cwd, Duration::from_secs(180), true)?;
        let executed = client.answer(TurnOptions { model: "", system, history: &[],
            query: "Executa um comando de shell para escrever apenas coucou-native-ok no ficheiro codex-marker.txt na pasta atual. Lê o ficheiro com outro comando e responde apenas com o conteúdo. Não alteres mais nada.",
            tools: &[], session_id: None, full_access: true }, |_, _| (String::new(), false), |_, _| None, |_| {}, |_| {})?;
        println!("Codex command execution: {}", executed.text);
        if std::fs::read_to_string(cwd.join("codex-marker.txt"))
            .unwrap_or_default()
            .trim()
            != "coucou-native-ok"
        {
            return Err("Codex native execution failed.".into());
        }
        if let Some(agy) = agy {
            let models = gravity::models(&agy, &cwd)?;
            println!(
                "Antigravity account connected; {} models offered",
                models.len()
            );
            let mut session = String::new();
            let first = gravity::answer(
                &agy,
                &cwd,
                "",
                system,
                &[],
                "Recorda a palavra jacarandá. Confirma em poucas palavras sem usar ferramentas.",
                None,
                false,
                None,
                |id| session = id.into(),
                |_| {},
            )?;
            println!("Antigravity first turn: {}", first.text);
            let second = gravity::answer(
                &agy,
                &cwd,
                "",
                system,
                &[],
                "Qual foi a palavra? Responde apenas com essa palavra sem ferramentas.",
                Some(&session),
                false,
                None,
                |_| {},
                |_| {},
            )?;
            println!("Antigravity resumed follow-up: {}", second.text);
            if !second.text.to_lowercase().contains("jacarandá") {
                return Err("Antigravity conversation context was lost.".into());
            }
            let executed = gravity::answer(&agy, &cwd, "", system, &[],
                "Executa um comando de shell para escrever apenas coucou-native-ok em gravity-marker.txt na pasta atual. Lê o ficheiro com outro comando e responde apenas com o conteúdo. Não alteres mais nada.", None, true, None, |_| {}, |_| {})?;
            println!("Antigravity command execution: {}", executed.text);
            if std::fs::read_to_string(cwd.join("gravity-marker.txt"))
                .unwrap_or_default()
                .trim()
                != "coucou-native-ok"
            {
                return Err("Antigravity native execution failed.".into());
            }
        }
        Ok(())
    })();
    let _ = std::fs::remove_dir_all(cwd);
    result
}
