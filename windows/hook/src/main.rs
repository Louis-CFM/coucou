//! coucou-hook — the relay Claude Code (and every other agent) runs on each hook
//! event.
//!
//! Reads the hook JSON on stdin, maps the agent's event and field names onto
//! Claude Code's (normalize.rs), adds a little terminal context, and hands it to
//! Coucou over the named pipe `\\.\pipe\coucou-<sid>` (Windows) or the Unix
//! socket `$XDG_RUNTIME_DIR/coucou.sock` (Linux).
//!
//! Hard rule (docs/CLAUDE.md): **never block the agent.**
//! * If the pipe does not exist — Coucou is closed — we exit 0 immediately, with
//!   only the "no opinion" reply the agent expects (reply.rs), and the session
//!   carries on untouched.
//! * Every step runs under a deadline enforced by the main thread, so a pipe that
//!   accepts the connection and then stops reading cannot wedge the session
//!   either: we abandon the worker and exit.
//! * Only `PermissionRequest` waits for an answer, because approving from the
//!   island is the whole point. No answer means no decision, and the agent asks
//!   in its terminal exactly as if Coucou were not installed.
//!
//! Usage: `coucou-hook [--agent <name>] [<EventName>]` (the event name is also
//! read from the JSON; `--agent` is absent for Claude Code), or
//! `coucou-hook --statusline` as Claude Code's status line command (plan usage,
//! see statusline.rs): it passes the plan limits on and runs the status line the
//! user had before, so that keeps working.

use std::io::{Read, Write};
use std::sync::mpsc;
use std::time::Duration;

use serde_json::{Map, Value};

mod normalize;
mod reply;

/// Budget for getting a pipe connection. Beyond this the agent wins, always.
const CONNECT_TIMEOUT: Duration = Duration::from_millis(300);
/// Whole-run budget for an event nobody waits on: connect and write, no more.
const FIRE_AND_FORGET_BUDGET: Duration = Duration::from_secs(2);
/// How long a permission prompt may stay on screen before the terminal takes over.
const DECISION_BUDGET: Duration = Duration::from_secs(110);
/// The fix loop (Coucou's Settings): how long Claude Code waits for the island's
/// word. After a test run it may first ask the double-check (5 s); a stop and a
/// commit are answered from what the island already knows.
fn loop_budget(event: &str) -> Duration {
    match event {
        "Stop" => Duration::from_secs(5),
        "PreToolUse" => Duration::from_secs(3),
        _ => Duration::from_secs(7),
    }
}
/// How much of a test command's output is kept: its end, where the summary is.
const TEST_OUTPUT_TAIL: usize = 8_000;

/// Fields that are pointless to forward and can be enormous (a whole file read,
/// a full command output). The island never shows them.
const DROPPED_FIELDS: &[&str] = &["tool_response", "tool_output", "transcript_path"];
/// Longest string forwarded for any single field; the island truncates to far
/// less than this anyway.
const MAX_FIELD_LEN: usize = 2_000;

mod statusline;

/// The live diff needs the whole text of a file edit, once it has happened:
/// PostToolUse of these tools keeps its edit strings far longer than the rest.
const DIFF_TOOLS: &[&str] = &["Edit", "MultiEdit", "Write"];
/// The `tool_input` keys holding the text being replaced or written.
const DIFF_FIELDS: &[&str] = &["old_string", "new_string", "content"];
/// Per edit string. The island stops diffing at 200 KB anyway (DiffEngine).
const MAX_DIFF_FIELD_LEN: usize = 256 * 1024;
/// For all edit strings of one event together, so the line stays well under the
/// 1 MiB the app reads from the pipe even once JSON-escaped.
const MAX_DIFF_TOTAL: usize = 512 * 1024;

#[cfg(windows)]
mod win;
#[cfg(windows)]
use win::connect;

#[cfg(target_os = "linux")]
mod unix;
#[cfg(target_os = "linux")]
use unix::connect;

/// What the command line says: `--agent <name>` and the event name.
struct Args {
    agent: String,
    event: String,
}

