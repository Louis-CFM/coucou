// Task mode — the chat hands a task to Claude Code itself: `claude -p`, run
// headlessly in a project folder the user picked, with no terminal anywhere.
// The spawned session reaches the island through the installed hooks like any
// other — the pill, its steps, the diffs and the approval cards all come from
// that path. Here we only start the process, keep hold of it so it can be
// cancelled, and hand its final answer back to the chat, which renders it as
// Markdown. The stream is read for two lines only: `init` (the session id)
// and `result` (the answer) — the hook Stop event truncates at 2 KB, so the
// answer must come from stdout.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::Serialize;
use serde_json::Value;
use tauri::{AppHandle, Emitter, Manager};

use crate::island;
use crate::platform;

/// A task may run for a long while, its approvals included; past this it is
/// presumed stuck and ended.
const TASK_TIMEOUT: Duration = Duration::from_secs(30 * 60);
/// One stream-json line we are willing to read — the whole answer rides in one.
const MAX_LINE: usize = 8 * 1024 * 1024;
/// Tasks running at once. The island gets crowded well before this.
const MAX_RUNNING: usize = 3;
/// The stderr kept for the message shown when claude dies without an answer.
const STDERR_TAIL: usize = 2048;

/// What every task is told besides the task itself: route the work, answer in
/// Markdown, and deliver reports as Typst files rather than Markdown.
const CHARTER: &str = "You were started from Coucou's task box, not a terminal: \
the user reads only your final message, in a small chat card, and follows the \
rest from Coucou's island. Route the work to the most suitable of the available \
subagents and skills. Write every answer and summary as plain Markdown. When \
the deliverable is a report or a document, do not deliver it as Markdown: write \
a Typst file under reports/ in the project (create the folder if needed), and \
compile it with `typst compile` when the typst CLI is installed. Keep the final \
message short: what was done, what changed, and where any files landed.";

#[derive(Default)]
pub struct Tasks {
    /// The running tasks, by id, so Cancel and the watchdog can end them.
    running: Mutex<HashMap<u64, Arc<Mutex<Child>>>>,
    next: AtomicU64,
}

/// `task-result` — a task's final answer, already Markdown.
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskResult {
    pub task_id: u64,
    pub ok: bool,
    pub text: String,
}

/// `task-started` — the task found its Claude Code session; its pill in the
/// island carries the same session id.
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct TaskStarted {
    task_id: u64,
    session_id: String,
}

