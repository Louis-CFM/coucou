//! coucou-hook — the relay Claude Code runs on every hook event.
//!
//! Reads the hook JSON on stdin, adds a little terminal context, and hands it to
//! Coucou over the named pipe `\\.\pipe\coucou-<sid>` (Windows) or the Unix
//! socket `$XDG_RUNTIME_DIR/coucou.sock` (Linux).
//!
//! Hard rule (docs/CLAUDE.md): **never block Claude Code.**
//! * If the pipe does not exist — Coucou is closed — we exit 0 immediately with
//!   nothing on stdout, and the session carries on untouched.
//! * Every step runs under a deadline enforced by the main thread, so a pipe that
//!   accepts the connection and then stops reading cannot wedge the session
//!   either: we abandon the worker and exit.
//! * Only `PermissionRequest` waits for a human, because approving from the
//!   island — or answering Claude's question there — is the whole point. No
//!   answer means empty stdout, and Claude Code asks in its own window exactly
//!   as if Coucou were not installed.
//!
//! Usage: `coucou-hook <EventName>` (the name is also read from the JSON).

use std::io::{Read, Write};
use std::sync::mpsc;
use std::time::Duration;

/// Budget for getting a pipe connection. Beyond this Claude Code wins, always.
const CONNECT_TIMEOUT: Duration = Duration::from_millis(300);
/// Whole-run budget for an event nobody waits on: connect and write, no more.
const FIRE_AND_FORGET_BUDGET: Duration = Duration::from_secs(2);
/// How long a permission prompt may stay on screen before the terminal takes over.
const DECISION_BUDGET: Duration = Duration::from_secs(110);

/// Fields that are pointless to forward and can be enormous (a whole file read,
/// a full command output). The island shows a few lines of them at most, and
/// those are taken out first.
const DROPPED_FIELDS: &[&str] = &["tool_response", "transcript_path"];
/// The tools that leave a file changed. What they did to it is the one part of
/// a tool's response the island shows.
const EDIT_TOOLS: &[&str] = &["Edit", "Write", "MultiEdit", "NotebookEdit"];
/// The tools that run a command: what it printed is what they have to show.
const COMMAND_TOOLS: &[&str] = &["Bash", "PowerShell"];
/// Lines of a tool's result forwarded — the end of what a command printed, the
/// start of a file that was read — and the longest of them, in characters.
const MAX_RESULT_LINES: usize = 40;
const MAX_RESULT_LINE: usize = 240;
/// The tool Claude asks its questions with. Its input goes back whole, with the
/// answers added, so it is kept as it came.
const QUESTION_TOOL: &str = "AskUserQuestion";
/// Longest diff forwarded for one change, and longest line in it.
const MAX_PATCH: usize = 12_000;
const MAX_PATCH_LINE: usize = 400;
/// Largest file read to show what an edit would do to it.
const MAX_PROPOSAL_FILE: u64 = 2_000_000;
/// Unchanged lines kept on each side of a proposed change.
const CONTEXT_LINES: usize = 3;
/// How much of a transcript's end is read — for the conversation's title, and
/// for what Claude said last — and the events worth reading it on: a turn's
/// ends, not each of its tools.
const TRANSCRIPT_TAIL: u64 = 256 * 1024;
const TRANSCRIPT_EVENTS: &[&str] = &["SessionStart", "UserPromptSubmit", "Stop", "PermissionRequest"];
const MAX_TITLE: usize = 80;
/// Longest piece of Claude's last message forwarded with a Stop, in characters.
const MAX_LAST_MESSAGE: usize = 6_000;
/// Longest string forwarded for any single field; the island truncates to far
/// less than this anyway.
const MAX_FIELD_LEN: usize = 2_000;

#[cfg(windows)]
mod win;
#[cfg(windows)]
use win::connect;

#[cfg(target_os = "linux")]
mod unix;
#[cfg(target_os = "linux")]
use unix::connect;

fn main() {
    let Some(Event { line: payload, name: event, tool_input }) = read_event() else { std::process::exit(0) };

    // Only a permission request waits for a human, so only it gets the long budget.
    let waits_for_answer = event == "PermissionRequest";
    let budget = if waits_for_answer { DECISION_BUDGET } else { FIRE_AND_FORGET_BUDGET };

    // The worker owns every blocking call. If it overruns the budget we simply
    // stop listening and exit: the process dying takes the pipe handle with it.
    // (No catch_unwind here — the release profile is panic = "abort", so it would
    // be dead code. `talk` is written to have nothing to panic on instead.)
    let (tx, rx) = mpsc::channel::<Option<String>>();
    std::thread::spawn(move || {
        let _ = tx.send(talk(&payload, waits_for_answer));
    });

    if let Ok(Some(answer)) = rx.recv_timeout(budget) {
        if let Some(json) = reply_json(&answer, tool_input.as_ref()) {
            let mut out = std::io::stdout();
            let _ = writeln!(out, "{json}");
            let _ = out.flush();
        }
    }
    // Nothing printed: Claude Code asks in the terminal, as if we were not here.
    std::process::exit(0);
}