fn args() -> Args {
    let mut agent = String::new();
    let mut event = String::new();
    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        if arg == "--agent" {
            agent = it.next().unwrap_or_default();
        } else if event.is_empty() {
            event = arg;
        }
    }
    Args { agent, event }
}

/// One event, ready to forward.
struct Event {
    /// The payload as one line of JSON.
    line: String,
    /// The canonical event name.
    name: String,
    /// For Claude Code's AskUserQuestion, the question as it was asked.
    question: Option<Value>,
    /// For Claude Code's ExitPlanMode, the plan as it was proposed: an allow for it
    /// only counts with the plan sent back (reply.rs).
    plan: Option<Value>,
    /// The fix loop is on and may answer this one: the relay waits for it.
    loop_reply: bool,
}

fn main() {
    if std::env::args().skip(1).any(|a| a == "--statusline") {
        statusline::run();
    }
    let args = args();
    let mut raw = Vec::new();
    let _ = std::io::stdin().read_to_end(&mut raw);
    let env = |key: &str| std::env::var(key).ok();
    let cwd = std::env::current_dir().map(|p| p.to_string_lossy().to_string()).unwrap_or_default();

    let Some(event) = prepare(&raw, &args, &env, &cwd) else {
        // Nothing we could forward. An agent that needs JSON still gets its
        // "no opinion" — Copilot is fail-closed and would deny without it.
        let name = normalize::event(&args.event);
        print(reply::stdout(&args.agent, name, None, None));
        std::process::exit(0);
    };

    // Only an agent whose decisions the island can give waits for one; any other
    // would be held for nothing, its decision being thrown away (reply.rs).
    let waits_for_answer = event.name == "PermissionRequest" && reply::takes_decisions(&args.agent);
    let budget = if waits_for_answer {
        DECISION_BUDGET
    } else if event.loop_reply {
        loop_budget(&event.name)
    } else {
        FIRE_AND_FORGET_BUDGET
    };
    let waits_for_answer = waits_for_answer || event.loop_reply;

    // The worker owns every blocking call. If it overruns the budget we simply
    // stop listening and exit: the process dying takes the pipe handle with it.
    // (No catch_unwind here — the release profile is panic = "abort", so it would
    // be dead code. `talk` is written to have nothing to panic on instead.)
    let (tx, rx) = mpsc::channel::<Option<String>>();
    let line = event.line.clone();
    std::thread::spawn(move || {
        let _ = tx.send(talk(&line, waits_for_answer));
    });

    let decision = rx.recv_timeout(budget).ok().flatten();
    print(reply::stdout_with_plan(
        &args.agent,
        &event.name,
        decision.as_deref(),
        event.question.as_ref(),
        event.plan.as_ref(),
    ));
    std::process::exit(0);
}

/// The app's marker for the fix loop, `fix-loop.on` in Coucou's folder.
fn fix_loop_on(env: &dyn Fn(&str) -> Option<String>) -> bool {
    coucou_dir(env).map(|dir| dir.join("fix-loop.on").is_file()).unwrap_or(false)
}

/// Coucou's folder: the one this relay was put in (its `bin`, beside coucou.exe),
/// wherever Coucou is installed (D:\Coucou); else %LOCALAPPDATA%\Coucou.
fn coucou_dir(env: &dyn Fn(&str) -> Option<String>) -> Option<std::path::PathBuf> {
    let exe = std::env::current_exe().ok();
    let bin = exe.as_deref().and_then(std::path::Path::parent);
    if let Some(home) = bin.filter(|b| b.file_name().is_some_and(|n| n.eq_ignore_ascii_case("bin"))).and_then(std::path::Path::parent) {
        if home.join("coucou.exe").is_file() {
            return Some(home.to_path_buf());
        }
    }
    env("LOCALAPPDATA").map(|dir| std::path::Path::new(&dir).join("Coucou"))
}