/// Starts `claude -p <prompt>` in `dir` and returns the task id right away.
/// The answer comes later, as a `task-result` event to the island. A
/// follow-up passes the session id of an earlier task: `--resume` then
/// continues that conversation instead of opening a new one.
pub fn spawn(
    app: AppHandle,
    tasks: &Tasks,
    prompt: String,
    dir: String,
    resume: Option<String>,
    outputs: Option<String>,
) -> Result<u64, String> {
    let dir = PathBuf::from(dir);
    if !dir.is_absolute() || !dir.is_dir() {
        return Err("That project folder does not exist.".into());
    }
    // Settings → Task outputs: answers and reports also land there (Obsidian…).
    let outputs = outputs
        .map(PathBuf::from)
        .filter(|p| p.is_absolute() && (p.is_dir() || std::fs::create_dir_all(p).is_ok()));
    if let Some(session) = resume.as_deref() {
        if !is_session_id(session) {
            return Err("That task can no longer be followed up.".into());
        }
    }
    if tasks.running.lock().unwrap().len() >= MAX_RUNNING {
        return Err("Three tasks are already running — let one finish first.".into());
    }
    let exe = platform::claude_candidates()
        .into_iter()
        .next()
        .ok_or("Claude Code was not found. Install the claude CLI, then try again.")?;

    let charter = match outputs.as_deref() {
        Some(out) => format!(
            "{CHARTER} Deliver the Typst reports into {} instead of reports/.",
            out.display()
        ),
        None => CHARTER.to_string(),
    };
    let mut cmd = Command::new(&exe);
    cmd.args([
        "-p",
        &prompt,
        "--output-format",
        "stream-json",
        "--verbose",
        "--append-system-prompt",
        &charter,
    ]);
    if let Some(out) = outputs.as_deref() {
        cmd.arg("--add-dir").arg(out);
    }
    if let Some(session) = resume.as_deref() {
        cmd.args(["--resume", session]);
    }
    cmd.current_dir(&dir)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    // An npm install is a `#!/usr/bin/env node` script (or a .cmd calling
    // node): its own folder first on PATH, so it finds its Node (codex_plan.rs).
    if let Some(parent) = exe.parent() {
        let mut dirs = vec![parent.to_path_buf()];
        if let Some(path) = std::env::var_os("PATH") {
            dirs.extend(std::env::split_paths(&path));
        }
        if let Ok(joined) = std::env::join_paths(dirs) {
            cmd.env("PATH", joined);
        }
    }
    platform::no_console(&mut cmd);
    let mut child = cmd
        .spawn()
        .map_err(|err| format!("claude could not start: {err}"))?;

    let stdout = child
        .stdout
        .take()
        .ok_or("claude could not start: no output")?;
    let stderr = child.stderr.take();
    let task_id = tasks.next.fetch_add(1, Ordering::Relaxed) + 1;
    let child = Arc::new(Mutex::new(child));
    tasks.running.lock().unwrap().insert(task_id, child.clone());

    // stderr drained so its pipe can never fill, the tail kept for the message
    // shown when claude ends without an answer (not signed in, an old CLI…).
    let tail = Arc::new(Mutex::new(Vec::new()));
    if let Some(stderr) = stderr {
        let tail = tail.clone();
        std::thread::spawn(move || {
            let mut reader = BufReader::new(stderr);
            let mut buf = [0u8; 1024];
            while let Ok(n) = reader.read(&mut buf) {
                if n == 0 {
                    break;
                }
                let mut kept = tail.lock().unwrap();
                kept.extend_from_slice(&buf[..n]);
                let overflow = kept.len().saturating_sub(STDERR_TAIL);
                if overflow > 0 {
                    kept.drain(..overflow);
                }
            }
        });
    }

    // The watchdog ends a task that outlives any reasonable run.
    {
        let app = app.clone();
        let child = child.clone();
        std::thread::spawn(move || {
            std::thread::sleep(TASK_TIMEOUT);
            finish(
                &app,
                task_id,
                &child,
                false,
                "The task ran for half an hour and was ended.".into(),
            );
        });
    }

    // The reader follows the stream-json lines to the final result.
    std::thread::spawn(move || {
        let mut reader = BufReader::new(stdout);
        let mut line = Vec::new();
        let mut outcome: Option<(bool, String)> = None;
        loop {
            line.clear();
            let n = match (&mut reader)
                .take(MAX_LINE as u64 + 1)
                .read_until(b'\n', &mut line)
            {
                Ok(n) => n,
                Err(_) => break,
            };
            if n == 0 || line.len() > MAX_LINE {
                break;
            }
            let Ok(message) = serde_json::from_slice::<Value>(&line) else {
                continue;
            };
            match message.get("type").and_then(Value::as_str) {
                Some("system") => {
                    if message.get("subtype").and_then(Value::as_str) == Some("init") {
                        if let Some(session) = message.get("session_id").and_then(Value::as_str) {
                            let _ = app.emit_to(
                                island::WINDOW_LABEL,
                                "task-started",
                                TaskStarted {
                                    task_id,
                                    session_id: session.to_string(),
                                },
                            );
                        }
                    }
                }
                Some("result") => {
                    let error = message
                        .get("is_error")
                        .and_then(Value::as_bool)
                        .unwrap_or(false);
                    let text = message
                        .get("result")
                        .and_then(Value::as_str)
                        .map(str::to_string)
                        .filter(|t| !t.trim().is_empty())
                        .unwrap_or_else(|| {
                            if error {
                                "The task failed without a message.".to_string()
                            } else {
                                "Done.".to_string()
                            }
                        });
                    outcome = Some((!error, text));
                    break;
                }
                _ => {}
            }
        }
        let (ok, text) = outcome.unwrap_or_else(|| {
            let kept = tail.lock().unwrap();
            let tail = String::from_utf8_lossy(&kept).trim().to_string();
            let text = if tail.is_empty() {
                "The task ended without an answer.".to_string()
            } else {
                format!("The task ended without an answer:\n\n```\n{tail}\n```")
            };
            (false, text)
        });
        // The answer also lands in the outputs folder as a Markdown note.
        let text = match (ok, outputs.as_deref()) {
            (true, Some(out)) => match save_note(out, &prompt, &dir, &text) {
                Some(path) => format!("{text}\n\n*Saved to {}*", path.display()),
                None => text,
            },
            _ => text,
        };
        finish(&app, task_id, &child, ok, text);
    });
    Ok(task_id)
}