/// The documented PermissionRequest output. Anything we do not recognise prints
/// nothing at all rather than guessing — silence is the safe answer.
/// See https://code.claude.com/docs/en/hooks
fn decision_json(decision: &str) -> Option<String> {
    let behavior = match decision.trim() {
        // "always" still answers a plain allow; remembering it is the island's
        // business, not Claude Code's.
        "allow" | "always" => r#"{"behavior":"allow"}"#.to_string(),
        "deny" => r#"{"behavior":"deny","message":"Denied from Coucou"}"#.to_string(),
        // A question the user chose not to answer: Claude is told so, and decides
        // what to do without the answer.
        "skip" => r#"{"behavior":"deny","message":"The user skipped this question from Coucou, without answering it."}"#.to_string(),
        _ => return None,
    };
    Some(format!(
        r#"{{"hookSpecificOutput":{{"hookEventName":"PermissionRequest","decision":{behavior}}}}}"#
    ))
}

/// What Coucou said about a permission request, as the JSON Claude Code
/// expects. Besides the bare `allow` and `deny`, one line carries something:
/// `answer {…}`, for Claude's question tool — the answers picked on the island,
/// keyed by question.
fn reply_json(answer: &str, tool_input: Option<&serde_json::Value>) -> Option<String> {
    let answer = answer.trim();
    match answer.strip_prefix("answer ") {
        Some(answers) => answered_json(answers, tool_input?),
        None => decision_json(answer),
    }
}

/// Allows the question tool with its input as Claude sent it plus `answers`:
/// the tool then returns them as if they had been picked in Claude Code.
fn answered_json(answers: &str, tool_input: &serde_json::Value) -> Option<String> {
    let answers = serde_json::from_str::<serde_json::Value>(answers).ok()?;
    if !answers.is_object() {
        return None;
    }
    let mut input = tool_input.as_object()?.clone();
    input.insert("answers".into(), answers);
    let input = serde_json::Value::Object(input);
    Some(format!(
        r#"{{"hookSpecificOutput":{{"hookEventName":"PermissionRequest","decision":{{"behavior":"allow","updatedInput":{input}}}}}}}"#
    ))
}

/// A unified diff being written: capped in length, its lines counted whole.
#[derive(Default)]
struct Patch {
    text: String,
    additions: u64,
    deletions: u64,
    truncated: bool,
}

impl Patch {
    fn hunk(&mut self, old_start: usize, old_lines: usize, new_start: usize, new_lines: usize) {
        self.text.push_str(&format!("@@ -{old_start},{old_lines} +{new_start},{new_lines} @@\n"));
    }

    /// One line with its sign. Past the cap it is still counted, no longer kept.
    fn push(&mut self, sign: char, line: &str) {
        match sign {
            '+' => self.additions += 1,
            '-' => self.deletions += 1,
            _ => {}
        }
        if self.truncated || self.text.len() + line.len() > MAX_PATCH {
            self.truncated = true;
            return;
        }
        let mut end = line.len().min(MAX_PATCH_LINE);
        while !line.is_char_boundary(end) {
            end -= 1;
        }
        self.text.push(sign);
        self.text.push_str(&line[..end]);
        self.text.push('\n');
    }

    fn json(self, created: bool) -> serde_json::Value {
        serde_json::json!({
            "patch": self.text, "additions": self.additions, "deletions": self.deletions,
            "truncated": self.truncated, "created": created,
        })
    }
}