/// The command of a shell tool call (Bash, PowerShell).
fn shell_command(map: &Map<String, Value>) -> Option<&str> {
    let tool = map.get("tool_name").and_then(Value::as_str)?;
    if tool != "Bash" && tool != "PowerShell" {
        return None;
    }
    map.get("tool_input").and_then(|i| i.get("command")).and_then(Value::as_str)
}

/// A command that may commit, push, open a pull request or publish. The island
/// decides (dotpals' ships); this only spares every other command the wait.
fn may_ship(command: &str) -> bool {
    let c = command.to_ascii_lowercase();
    (c.contains("git") && (c.contains("commit") || c.contains("push"))) || c.contains("gh pr create") || c.contains("npm publish")
}

/// A shell command that runs tests (dotpals' list): npm test, pytest, cargo test…
pub fn is_test_command(command: &str) -> bool {
    let c = format!(" {} ", command.to_ascii_lowercase().replace(['\t', '\n', '\r', ';', '&', '|', '(', ')'], " "));
    let c = c.split_whitespace().collect::<Vec<_>>().join(" ");
    let c = format!(" {c} ");
    const RUNS: [&str; 26] = [
        " npm test ", " npm run test", " pnpm test ", " pnpm run test", " yarn test", " yarn run test",
        " bun test", " bun run test", " node --test", " jest", " vitest", " mocha", " pytest",
        " tox ", " rspec", " phpunit", " playwright test", " go test", " cargo test", " dotnet test",
        " gradle test", " gradlew test", " mvn test", " -m unittest", " deno test", " make test",
    ];
    RUNS.iter().any(|r| c.contains(r)) || c.contains(" npx jest") || c.contains(" npx vitest")
}

/// The end of a finished test command's output (stdout, stderr, the error), for
/// the island to read its result. Only for a test command: no other output is
/// ever forwarded.
fn test_output(map: &serde_json::Map<String, Value>, name: &str) -> Option<(String, bool, bool)> {
    if name != "PostToolUse" && name != "PostToolUseFailure" {
        return None;
    }
    let tool = map.get("tool_name").and_then(Value::as_str)?;
    if tool != "Bash" && tool != "PowerShell" {
        return None;
    }
    let command = map.get("tool_input").and_then(|i| i.get("command")).and_then(Value::as_str)?;
    if !is_test_command(command) {
        return None;
    }
    let response = map.get("tool_response");
    let text = |v: Option<&Value>| v.and_then(Value::as_str).unwrap_or_default().to_string();
    let mut out = match response {
        Some(Value::String(s)) => s.clone(),
        Some(r) => format!("{}\n{}", text(r.get("stdout")), text(r.get("stderr"))),
        None => String::new(),
    };
    let error = text(map.get("error"));
    if !error.is_empty() {
        out.push('\n');
        out.push_str(&error);
    }
    let stopped = response.and_then(|r| r.get("interrupted")).and_then(Value::as_bool).unwrap_or(false);
    let out = out.trim().to_string();
    let tail = if out.len() > TEST_OUTPUT_TAIL {
        let mut start = out.len() - TEST_OUTPUT_TAIL;
        while !out.is_char_boundary(start) {
            start += 1;
        }
        format!("…{}", &out[start..])
    } else {
        out
    };
    Some((tail, name == "PostToolUseFailure", stopped))
}

fn print(line: Option<String>) {
    if let Some(line) = line {
        let mut out = std::io::stdout();
        let _ = writeln!(out, "{line}");
        let _ = out.flush();
    }
}

