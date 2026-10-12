// What the four CLI session readers (claude_, codex_, opencode_, devin_sessions)
// share: what a session id may be, how a prompt is handed to a CLI, what a
// resumed run answered, and reading their history files.

use std::collections::BTreeSet;
use std::path::Path;
use std::sync::Mutex;

use crate::cli_chat;

/// A session id as the CLIs write them — UUIDs, OpenCode's `ses_…`, Devin's
/// prefixes: letters, digits, `-` and `_`, at most 128, and not starting with
/// `-`. The id comes from the phone: anything else (a path, an option) never
/// reaches a file name or a command line.
pub fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && !id.starts_with('-')
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// The prompt as one argument the CLI cannot take for an option: one starting
/// with `-` gets a leading space. A `.cmd`/`.bat` launcher (npm's shims on
/// Windows) cannot be given a line break at all — Rust refuses to start it —
/// so there, and only there, line breaks become spaces.
pub fn prompt_arg(query: &str, cli: &Path) -> String {
    let batch = cli
        .extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| e.eq_ignore_ascii_case("cmd") || e.eq_ignore_ascii_case("bat"));
    let mut prompt = if batch {
        query.split(['\r', '\n']).filter(|l| !l.is_empty()).collect::<Vec<_>>().join(" ")
    } else {
        query.to_string()
    };
    if prompt.starts_with('-') {
        prompt.insert(0, ' ');
    }
    prompt
}

/// What a resumed run answered: its output, or the first line of its error.
/// `who` names the CLI ("The Codex CLI") in the fallback message.
pub fn answer(out: &std::process::Output, who: &str) -> Result<String, String> {
    if out.status.success() {
        let text = cli_chat::strip_ansi(&String::from_utf8_lossy(&out.stdout)).trim().to_string();
        return if text.is_empty() { Err("No response text.".into()) } else { Ok(text) };
    }
    let stderr = cli_chat::strip_ansi(&String::from_utf8_lossy(&out.stderr));
    Err(stderr
        .lines()
        .find(|l| !l.trim().is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| format!("{who} failed.")))
}

/// Logs `what` failing, once per run: a CLI whose store changed shape must show
/// up in coucou.log, not flood it every minute the picker is open.
#[allow(dead_code)] // used by the Devin/OpenCode readers (Task 2.10)
pub fn log_once(what: &'static str, err: &str) {
    static SEEN: Mutex<BTreeSet<&'static str>> = Mutex::new(BTreeSet::new());
    if SEEN.lock().unwrap_or_else(|e| e.into_inner()).insert(what) {
        crate::log::line(format!("{what}: {err}"));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    #[test]
    fn ids_that_could_be_paths_or_options_are_refused() {
        for ok in ["0f9c2a8e-1b2c-4d5e-8f90-123456789abc", "ses_abc123", "abcd"] {
            assert!(valid_id(ok), "{ok}");
        }
        for bad in ["", "../../etc/passwd", r"C:\x", "a/b", "a b", "--dangerously-skip-permissions", "-r"] {
            assert!(!valid_id(bad), "{bad}");
        }
        assert!(!valid_id(&"a".repeat(129)));
    }

    #[test]
    fn a_prompt_never_reads_as_an_option() {
        let exe = Path::new("/usr/local/bin/claude");
        assert_eq!(prompt_arg("--model x run it", exe), " --model x run it");
        assert_eq!(prompt_arg("-c approval_policy=never", exe), " -c approval_policy=never");
        assert_eq!(prompt_arg("répare le test", exe), "répare le test");
        assert_eq!(prompt_arg("line one\nline two", exe), "line one\nline two");
        // npm's launcher cannot take a line break at all: it becomes a space.
        let shim = Path::new(r"C:\Users\Zoé\AppData\Roaming\npm\codex.CMD");
        assert_eq!(prompt_arg("line one\r\nline two\n", shim), "line one line two");
        assert_eq!(prompt_arg("-x\nmore", shim), " -x more");
    }

    #[cfg(windows)]
    fn status(ok: bool) -> std::process::ExitStatus {
        std::os::windows::process::ExitStatusExt::from_raw(if ok { 0 } else { 1 })
    }
    #[cfg(unix)]
    fn status(ok: bool) -> std::process::ExitStatus {
        std::os::unix::process::ExitStatusExt::from_raw(if ok { 0 } else { 256 })
    }

    fn output(ok: bool, stdout: &str, stderr: &str) -> std::process::Output {
        std::process::Output { status: status(ok), stdout: stdout.into(), stderr: stderr.into() }
    }

    #[test]
    fn a_run_answers_with_its_output_or_its_first_error_line() {
        assert_eq!(answer(&output(true, "\u{1b}[32mDone.\u{1b}[0m\n", ""), "The Codex CLI"), Ok("Done.".into()));
        assert_eq!(answer(&output(true, "  \n", ""), "The Codex CLI"), Err("No response text.".into()));
        assert_eq!(answer(&output(false, "", "\nError: not logged in\nmore"), "The Codex CLI"), Err("Error: not logged in".into()));
        assert_eq!(answer(&output(false, "", ""), "The Codex CLI"), Err("The Codex CLI failed.".into()));
    }
}