/// The unified diff of what an edit tool did, from the hunks Claude Code puts in
/// its response — with the lines' real numbers, which the tool's input has not.
/// A file written new has no hunk: its content is the diff.
fn change_of(response: &serde_json::Value) -> Option<serde_json::Value> {
    let mut patch = Patch::default();
    let hunks = response.get("structuredPatch").and_then(|v| v.as_array());
    let created = response.get("type").and_then(|v| v.as_str()) == Some("create");
    match hunks {
        Some(hunks) if !hunks.is_empty() => {
            for hunk in hunks {
                let n = |key: &str| hunk.get(key).and_then(|v| v.as_u64()).unwrap_or(0) as usize;
                patch.hunk(n("oldStart"), n("oldLines"), n("newStart"), n("newLines"));
                for line in hunk.get("lines").and_then(|v| v.as_array()).into_iter().flatten() {
                    let line = line.as_str().unwrap_or_default();
                    let mut chars = line.chars();
                    patch.push(chars.next().unwrap_or(' '), chars.as_str());
                }
            }
        }
        _ if created => {
            let content = response.get("content").and_then(|v| v.as_str())?;
            patch.hunk(0, 0, 1, content.lines().count());
            for line in content.lines() {
                patch.push('+', line);
            }
        }
        _ => return None,
    }
    Some(patch.json(created))
}

/// A few lines of what a tool gave back, for the island to show under the
/// step: the end of what a command printed, the start of a file that was read,
/// what a search found. Nothing else of a tool's response leaves the relay.
fn result_of(tool: &str, response: &serde_json::Value) -> Option<serde_json::Value> {
    let text = |key: &str| response.get(key).and_then(|v| v.as_str()).unwrap_or_default();
    let names = || {
        let files = response.get("filenames").and_then(|v| v.as_array());
        files.into_iter().flatten().filter_map(|v| v.as_str()).collect::<Vec<_>>().join("\n")
    };
    match tool {
        _ if COMMAND_TOOLS.contains(&tool) => {
            let printed = [text("stdout"), text("stderr")].iter().filter(|s| !s.trim().is_empty()).cloned().collect::<Vec<_>>().join("\n");
            excerpt(&plain(&printed), None, true)
        }
        "Read" => {
            let file = response.get("file")?;
            let start = file.get("startLine").and_then(|v| v.as_u64()).unwrap_or(1);
            excerpt(file.get("content")?.as_str()?, Some(start), false)
        }
        "Grep" if !text("content").trim().is_empty() => excerpt(text("content"), None, false),
        "Grep" | "Glob" => excerpt(&names(), None, false),
        _ => None,
    }
}

/// The first lines of a text, or its last when `tail` — what a command ends
/// on is what it has to say. `start` is the number of the first line, for a file.
fn excerpt(text: &str, start: Option<u64>, tail: bool) -> Option<serde_json::Value> {
    let lines: Vec<&str> = text.trim_end().lines().collect();
    if lines.iter().all(|line| line.trim().is_empty()) {
        return None;
    }
    let truncated = lines.len() > MAX_RESULT_LINES;
    let kept = if tail { &lines[lines.len().saturating_sub(MAX_RESULT_LINES)..] } else { &lines[..lines.len().min(MAX_RESULT_LINES)] };
    let kept: Vec<String> = kept.iter().map(|line| clip(line.trim_end(), MAX_RESULT_LINE)).collect();
    Some(serde_json::json!({ "text": kept.join("\n"), "start": start, "truncated": truncated, "tail": tail }))
}

/// What a command printed without the escape sequences that colour it in a terminal.
fn plain(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '\u{1b}' {
            out.push(c);
            continue;
        }
        // ESC [ … up to the letter that ends the sequence; a lone ESC just goes.
        if chars.peek() == Some(&'[') {
            chars.next();
            for c in chars.by_ref() {
                if ('@'..='~').contains(&c) {
                    break;
                }
            }
        }
    }
    out
}

/// The file as Claude Code reads it: text, with Unix line ends. None when it
/// is not there, or too large to be worth showing a diff of.
fn read_text(path: &str) -> Option<String> {
    let size = std::fs::metadata(path).ok()?.len();
    if size > MAX_PROPOSAL_FILE {
        return None;
    }
    let bytes = std::fs::read(path).ok()?;
    Some(String::from_utf8_lossy(&bytes).replace("\r\n", "\n"))
}

/// One edit applied to a text, the way the Edit tool applies it.
fn apply(text: &str, edit: &serde_json::Value) -> Option<String> {
    let old = edit.get("old_string")?.as_str()?;
    let new = edit.get("new_string")?.as_str()?;
    if old.is_empty() || !text.contains(old) {
        return None;
    }
    let all = edit.get("replace_all").and_then(|v| v.as_bool()).unwrap_or(false);
    Some(if all { text.replace(old, new) } else { text.replacen(old, new, 1) })
}