/// The payload to forward, from the raw stdin bytes. `env` reads an environment
/// variable and `cwd` is the working directory, so tests stay pure.
fn prepare(raw: &[u8], args: &Args, env: &dyn Fn(&str) -> Option<String>, cwd: &str) -> Option<Event> {
    // Some shells hand us a UTF-8 BOM; serde_json would choke on it.
    let raw = raw.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(raw);
    let mut payload = serde_json::from_slice::<Value>(raw).ok()?;
    let map = payload.as_object_mut()?;

    // Which agent this hook was installed for, so the app routes it to the right
    // pill. Absent means Claude Code, so existing hook commands keep working
    // unchanged; invalid names are discarded by the app, not here. A Claude Code
    // session started from the Claude desktop app is tagged `claude-desktop`.
    if let Some(tag) = agent_tag(&args.agent, env) {
        map.insert("coucou_agent".into(), Value::String(tag));
    }
    // Claude Code in Cursor's terminal goes on the Cursor pill (Mac #120).
    if !map.contains_key("term_editor") {
        if let Some(editor) = term_editor(env) {
            map.insert("term_editor".into(), Value::String(editor.into()));
        }
    }

    let raw_event = map
        .get("hook_event_name")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| args.event.clone());
    normalize::fields(map, env);
    let name = normalize::refine(normalize::event(&raw_event), map);
    map.insert("hook_event_name".into(), Value::String(name.clone()));

    let tests = test_output(map, &name);
    // "Make Claude fix failing tests" (Coucou's Settings, which leaves a marker while
    // it is on): Claude Code, here or in the Claude app, waits for the island's word
    // after a test run, before a commit or push, and when it stops (island/loop.ts).
    let loop_reply = args.agent.is_empty()
        && match name.as_str() {
            "Stop" => true,
            "PreToolUse" => shell_command(map).is_some_and(may_ship),
            "PostToolUse" | "PostToolUseFailure" => tests.is_some(),
            _ => false,
        }
        && fix_loop_on(env);
    for field in DROPPED_FIELDS {
        map.remove(*field);
    }

    if map.get("cwd").and_then(Value::as_str).map(str::is_empty).unwrap_or(true) && !cwd.is_empty() {
        map.insert("cwd".into(), Value::String(cwd.to_string()));
    }

    add_terminal_context(map, env);

    // Kept whole: what goes back to Claude Code must be its own input, not the
    // shortened copy the island is shown.
    let question = (map.get("tool_name").and_then(Value::as_str) == Some("AskUserQuestion"))
        .then(|| map.get("tool_input").cloned())
        .flatten();
    let plan = (map.get("tool_name").and_then(Value::as_str) == Some("ExitPlanMode"))
        .then(|| map.get("tool_input").cloned())
        .flatten();

    // Every string is capped, except the edit text of a finished Edit /
    // MultiEdit / Write, which the live diff needs whole (within its own limits).
    truncate_payload(&mut payload, &name);
    // After the caps: the end of a test run's output is kept whole.
    if let (Some((output, failed, stopped)), Some(map)) = (tests, payload.as_object_mut()) {
        map.insert("coucou_test_output".into(), Value::String(output));
        map.insert("coucou_test_failed".into(), Value::Bool(failed));
        map.insert("coucou_test_stopped".into(), Value::Bool(stopped));
    }
    if let (true, Some(map)) = (loop_reply, payload.as_object_mut()) {
        map.insert("coucou_loop".into(), Value::Bool(true));
    }

    let mut line = payload.to_string();
    line.push('\n');
    Some(Event { line, name, question, plan, loop_reply })
}

/// Which terminal the session runs in. Unlike macOS, Coucou here accepts events
/// from every terminal, so this is context only — never a filter.
fn add_terminal_context(map: &mut Map<String, Value>, env: &dyn Fn(&str) -> Option<String>) {
    for (key, var) in [
        ("term_program", "TERM_PROGRAM"),
        ("wt_session", "WT_SESSION"),
        ("term_session_id", "TERM_SESSION_ID"),
        ("vscode_pid", "VSCODE_PID"),
        ("session_pid", "CLAUDE_CODE_SSE_PORT"),
    ] {
        if !map.contains_key(key) {
            map.insert(key.into(), Value::String(env(var).unwrap_or_default()));
        }
    }
}

/// The `coucou_agent` tag: `--agent` when given, otherwise `claude-desktop` for
/// a Claude Code session started from the Claude desktop app, which says so in
/// CLAUDE_CODE_ENTRYPOINT — the same rule as the Mac's relay (#191). Nothing
/// for a plain Claude Code session.
fn agent_tag(arg: &str, env: &dyn Fn(&str) -> Option<String>) -> Option<String> {
    if !arg.is_empty() {
        return Some(arg.to_string());
    }
    (env("CLAUDE_CODE_ENTRYPOINT").as_deref() == Some("claude-desktop"))
        .then(|| "claude-desktop".to_string())
}

