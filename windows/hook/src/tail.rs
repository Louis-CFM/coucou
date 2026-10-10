//! The last lines a finished command printed, for the island's code view. The
//! rest of `tool_response` is never forwarded: it may hold anything.

/// How many lines of a command's output go on, and how wide each may be.
const TAIL_LINES: usize = 3;
const TAIL_WIDTH: usize = 160;

/// The last few non-empty lines of `stdout`, else of `stderr`, without colour
/// codes, trailing blanks cut, each cut to TAIL_WIDTH characters.
pub fn output_tail(stdout: Option<&str>, stderr: Option<&str>) -> Option<Vec<String>> {
    let text = [stdout, stderr].into_iter().flatten().find(|s| !s.trim().is_empty())?;
    let mut lines: Vec<String> = text
        .lines()
        .map(|l| strip_ansi(l).trim_end().to_string())
        .filter(|l| !l.trim().is_empty())
        .rev()
        .take(TAIL_LINES)
        .map(|l| l.chars().take(TAIL_WIDTH).collect())
        .collect();
    lines.reverse();
    (!lines.is_empty()).then_some(lines)
}

/// Drops `ESC [ … letter` colour and cursor sequences, and any other lone ESC.
pub fn strip_ansi(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '\u{1b}' {
            out.push(c);
            continue;
        }
        if chars.peek() != Some(&'[') {
            continue;
        }
        chars.next();
        for n in chars.by_ref() {
            if n.is_ascii_alphabetic() {
                break;
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_last_three_lines_survive_without_colours() {
        let out = "a\n\n\u{1b}[32mPASS\u{1b}[0m tests/x.ts\n  \u{2713} works (3 ms)\nTests: 1 passed  \n\n";
        assert_eq!(
            output_tail(Some(out), None).unwrap(),
            vec!["PASS tests/x.ts", "  \u{2713} works (3 ms)", "Tests: 1 passed"]
        );
    }

    #[test]
    fn stderr_is_the_fallback_and_nothing_printed_is_nothing() {
        assert_eq!(output_tail(Some(""), Some("boom")).unwrap(), vec!["boom"]);
        assert_eq!(output_tail(Some("ok"), Some("ignored")).unwrap(), vec!["ok"]);
        assert!(output_tail(Some(" \n\t\n"), None).is_none());
        assert!(output_tail(None, Some("")).is_none());
        assert!(output_tail(None, None).is_none());
    }

    #[test]
    fn long_lines_are_cut_on_a_char_boundary() {
        let line = "\u{e9}".repeat(400);
        let tail = output_tail(Some(&line), None).unwrap();
        assert_eq!(tail[0].chars().count(), TAIL_WIDTH);
    }

    #[test]
    fn cursor_sequences_and_lone_escapes_go() {
        assert_eq!(strip_ansi("\u{1b}[2K\u{1b}[1Gdone"), "done");
        assert_eq!(strip_ansi("a\u{1b}b"), "ab");
        assert_eq!(strip_ansi("\u{1b}[1;31mred\u{1b}[0m"), "red");
        assert_eq!(strip_ansi("plain"), "plain");
    }
}