/// What changes between two texts, as one hunk: the lines they share at both
/// ends are left out but for a few of context, and everything between is old
/// then new. Not the shortest diff there is — the honest one a relay can afford.
fn diff_of(before: &str, after: &str, created: bool) -> Option<serde_json::Value> {
    let a: Vec<&str> = before.lines().collect();
    let b: Vec<&str> = after.lines().collect();
    let mut head = 0;
    while head < a.len() && head < b.len() && a[head] == b[head] {
        head += 1;
    }
    let mut tail = 0;
    while tail < a.len() - head && tail < b.len() - head && a[a.len() - 1 - tail] == b[b.len() - 1 - tail] {
        tail += 1;
    }
    let (a_end, b_end) = (a.len() - tail, b.len() - tail);
    if head == a_end && head == b_end {
        return None;
    }
    let from = head.saturating_sub(CONTEXT_LINES);
    let after_lines = tail.min(CONTEXT_LINES);
    let (old_lines, new_lines) = (a_end - from + after_lines, b_end - from + after_lines);
    let mut patch = Patch::default();
    // A side with no line starts at 0, as `diff` writes it.
    patch.hunk(if old_lines == 0 { 0 } else { from + 1 }, old_lines, if new_lines == 0 { 0 } else { from + 1 }, new_lines);
    a[from..head].iter().for_each(|l| patch.push(' ', l));
    a[head..a_end].iter().for_each(|l| patch.push('-', l));
    b[head..b_end].iter().for_each(|l| patch.push('+', l));
    a[a_end..a_end + after_lines].iter().for_each(|l| patch.push(' ', l));
    Some(patch.json(created))
}

/// What an edit asking for permission would do to its file: the file as it is,
/// the edit applied to a copy, and the diff between the two. Nothing is written.
fn proposal_of(tool: &str, input: &serde_json::Value) -> Option<serde_json::Value> {
    let path = input.get("file_path")?.as_str()?;
    let before = read_text(path);
    let exists = std::path::Path::new(path).exists();
    let after = match tool {
        "Write" if before.is_some() || !exists => input.get("content")?.as_str()?.replace("\r\n", "\n"),
        "Edit" => apply(before.as_deref()?, input)?,
        "MultiEdit" => input
            .get("edits")?
            .as_array()?
            .iter()
            .try_fold(before.clone()?, |text, edit| apply(&text, edit))?,
        _ => return None,
    };
    diff_of(before.as_deref().unwrap_or_default(), &after, !exists)
}

/// The conversation's title, as Claude Code last wrote it in the session's
/// transcript. That file's format is Claude Code's own and may change: whatever
/// goes wrong here, there is simply no title. Only the file's end is read — a
/// long session's transcript runs to hundreds of megabytes.
fn title_of(tail: &str) -> Option<String> {
    tail.lines().rev().find_map(title_in)
}

/// The end of a session's transcript, as text.
fn tail_of(transcript: &str) -> Option<String> {
    use std::io::{Seek, SeekFrom};
    let mut file = std::fs::File::open(transcript).ok()?;
    let size = file.metadata().ok()?.len();
    file.seek(SeekFrom::Start(size.saturating_sub(TRANSCRIPT_TAIL))).ok()?;
    let mut tail = Vec::new();
    file.read_to_end(&mut tail).ok()?;
    Some(String::from_utf8_lossy(&tail).into_owned())
}

/// What Claude said last, from the transcript's end: the text of its last
/// message that has any. Read the same forgiving way as the title.
fn last_message_of(tail: &str) -> Option<String> {
    tail.lines().rev().find_map(said_in)
}

/// The text of an assistant's line of the transcript, if it says anything.
fn said_in(line: &str) -> Option<String> {
    if !line.contains("\"assistant\"") {
        return None;
    }
    let entry = serde_json::from_str::<serde_json::Value>(line).ok()?;
    if entry.get("type")?.as_str()? != "assistant" {
        return None;
    }
    let text = entry
        .pointer("/message/content")?
        .as_array()?
        .iter()
        .filter(|block| block.get("type").and_then(|v| v.as_str()) == Some("text"))
        .filter_map(|block| block.get("text")?.as_str())
        .collect::<Vec<_>>()
        .join("\n\n");
    let text = text.trim();
    (!text.is_empty()).then(|| clip(text, MAX_LAST_MESSAGE))
}

/// The first `max` characters, with a mark when some were left out.
fn clip(text: &str, max: usize) -> String {
    let mut out: String = text.chars().take(max).collect();
    if text.chars().nth(max).is_some() {
        out.push('…');
    }
    out
}