/// `cursor` when the session runs in Cursor's integrated terminal. Cursor sets
/// TERM_PROGRAM=vscode like VS Code does, so it is told apart by its own trace
/// variable, or by its executable behind VS Code's git helper.
fn term_editor(env: &dyn Fn(&str) -> Option<String>) -> Option<&'static str> {
    if env("CURSOR_TRACE_ID").is_some_and(|v| !v.is_empty()) {
        return Some("cursor");
    }
    let helper = env("VSCODE_GIT_ASKPASS_NODE").unwrap_or_default();
    let exe = helper.rsplit(['/', '\\']).next().unwrap_or_default().to_ascii_lowercase();
    exe.starts_with("cursor").then_some("cursor")
}

/// Caps the strings of a payload: every field to MAX_FIELD_LEN, except the edit
/// strings of a finished Edit / MultiEdit / Write, which the live diff needs
/// whole. If even those had to be cut, `coucou_diff_truncated` tells the island
/// not to show counts it cannot trust.
fn truncate_payload(payload: &mut serde_json::Value, event: &str) {
    let keeps_diff = event == "PostToolUse"
        && payload
            .get("tool_name")
            .and_then(|v| v.as_str())
            .is_some_and(|tool| DIFF_TOOLS.contains(&tool));
    let input = if keeps_diff {
        payload.as_object_mut().and_then(|map| map.remove("tool_input"))
    } else {
        None
    };

    truncate_strings(payload);

    if let Some(mut input) = input {
        let mut budget = MAX_DIFF_TOTAL;
        let mut cut_any = false;
        cap_diff_strings(&mut input, &mut budget, &mut cut_any);
        if let Some(map) = payload.as_object_mut() {
            map.insert("tool_input".into(), input);
            if cut_any {
                map.insert("coucou_diff_truncated".into(), serde_json::Value::Bool(true));
            }
        }
    }
}

/// `tool_input` of a diff tool: edit strings share MAX_DIFF_TOTAL, each capped at
/// MAX_DIFF_FIELD_LEN; any other string gets the ordinary cap.
fn cap_diff_strings(value: &mut serde_json::Value, budget: &mut usize, cut_any: &mut bool) {
    match value {
        serde_json::Value::Object(map) => {
            for (key, v) in map.iter_mut() {
                match v {
                    serde_json::Value::String(s) if DIFF_FIELDS.contains(&key.as_str()) => {
                        let limit = MAX_DIFF_FIELD_LEN.min(*budget);
                        if cut(s, limit) {
                            *cut_any = true;
                        }
                        *budget = budget.saturating_sub(s.len());
                    }
                    _ => cap_diff_strings(v, budget, cut_any),
                }
            }
        }
        serde_json::Value::Array(items) => {
            for item in items {
                cap_diff_strings(item, budget, cut_any);
            }
        }
        serde_json::Value::String(s) => {
            cut(s, MAX_FIELD_LEN);
        }
        _ => {}
    }
}

/// Caps every string in the payload. A single Write can carry a whole file.
fn truncate_strings(value: &mut Value) {
    match value {
        Value::String(s) => {
            cut(s, MAX_FIELD_LEN);
        }
        Value::Array(items) => items.iter_mut().for_each(truncate_strings),
        Value::Object(map) => map.values_mut().for_each(truncate_strings),
        _ => {}
    }
}

