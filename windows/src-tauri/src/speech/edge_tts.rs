//! Optional online Read Aloud via a project-owned, pinned edge-tts environment.
//! Never reads CLI credentials or installs global Python packages.
use std::io::{Read, Write};
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const HELPER: &str = include_str!("edge_tts_helper.py");
const MAX_AUDIO: u64 = 8 * 1024 * 1024;

pub fn generate(python: &Path, text: &str, running: impl FnMut() -> bool) -> Option<Vec<u8>> {
    if text.trim().is_empty() || text.chars().count() > 8000 || !python.is_file() {
        return None;
    }
    run(python, HELPER, text, running)
}

fn run(
    python: &Path,
    helper: &str,
    text: &str,
    mut running: impl FnMut() -> bool,
) -> Option<Vec<u8>> {
    if !running() {
        return None;
    }
    let mut child = Command::new(python)
        .args(["-I", "-c", helper])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let stdout = child.stdout.take()?;
    let reader = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        stdout.take(MAX_AUDIO + 1).read_to_end(&mut bytes).ok()?;
        (!bytes.is_empty() && bytes.len() as u64 <= MAX_AUDIO).then_some(bytes)
    });
    let input = serde_json::to_vec(&serde_json::json!({"text": text})).ok()?;
    let written = child
        .stdin
        .take()
        .is_some_and(|mut stdin| stdin.write_all(&input).is_ok());
    let until = Instant::now() + Duration::from_secs(30);
    let success = loop {
        if !written || !running() || Instant::now() >= until {
            let _ = child.kill();
            let _ = child.wait();
            break false;
        }
        match child.try_wait() {
            Ok(Some(status)) => break status.success(),
            Ok(None) => std::thread::sleep(Duration::from_millis(50)),
            Err(_) => {
                let _ = child.kill();
                let _ = child.wait();
                break false;
            }
        }
    };
    let result = reader.join().ok().flatten();
    (success && running()).then_some(result).flatten()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[cfg(target_os = "linux")]
    fn stdin_keeps_text_out_of_arguments_and_cancellation_reaps_the_child() {
        let python = Path::new("/usr/bin/python3");
        let echo =
            "import json,sys; sys.stdout.buffer.write(json.load(sys.stdin)['text'].encode())";
        let text = "Olá, Pedro. $(this is text) ' \"";
        assert_eq!(run(python, echo, text, || true).unwrap(), text.as_bytes());
        let started = Instant::now();
        let sleeper = "import json,sys,time; json.load(sys.stdin); time.sleep(30)";
        assert!(run(python, sleeper, text, || started.elapsed()
            < Duration::from_millis(120))
        .is_none());
        assert!(started.elapsed() < Duration::from_secs(3));
        assert!(run(python, "raise SystemExit(1)", text, || true).is_none());
    }

    #[test]
    #[ignore = "Requires the project's edge-tts environment and an online service"]
    fn evaluate_raquel_with_synthetic_text() {
        let python = std::env::var("COUCOU_TEST_EDGE_PYTHON").expect("COUCOU_TEST_EDGE_PYTHON");
        let target = std::env::var("COUCOU_TEST_EDGE_OUTPUT").expect("COUCOU_TEST_EDGE_OUTPUT");
        let started = Instant::now();
        let mp3 = generate(
            Path::new(&python),
            "Olá, Pedro. Posso ajudar-te a organizar os ficheiros, passo a passo.",
            || true,
        )
        .expect("Read Aloud voice");
        println!(
            "Raquel: {:.3} seconds, {} bytes",
            started.elapsed().as_secs_f64(),
            mp3.len()
        );
        std::fs::write(target, mp3).unwrap();
    }
}