/// The title a transcript line carries, if it is one that names the conversation.
fn title_in(line: &str) -> Option<String> {
    if !line.contains("-title\"") && !line.contains("\"summary\"") {
        return None;
    }
    let entry = serde_json::from_str::<serde_json::Value>(line).ok()?;
    let title = match entry.get("type")?.as_str()? {
        "custom-title" => entry.get("customTitle"),
        "ai-title" => entry.get("aiTitle"),
        "summary" => entry.get("summary"),
        _ => None,
    }?
    .as_str()?
    .trim();
    (!title.is_empty()).then(|| title.chars().take(MAX_TITLE).collect())
}

/// One hook event, ready to go: the line for Coucou, its name, and — for
/// Claude's question tool only — its input exactly as it came.
struct Event {
    line: String,
    name: String,
    tool_input: Option<serde_json::Value>,
}

/// Reads stdin and returns the payload to forward plus the event name.
fn read_event() -> Option<Event> {
    let mut raw = Vec::new();
    if std::io::stdin().read_to_end(&mut raw).is_err() || raw.is_empty() {
        return None;
    }
    // Some shells hand us a UTF-8 BOM; serde_json would choke on it.
    if raw.starts_with(&[0xEF, 0xBB, 0xBF]) {
        raw.drain(..3);
    }

    let mut payload = serde_json::from_slice::<serde_json::Value>(&raw).ok()?;
    let map = payload.as_object_mut()?;

    // Parse argv: "coucou-hook.exe [--agent <name>] [<EventName>]"
    // --agent tags the payload with coucou_agent so the app routes to the right pill.
    // Absent or invalid names are validated and discarded by the app, not here.
    let mut agent = String::new();
    let mut arg_event = String::new();
    {
        let mut it = std::env::args().skip(1);
        while let Some(arg) = it.next() {
            if arg == "--agent" {
                agent = it.next().unwrap_or_default();
            } else if arg_event.is_empty() {
                arg_event = arg;
            }
        }
    }
    // Which agent this hook was installed for. Absent means Claude Code,
    // so existing hook commands keep working unchanged.
    if !agent.is_empty() {
        map.insert("coucou_agent".into(), serde_json::Value::String(agent));
    }
    let event = map
        .get("hook_event_name")
        .and_then(|v| v.as_str())
        .map(str::to_string)
        .filter(|s| !s.is_empty())
        .unwrap_or(arg_event);
    map.insert("hook_event_name".into(), serde_json::Value::String(event.clone()));

    let tool = map.get("tool_name").and_then(|v| v.as_str()).unwrap_or_default().to_string();
    // Before anything is cut or dropped: what an edit did, and a question whole.
    let change = (event == "PostToolUse" && EDIT_TOOLS.contains(&tool.as_str()))
        .then(|| map.get("tool_response").and_then(change_of))
        .flatten();
    // A few lines of what the tool gave back, to show under its step.
    let result = (event == "PostToolUse")
        .then(|| map.get("tool_response").and_then(|response| result_of(&tool, response)))
        .flatten();
    let tool_input = (tool == QUESTION_TOOL).then(|| map.get("tool_input").cloned()).flatten();
    // A question that got its answers, wherever they were picked: the island's
    // journal shows them under the question.
    let answers = (event == "PostToolUse" && tool == QUESTION_TOOL)
        .then(|| map.get("tool_response").and_then(|response| response.get("answers")).filter(|v| v.is_object()).cloned())
        .flatten();
    if let Some(answers) = answers {
        map.insert("answers".into(), answers);
    }
    // An edit asking for permission: what it would do, to look at before allowing.
    let proposal = (event == "PermissionRequest" && EDIT_TOOLS.contains(&tool.as_str()))
        .then(|| map.get("tool_input").and_then(|input| proposal_of(&tool, input)))
        .flatten();

    let tail = TRANSCRIPT_EVENTS
        .contains(&event.as_str())
        .then(|| map.get("transcript_path").and_then(|v| v.as_str()).and_then(tail_of))
        .flatten();
    let title = tail.as_deref().and_then(title_of);
    // A turn ends: what Claude said to end it. Claude Code hands it over when
    // it can; the transcript has it otherwise.
    let last_message = (event == "Stop")
        .then(|| {
            map.get("last_assistant_message")
                .and_then(|v| v.as_str())
                .map(|text| clip(text.trim(), MAX_LAST_MESSAGE))
                .filter(|text| !text.is_empty())
                .or_else(|| tail.as_deref().and_then(last_message_of))
        })
        .flatten();
    map.remove("last_assistant_message");

    for field in DROPPED_FIELDS {
        map.remove(*field);
    }

    let cwd_missing = map
        .get("cwd")
        .and_then(|v| v.as_str())
        .map(str::is_empty)
        .unwrap_or(true);
    if cwd_missing {
        if let Ok(cwd) = std::env::current_dir() {
            map.insert(
                "cwd".into(),
                serde_json::Value::String(cwd.to_string_lossy().to_string()),
            );
        }
    }

    // Which terminal the session runs in. Unlike macOS, Coucou here accepts
    // events from every terminal, so this is context only — never a filter.
    for (key, var) in [
        ("term_program", "TERM_PROGRAM"),
        ("wt_session", "WT_SESSION"),
        ("term_session_id", "TERM_SESSION_ID"),
        ("vscode_pid", "VSCODE_PID"),
        ("session_pid", "CLAUDE_CODE_SSE_PORT"),
        // Which Claude Code this is: the desktop app, VS Code, the command line.
        ("entrypoint", "CLAUDE_CODE_ENTRYPOINT"),
    ] {
        if !map.contains_key(key) {
            let value = std::env::var(var).unwrap_or_default();
            map.insert(key.into(), serde_json::Value::String(value));
        }
    }

    truncate_strings(&mut payload);
    // After the cut: a diff is already capped, and far longer than a field.
    if let Some(change) = change {
        payload["change"] = change;
    }
    if let Some(proposal) = proposal {
        payload["proposal"] = proposal;
    }
    if let Some(result) = result {
        payload["result"] = result;
    }
    if let Some(title) = title {
        payload["session_title"] = serde_json::Value::String(title);
    }
    if let Some(text) = last_message {
        payload["last_message"] = serde_json::Value::String(text);
    }

    let mut line = payload.to_string();
    line.push('\n');
    Some(Event { line, name: event, tool_input })
}