/// A finished task's answer, saved into the outputs folder (Settings → Task
/// outputs) as an Obsidian-friendly note: "2026-10-09 153412 fix-the-tests.md".
fn save_note(out: &Path, prompt: &str, project: &Path, text: &str) -> Option<PathBuf> {
    let t = crate::platform::local_time();
    let slug: String = prompt
        .to_lowercase()
        .chars()
        .map(|c| if c.is_alphanumeric() { c } else { '-' })
        .collect::<String>()
        .split('-')
        .filter(|p| !p.is_empty())
        .collect::<Vec<_>>()
        .join("-")
        .chars()
        .take(40)
        .collect();
    let name = format!(
        "{:04}-{:02}-{:02} {:02}{:02}{:02} {slug}.md",
        t.year, t.month, t.day, t.hour, t.minute, t.second
    );
    let title: String = prompt
        .lines()
        .next()
        .unwrap_or("")
        .chars()
        .take(120)
        .collect();
    let note = format!(
        "---\ntask: \"{}\"\nproject: {}\ndate: {:04}-{:02}-{:02} {:02}:{:02}\n---\n\n{}\n",
        title.replace('"', "'"),
        project.display(),
        t.year,
        t.month,
        t.day,
        t.hour,
        t.minute,
        text
    );
    let path = out.join(name);
    std::fs::write(&path, note).ok()?;
    Some(path)
}

/// What `--resume` accepts: the session ids Claude Code mints (UUID-like,
/// hex and dashes). Anything else never reaches the command line.
fn is_session_id(session: &str) -> bool {
    (8..=64).contains(&session.len()) && session.chars().all(|c| c.is_ascii_hexdigit() || c == '-')
}

/// The folder button on a finished task's bubble: opens the project's
/// reports/ folder when the task wrote one, else the project itself.
pub fn reveal(dir: &str) {
    let dir = PathBuf::from(dir);
    if !dir.is_absolute() || !dir.is_dir() {
        return;
    }
    let reports = dir.join("reports");
    let shown = if reports.is_dir() { reports } else { dir };
    platform::reveal_folder(&shown.to_string_lossy());
}

/// Cancel, from the ✕ on the task's chat bubble.
pub fn cancel(app: &AppHandle, task_id: u64) {
    let child = {
        let tasks = app.state::<Tasks>();
        let running = tasks.running.lock().unwrap();
        running.get(&task_id).cloned()
    };
    if let Some(child) = child {
        finish(app, task_id, &child, false, "Cancelled.".into());
    }
}

/// The projects root as a path: the home folder until one is picked.
fn resolve_root(root: &str) -> PathBuf {
    match root.trim() {
        "" => platform::home_dir(),
        picked => PathBuf::from(picked),
    }
}

