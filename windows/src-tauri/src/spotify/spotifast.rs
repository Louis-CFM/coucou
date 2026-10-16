//! Spotifast's documented CLI controls its running instance without credentials.
//! https://github.com/crmne/spotifast/blob/v0.13.1/docs/_guide/using-spotifast.md

use std::io::Read;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

#[derive(Debug, PartialEq)]
pub(super) struct State {
    pub volume: i32,
    pub shuffle: bool,
    pub repeat: &'static str,
}

pub(super) fn parse(raw: &str) -> Option<State> {
    // Text fields are sanitized by Spotifast. Future fields may be appended.
    let fields: Vec<_> = raw.trim_end_matches(['\r', '\n']).split('\t').collect();
    if fields.len() < 12 || !matches!(fields[0], "playing" | "paused" | "stopped") {
        return None;
    }
    let volume = fields[6].parse::<i32>().ok().filter(|v| (0..=100).contains(v))?;
    let shuffle = match fields[7] { "on" => true, "off" => false, _ => return None };
    let repeat = match fields[8] {
        "off" => "off", "context" => "context", "track" => "track", _ => return None,
    };
    Some(State { volume, shuffle, repeat })
}

pub(super) fn read(path: &Path) -> Option<State> {
    parse(&run(path, &["now-playing", "--raw"])? )
}

pub(super) fn control(path: &Path, action: &str, value: f64) -> bool {
    if !value.is_finite() { return false; }
    match action {
        "volume" => run(path, &["volume", &value.round().clamp(0.0, 100.0).to_string()]).is_some(),
        "shuffle" => run(path, &["shuffle", if value == 0.0 { "off" } else { "on" }]).is_some(),
        "repeat" => run(path, &["repeat", match value as i32 {
            0 => "off", 1 => "context", 2 => "track", _ => return false,
        }]).is_some(),
        _ => false,
    }
}

fn run(path: &Path, args: &[&str]) -> Option<String> {
    const LIMIT: u64 = 64 * 1024;
    let mut child = crate::platform::no_console(Command::new(path).args(args))
        .stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().ok()?;
    let stdout = child.stdout.take()?;
    // Drain concurrently: a long title must not fill the pipe and block exit.
    let reader = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        stdout.take(LIMIT + 1).read_to_end(&mut bytes).ok()?;
        (bytes.len() <= LIMIT as usize).then_some(bytes)
    });
    let deadline = Instant::now() + Duration::from_secs(2);
    let success = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status.success(),
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(20)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                break false;
            }
        }
    };
    let bytes = reader.join().ok().flatten()?;
    if !success { return None; }
    String::from_utf8(bytes).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parses_internal_controls_and_extra_fields() {
        let raw = "paused\tSong\tArtist\tAlbum\t1\t1000\t34\ton\ttrack\turl\tno\tSpotifast\tfuture\r\n";
        assert_eq!(parse(raw), Some(State { volume: 34, shuffle: true, repeat: "track" }));
        assert_eq!(parse(&raw.replace("34\ton\ttrack", "0\toff\tcontext")),
            Some(State { volume: 0, shuffle: false, repeat: "context" }));
    }
    #[test]
    fn rejects_missing_invalid_or_out_of_range_controls() {
        assert_eq!(parse("nothing playing"), None);
        let raw = "playing\ts\ta\tb\t0\t10\t101\ton\toff\tu\tno\td";
        assert_eq!(parse(raw), None);
        assert_eq!(parse(&raw.replace("101", "NaN")), None);
        assert_eq!(parse(&raw.replace("101", "30").replace("\ton\t", "\tunknown\t")), None);
    }
}