/// Caps every string in the payload. A single Write can carry a whole file.
fn truncate_strings(value: &mut serde_json::Value) {
    match value {
        serde_json::Value::String(s) => {
            if s.len() > MAX_FIELD_LEN {
                // Cut on a char boundary; a lone byte index can split UTF-8.
                let mut end = MAX_FIELD_LEN;
                while end > 0 && !s.is_char_boundary(end) {
                    end -= 1;
                }
                s.truncate(end);
                s.push('…');
            }
        }
        serde_json::Value::Array(items) => items.iter_mut().for_each(truncate_strings),
        serde_json::Value::Object(map) => map.values_mut().for_each(truncate_strings),
        _ => {}
    }
}

/// Connect, send, and — for a permission request — wait for the island's word.
fn talk(payload: &str, waits_for_answer: bool) -> Option<String> {
    let mut pipe = connect()?;

    if pipe.write_all(payload.as_bytes()).is_err() {
        return None;
    }
    let _ = pipe.flush();

    if !waits_for_answer {
        return None;
    }

    let mut buf = Vec::new();
    let mut chunk = [0u8; 1024];
    loop {
        match pipe.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => {
                buf.extend_from_slice(&chunk[..n]);
                if buf.contains(&b'\n') {
                    break;
                }
            }
            Err(_) => break,
        }
    }
    let answer = String::from_utf8_lossy(&buf).trim().to_string();
    (!answer.is_empty()).then_some(answer)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decision_json_matches_the_documented_shape() {
        assert_eq!(
            decision_json("allow").unwrap(),
            r#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
        );
        assert_eq!(
            decision_json("deny").unwrap(),
            r#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from Coucou"}}}"#
        );
        // "always" is an island concept; Claude Code just gets an allow.
        assert!(decision_json("always").unwrap().contains(r#""behavior":"allow""#));
        // A skipped question is a denial that says what it is.
        let skipped = decision_json("skip").unwrap();
        assert!(skipped.contains(r#""behavior":"deny""#) && skipped.contains("skipped this question"));
    }

    #[test]
    fn anything_unrecognised_prints_nothing() {
        assert!(decision_json("").is_none());
        assert!(decision_json("maybe").is_none());
        // The shape the app used to send must not be mistaken for a decision.
        assert!(decision_json(r#"{"permissionDecision":"allow"}"#).is_none());
    }

    #[test]
    fn an_answer_goes_back_with_the_question_it_answers() {
        let input = serde_json::json!({ "questions": [{ "question": "Which engine?" }] });
        let out = reply_json(r#"answer {"Which engine?":"Postgres"}"#, Some(&input)).unwrap();
        let v: serde_json::Value = serde_json::from_str(&out).unwrap();
        let decision = &v["hookSpecificOutput"]["decision"];
        assert_eq!(v["hookSpecificOutput"]["hookEventName"], "PermissionRequest");
        assert_eq!(decision["behavior"], "allow");
        assert_eq!(decision["updatedInput"]["questions"][0]["question"], "Which engine?");
        assert_eq!(decision["updatedInput"]["answers"]["Which engine?"], "Postgres");
        // Without the question there is nothing to answer; a plain word still works.
        assert!(reply_json(r#"answer {"a":"b"}"#, None).is_none());
        assert!(reply_json("answer nonsense", Some(&input)).is_none());
        assert_eq!(reply_json("deny", None), decision_json("deny"));
    }

    #[test]
    fn an_edit_becomes_a_diff_with_its_line_numbers() {
        let response = serde_json::json!({
            "filePath": "a.rs",
            "structuredPatch": [{
                "oldStart": 2, "oldLines": 3, "newStart": 2, "newLines": 4,
                "lines": [" mod claude;", "-mod files;", "+mod files;", "+mod github;", " mod hooks;"],
            }],
        });
        let change = change_of(&response).unwrap();
        assert_eq!(
            change["patch"],
            "@@ -2,3 +2,4 @@\n mod claude;\n-mod files;\n+mod files;\n+mod github;\n mod hooks;\n"
        );
        assert_eq!(change["additions"], 2);
        assert_eq!(change["deletions"], 1);
        assert_eq!(change["created"], false);
        assert_eq!(change["truncated"], false);
    }

    #[test]
    fn a_new_file_is_all_additions_and_a_long_one_is_cut() {
        let created = serde_json::json!({ "type": "create", "content": "one\ntwo\n", "structuredPatch": [] });
        let change = change_of(&created).unwrap();
        assert_eq!(change["patch"], "@@ -0,0 +1,2 @@\n+one\n+two\n");
        assert_eq!(change["created"], true);

        let long = serde_json::json!({ "type": "create", "content": "line of text\n".repeat(5000), "structuredPatch": [] });
        let change = change_of(&long).unwrap();
        assert!(change["patch"].as_str().unwrap().len() <= MAX_PATCH + 32);
        assert_eq!(change["truncated"], true);
        // Counted whole, even where the diff itself was cut.
        assert_eq!(change["additions"], 5000);

        // A response with nothing to show — a read, a failed edit — is no change.
        assert!(change_of(&serde_json::json!({ "structuredPatch": [] })).is_none());
        assert!(change_of(&serde_json::json!("done")).is_none());
    }

    #[test]
    fn a_proposed_edit_is_shown_where_it_lands() {
        let before = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n";
        let edit = serde_json::json!({ "old_string": "five", "new_string": "5\nfive and a half" });
        let after = apply(before, &edit).unwrap();
        let diff = diff_of(before, &after, false).unwrap();
        assert_eq!(
            diff["patch"],
            "@@ -2,7 +2,8 @@\n two\n three\n four\n-five\n+5\n+five and a half\n six\n seven\n eight\n"
        );
        assert_eq!(diff["additions"], 2);
        assert_eq!(diff["deletions"], 1);
        // Text that is not in the file cannot be replaced: no proposal, the card stays plain.
        assert!(apply(before, &serde_json::json!({ "old_string": "nine", "new_string": "9" })).is_none());
        // Nothing changed is nothing to show.
        assert!(diff_of(before, before, false).is_none());
    }

    #[test]
    fn a_proposed_edit_is_read_from_the_file_and_never_written() {
        let path = std::env::temp_dir().join(format!("coucou-hook-test-{}.txt", std::process::id()));
        std::fs::write(&path, "alpha\r\nbeta\r\ngamma\r\n").unwrap();
        let file = path.to_string_lossy().to_string();

        let edit = serde_json::json!({ "file_path": file, "old_string": "beta", "new_string": "BETA" });
        let proposal = proposal_of("Edit", &edit).unwrap();
        assert_eq!(proposal["patch"], "@@ -1,3 +1,3 @@\n alpha\n-beta\n+BETA\n gamma\n");
        assert_eq!(proposal["created"], false);

        let write = serde_json::json!({ "file_path": file, "content": "alpha\nbeta\ngamma\ndelta\n" });
        assert_eq!(proposal_of("Write", &write).unwrap()["patch"], "@@ -1,3 +1,4 @@\n alpha\n beta\n gamma\n+delta\n");

        assert_eq!(std::fs::read_to_string(&path).unwrap(), "alpha\r\nbeta\r\ngamma\r\n");
        std::fs::remove_file(&path).unwrap();

        // The file is gone now: writing it is creating it.
        let created = proposal_of("Write", &write).unwrap();
        assert_eq!(created["patch"], "@@ -0,0 +1,4 @@\n+alpha\n+beta\n+gamma\n+delta\n");
        assert_eq!(created["created"], true);
        assert!(proposal_of("Edit", &edit).is_none());
    }

    #[test]
    fn the_title_is_the_last_one_the_transcript_names() {
        assert_eq!(
            title_in(r#"{"type":"custom-title","customTitle":" Panneau GitHub ","sessionId":"x"}"#).as_deref(),
            Some("Panneau GitHub")
        );
        assert_eq!(title_in(r#"{"type":"summary","summary":"Fix the hook","leafUuid":"y"}"#).as_deref(), Some("Fix the hook"));
        // A message that merely talks about titles is not one.
        assert!(title_in(r#"{"type":"user","message":{"content":"the custom-title\" line"}}"#).is_none());
        assert!(title_in("not json -title\"").is_none());

        let path = std::env::temp_dir().join(format!("coucou-hook-title-{}.jsonl", std::process::id()));
        std::fs::write(
            &path,
            "{\"type\":\"custom-title\",\"customTitle\":\"First\"}\n{\"type\":\"user\"}\n{\"type\":\"custom-title\",\"customTitle\":\"Second\"}\n{\"type\":\"assistant\"}\n",
        )
        .unwrap();
        let tail = tail_of(&path.to_string_lossy()).unwrap();
        assert_eq!(title_of(&tail).as_deref(), Some("Second"));
        std::fs::remove_file(&path).unwrap();
        assert!(tail_of(&path.to_string_lossy()).is_none());
    }

    #[test]
    fn what_claude_said_last_is_its_last_message_with_words() {
        let tail = [
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"First answer."}]}}"#,
            r#"{"type":"user","message":{"content":"and the \"assistant\" said?"}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"hm"},{"type":"text","text":"Done."},{"type":"text","text":"Two files changed."}]}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}"#,
            r#"{"type":"custom-title","customTitle":"A title"}"#,
        ]
        .join("\n");
        assert_eq!(last_message_of(&tail).as_deref(), Some("Done.\n\nTwo files changed."));
        assert!(last_message_of(r#"{"type":"user","message":{"content":"hello"}}"#).is_none());
        assert_eq!(clip("héllo", 3), "hél…");
        assert_eq!(clip("hey", 3), "hey");
    }

    #[test]
    fn a_command_shows_the_end_of_what_it_printed_without_its_colours() {
        let printed = (1..=60).map(|i| format!("line {i}")).collect::<Vec<_>>().join("\n");
        let response = serde_json::json!({ "stdout": format!("{printed}\n\u{1b}[32mPASS\u{1b}[0m tests\n"), "stderr": "" });
        let result = result_of("Bash", &response).unwrap();
        let text = result["text"].as_str().unwrap();
        assert_eq!(text.lines().count(), MAX_RESULT_LINES);
        assert!(text.ends_with("PASS tests"));
        assert!(!text.contains("line 21\n"));
        assert_eq!(result["truncated"], true);
        assert_eq!(result["tail"], true);
        // A command that printed nothing has nothing to show.
        assert!(result_of("PowerShell", &serde_json::json!({ "stdout": "\n", "stderr": "" })).is_none());
    }

    #[test]
    fn a_file_read_shows_its_first_lines_with_their_numbers() {
        let response = serde_json::json!({ "type": "text", "file": { "content": "fn a() {}\nfn b() {}\n", "startLine": 12 } });
        let result = result_of("Read", &response).unwrap();
        assert_eq!(result["text"], "fn a() {}\nfn b() {}");
        assert_eq!(result["start"], 12);
        assert_eq!(result["tail"], false);
        // A search shows what it found; a tool with nothing to show, nothing.
        let found = result_of("Glob", &serde_json::json!({ "filenames": ["a.rs", "b.rs"] })).unwrap();
        assert_eq!(found["text"], "a.rs\nb.rs");
        assert!(result_of("WebFetch", &serde_json::json!({ "result": "…" })).is_none());
    }

    #[test]
    fn long_strings_are_cut_on_a_char_boundary() {
        let mut v = serde_json::json!({ "tool_input": { "content": "é".repeat(4000) } });
        truncate_strings(&mut v);
        let s = v["tool_input"]["content"].as_str().unwrap();
        assert!(s.len() <= MAX_FIELD_LEN + 4);
        assert!(s.ends_with('…'));
    }
}