/// The folders the chat's Task mode offers: the projects root picked in
/// Settings (the home folder until one is picked), then its subfolders.
pub fn projects(root: &str) -> Vec<String> {
    let root = resolve_root(root);
    if !root.is_absolute() || !root.is_dir() {
        return Vec::new();
    }
    let mut out = vec![root.to_string_lossy().to_string()];
    if let Ok(entries) = std::fs::read_dir(&root) {
        let mut dirs: Vec<String> = entries
            .filter_map(|entry| {
                let entry = entry.ok()?;
                let name = entry.file_name().into_string().ok()?;
                if name.starts_with('.') {
                    return None;
                }
                entry
                    .file_type()
                    .ok()?
                    .is_dir()
                    .then(|| entry.path().to_string_lossy().to_string())
            })
            .collect();
        dirs.sort_by_key(|path| path.to_lowercase());
        out.extend(dirs);
    }
    out
}

/// The one way a task ends. Whoever takes it out of the running map reports
/// it; everyone else stays silent — the reader, the watchdog and Cancel can
/// all race here, and the chat must hear exactly one answer.
fn finish(app: &AppHandle, task_id: u64, child: &Arc<Mutex<Child>>, ok: bool, text: String) {
    {
        let tasks = app.state::<Tasks>();
        let mut running = tasks.running.lock().unwrap();
        if running.remove(&task_id).is_none() {
            return;
        }
    }
    kill_tree(child);
    let _ = app.emit_to(
        island::WINDOW_LABEL,
        "task-result",
        TaskResult { task_id, ok, text },
    );
}

/// Ends the whole tree: an npm install runs `claude.cmd`, and killing cmd.exe
/// alone would leave node running under it (codex_plan.rs does the same).
fn kill_tree(child: &Arc<Mutex<Child>>) {
    let mut child = child.lock().unwrap();
    #[cfg(windows)]
    {
        let mut kill = Command::new("taskkill");
        kill.args(["/T", "/F", "/PID", &child.id().to_string()]);
        platform::no_console(&mut kill);
        let _ = kill.status();
    }
    let _ = child.kill();
    let _ = child.wait();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("coucou-tasks-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn the_root_comes_first_then_its_visible_subfolders_sorted() {
        let dir = scratch("projects");
        for sub in ["shop", "Blog", ".git"] {
            std::fs::create_dir(dir.join(sub)).unwrap();
        }
        std::fs::write(dir.join("notes.md"), "not a folder").unwrap();
        let listed = projects(&dir.to_string_lossy());
        let names: Vec<String> = listed
            .iter()
            .map(|p| {
                PathBuf::from(p)
                    .file_name()
                    .unwrap()
                    .to_string_lossy()
                    .to_string()
            })
            .collect();
        assert_eq!(names[0], dir.file_name().unwrap().to_string_lossy());
        assert_eq!(&names[1..], ["Blog", "shop"]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_root_that_is_not_a_folder_offers_nothing() {
        assert!(projects("/nowhere/at/all").is_empty());
        assert!(projects("relative/path").is_empty());
    }

    #[test]
    fn only_a_claude_session_id_may_ride_a_resume() {
        assert!(is_session_id("ba748b2f-969b-4062-aa70-94d523486b4d"));
        assert!(!is_session_id("../../etc/passwd"));
        assert!(!is_session_id("--dangerously-skip-permissions"));
        assert!(!is_session_id("short"));
        assert!(!is_session_id(&"a".repeat(65)));
    }

    #[test]
    fn a_blank_root_means_the_home_folder_and_a_typed_one_is_trimmed() {
        // Only the mapping is tested here: a hooks.rs test moves $HOME around,
        // so nothing may assume the real home folder exists during the run.
        assert_eq!(resolve_root("  "), platform::home_dir());
        assert_eq!(resolve_root(" /x/y "), PathBuf::from("/x/y"));
    }
}