/// Shortens `s` to at most `max` bytes plus an ellipsis; true if it was cut.
fn cut(s: &mut String, max: usize) -> bool {
    if s.len() <= max {
        return false;
    }
    // Cut on a char boundary; a lone byte index can split UTF-8.
    let mut end = max;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    s.truncate(end);
    s.push('…');
    true
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

    fn run(raw: &str, agent: &str, event: &str) -> (Value, Event) {
        let args = Args { agent: agent.into(), event: event.into() };
        let ev = prepare(raw.as_bytes(), &args, &|_| None, "/home/me/here").expect("forwarded");
        let v = serde_json::from_str(ev.line.trim_end()).unwrap();
        (v, ev)
    }

    fn env_of(vars: &'static [(&'static str, &'static str)]) -> impl Fn(&str) -> Option<String> {
        move |name| vars.iter().find(|(k, _)| *k == name).map(|(_, v)| v.to_string())
    }

    #[test]
    fn claude_desktop_sessions_are_tagged_and_an_explicit_agent_wins() {
        let desktop = env_of(&[("CLAUDE_CODE_ENTRYPOINT", "claude-desktop")]);
        assert_eq!(agent_tag("", &desktop).as_deref(), Some("claude-desktop"));
        assert_eq!(agent_tag("gemini", &desktop).as_deref(), Some("gemini"));
        assert_eq!(agent_tag("", &env_of(&[("CLAUDE_CODE_ENTRYPOINT", "cli")])), None);
        assert_eq!(agent_tag("", &env_of(&[])), None);
    }

    #[test]
    fn cursor_is_told_apart_from_vs_code() {
        assert_eq!(term_editor(&env_of(&[("CURSOR_TRACE_ID", "abc")])), Some("cursor"));
        assert_eq!(
            term_editor(&env_of(&[(
                "VSCODE_GIT_ASKPASS_NODE",
                r"C:\Users\me\AppData\Local\Programs\cursor\Cursor.exe"
            )])),
            Some("cursor")
        );
        assert_eq!(
            term_editor(&env_of(&[(
                "VSCODE_GIT_ASKPASS_NODE",
                r"C:\Users\me\AppData\Local\Programs\Microsoft VS Code\Code.exe"
            )])),
            None
        );
        assert_eq!(term_editor(&env_of(&[("CURSOR_TRACE_ID", "")])), None);
        assert_eq!(term_editor(&env_of(&[("TERM_PROGRAM", "vscode")])), None);
    }

    #[test]
    fn long_strings_are_cut_on_a_char_boundary() {
        let mut v = serde_json::json!({ "tool_input": { "content": "é".repeat(4000) } });
        truncate_strings(&mut v);
        let s = v["tool_input"]["content"].as_str().unwrap();
        assert!(s.len() <= MAX_FIELD_LEN + 4);
        assert!(s.ends_with('…'));
    }

    #[test]
    fn claude_code_payloads_are_forwarded_as_they_are() {
        let (v, ev) = run(r#"{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"/p"}"#, "", "PreToolUse");
        assert_eq!(ev.name, "PreToolUse");
        assert!(v.get("coucou_agent").is_none());
        assert_eq!(v["cwd"], "/p");
        assert_eq!(v["tool_name"], "Bash");
    }

    #[test]
    fn an_agents_event_is_tagged_and_renamed() {
        // Gemini CLI: its own name in the payload, ours on the command line.
        let (v, ev) = run(r#"{"hook_event_name":"BeforeTool","toolCall":{"name":"shell","args":{"CommandLine":"ls"}}}"#, "gemini", "PreToolUse");
        assert_eq!(ev.name, "PreToolUse");
        assert_eq!(v["hook_event_name"], "PreToolUse");
        assert_eq!(v["coucou_agent"], "gemini");
        assert_eq!(v["tool_input"]["command"], "ls");
        assert_eq!(v["cwd"], "/home/me/here");

        // Copilot CLI sends no event name: the command line's camelCase one is used.
        let (_, ev) = run(r#"{"toolName":"bash"}"#, "copilot", "permissionRequest");
        assert_eq!(ev.name, "PermissionRequest");

        // Cursor: a stop that failed, and its tool output left behind.
        let (v, ev) = run(r#"{"hook_event_name":"stop","status":"error","tool_output":"huge"}"#, "cursor", "");
        assert_eq!(ev.name, "StopFailure");
        assert!(v.get("tool_output").is_none());
    }

    #[test]
    fn the_fix_loop_waits_only_where_it_may_answer() {
        let dir = std::env::temp_dir().join(format!("coucou-loop-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("Coucou")).unwrap();
        let marker = dir.join("Coucou").join("fix-loop.on");
        std::fs::write(&marker, b"1").unwrap();
        let local = dir.to_string_lossy().to_string();
        let env = move |k: &str| (k == "LOCALAPPDATA").then(|| local.clone());
        let waits = |raw: &str, agent: &str, event: &str| {
            let args = Args { agent: agent.into(), event: event.into() };
            let ev = prepare(raw.as_bytes(), &args, &env, "/x").unwrap();
            let v: Value = serde_json::from_str(ev.line.trim_end()).unwrap();
            assert_eq!(v.get("coucou_loop").is_some(), ev.loop_reply);
            ev.loop_reply
        };
        assert!(waits(r#"{"hook_event_name":"Stop"}"#, "", "Stop"));
        assert!(!waits(r#"{"hook_event_name":"Stop"}"#, "codex", "Stop"));
        assert!(waits(r#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m x"}}"#, "", "PreToolUse"));
        assert!(!waits(r#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}"#, "", "PreToolUse"));
        assert!(waits(r#"{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"npm test"},"tool_response":{"stdout":"ok"}}"#, "", "PostToolUse"));
        assert!(!waits(r#"{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"ls"},"tool_response":{"stdout":"ok"}}"#, "", "PostToolUse"));
        std::fs::remove_file(&marker).unwrap();
        assert!(!waits(r#"{"hook_event_name":"Stop"}"#, "", "Stop"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_test_commands_output_end_is_kept_and_no_other_output() {
        let raw = r#"{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"cd app && npm test"},"tool_response":{"stdout":"PASS a.test.js\nTests: 3 passed, 3 total","stderr":"","interrupted":false}}"#;
        let (v, _) = run(raw, "", "PostToolUse");
        assert!(v["coucou_test_output"].as_str().unwrap().contains("3 passed"));
        assert_eq!(v["coucou_test_failed"], false);
        assert!(v.get("tool_response").is_none());
        let raw = r#"{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"ls -la"},"tool_response":{"stdout":"secret.txt"}}"#;
        let (v, _) = run(raw, "", "PostToolUse");
        assert!(v.get("coucou_test_output").is_none());
        assert!(is_test_command("python -m pytest -q"));
        assert!(is_test_command("cargo test --release"));
        assert!(!is_test_command("git status"));
        assert!(!is_test_command("cat test.txt"));
    }

    #[test]
    fn a_question_is_kept_whole_and_only_for_ask_user_question() {
        let long = "x".repeat(3000);
        let raw = format!(r#"{{"hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{{"questions":[{{"question":"{long}"}}]}}}}"#);
        let (v, ev) = run(&raw, "", "");
        assert_eq!(ev.question.unwrap()["questions"][0]["question"].as_str().unwrap().len(), 3000);
        assert!(v["tool_input"]["questions"][0]["question"].as_str().unwrap().ends_with('…'));
        let (_, ev) = run(r#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}"#, "", "");
        assert!(ev.question.is_none());
    }

    #[test]
    fn what_cannot_be_read_is_not_forwarded() {
        let args = Args { agent: "copilot".into(), event: "preToolUse".into() };
        for raw in ["", "not json", "[1,2]"] {
            assert!(prepare(raw.as_bytes(), &args, &|_| None, "/").is_none());
        }
        // A BOM is not a reason to drop the event.
        let mut bom = vec![0xEF, 0xBB, 0xBF];
        bom.extend_from_slice(br#"{"hook_event_name":"Stop"}"#);
        assert!(prepare(&bom, &args, &|_| None, "/").is_some());
    }

    #[test]
    fn the_live_diff_rule_holds_through_the_normalised_relay() {
        let big = "z".repeat(10_000);
        // Claude Code's finished Edit: kept whole.
        let raw = format!(r#"{{"hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{{"old_string":"{big}","new_string":"a"}}}}"#);
        let (v, _) = run(&raw, "", "");
        assert_eq!(v["tool_input"]["old_string"].as_str().unwrap().len(), big.len());
        // The same edit before it happens, or an agent's event renamed onto
        // PreToolUse: the ordinary cap.
        let raw = format!(r#"{{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{{"old_string":"{big}"}}}}"#);
        let (v, _) = run(&raw, "", "");
        assert!(v["tool_input"]["old_string"].as_str().unwrap().len() <= MAX_FIELD_LEN + 4);
        let raw = format!(r#"{{"hook_event_name":"BeforeTool","tool_name":"Edit","tool_input":{{"content":"{big}"}}}}"#);
        let (v, ev) = run(&raw, "gemini", "");
        assert_eq!(ev.name, "PreToolUse");
        assert!(v["tool_input"]["content"].as_str().unwrap().len() <= MAX_FIELD_LEN + 4);
    }

    #[test]
    fn a_finished_edit_keeps_its_text_whole_for_the_live_diff() {
        let big = "line\n".repeat(4_000); // 20 KB, well past MAX_FIELD_LEN
        let mut v = serde_json::json!({
            "tool_name": "Edit",
            "tool_input": { "file_path": "/p/a.ts", "old_string": big, "new_string": big },
            "cwd": "x".repeat(4_000),
        });
        truncate_payload(&mut v, "PostToolUse");
        assert_eq!(v["tool_input"]["old_string"].as_str().unwrap().len(), big.len());
        assert_eq!(v["tool_input"]["new_string"].as_str().unwrap().len(), big.len());
        // Everything else keeps the ordinary cap, and nothing says "cut".
        assert!(v["cwd"].as_str().unwrap().len() <= MAX_FIELD_LEN + 4);
        assert!(v.get("coucou_diff_truncated").is_none());

        let mut multi = serde_json::json!({
            "tool_name": "MultiEdit",
            "tool_input": { "edits": [{ "old_string": big, "new_string": "x" }] },
        });
        truncate_payload(&mut multi, "PostToolUse");
        assert_eq!(multi["tool_input"]["edits"][0]["old_string"].as_str().unwrap().len(), big.len());
    }

    #[test]
    fn edits_are_still_capped_before_they_happen_and_for_other_tools() {
        let big = "é".repeat(4_000);
        for (event, tool) in [("PreToolUse", "Edit"), ("PermissionRequest", "Write"), ("PostToolUse", "Bash")] {
            let mut v = serde_json::json!({ "tool_name": tool, "tool_input": { "content": big } });
            truncate_payload(&mut v, event);
            assert!(v["tool_input"]["content"].as_str().unwrap().len() <= MAX_FIELD_LEN + 4, "{event} {tool}");
        }
    }

    #[test]
    fn an_edit_beyond_the_budget_is_cut_and_flagged() {
        let huge = "x".repeat(MAX_DIFF_FIELD_LEN + 10);
        let mut v = serde_json::json!({
            "tool_name": "Write",
            "tool_input": { "file_path": "/p/big.txt", "content": huge },
        });
        truncate_payload(&mut v, "PostToolUse");
        assert!(v["tool_input"]["content"].as_str().unwrap().len() <= MAX_DIFF_FIELD_LEN + 4);
        assert_eq!(v["coucou_diff_truncated"], serde_json::Value::Bool(true));

        // Together, the edit strings never pass the shared budget.
        let half = "y".repeat(MAX_DIFF_FIELD_LEN - 1);
        let edits: Vec<_> = (0..4)
            .map(|_| serde_json::json!({ "old_string": half, "new_string": half }))
            .collect();
        let mut multi = serde_json::json!({ "tool_name": "MultiEdit", "tool_input": { "edits": edits } });
        truncate_payload(&mut multi, "PostToolUse");
        assert!(multi.to_string().len() < MAX_DIFF_TOTAL + 64 * 1024);
        assert_eq!(multi["coucou_diff_truncated"], serde_json::Value::Bool(true));
    }
}
