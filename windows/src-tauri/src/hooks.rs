// Claude Code hook installation.
//
// The rule from CLAUDE.md is strict and is followed to the letter:
// read %USERPROFILE%\.claude\settings.json, take a dated backup, merge without
// touching anybody else's hooks, show the diff, and write only after an explicit
// click. Uninstall removes Coucou's entries and nothing else.
//
// The command is only the quoted exe path in forward slashes plus the event name:
// on Windows Claude Code runs hook commands through Git Bash, and anything with
// PowerShell or cmd in it breaks.

use std::path::{Path, PathBuf};

use crate::{platform, settings};
use serde::Serialize;
use serde_json::{json, Map, Value};
use tauri::{AppHandle, Manager};

/// Every event the island reacts to, with the hook timeout written to settings.json.
/// PermissionRequest waits for a human, so it gets the decision timeout + 10 s.
pub const HOOK_EVENTS: &[(&str, u64)] = &[
    ("SessionStart", 10),
    ("SessionEnd", 10),
    ("UserPromptSubmit", 10),
    ("PreToolUse", 10),
    ("PostToolUse", 10),
    ("PostToolUseFailure", 10),
    ("PermissionRequest", 120),
    ("Notification", 10),
    ("Stop", 10),
    ("StopFailure", 10),
    ("SubagentStart", 10),
    ("SubagentStop", 10),
];

/// Copilot CLI speaks the Claude event names, but not every one of them.
const COPILOT_HOOK_EVENTS: &[(&str, u64)] = &[
    ("SessionStart", 10),
    ("SessionEnd", 10),
    ("UserPromptSubmit", 10),
    ("PreToolUse", 10),
    ("PostToolUse", 10),
    ("PostToolUseFailure", 10),
    ("PermissionRequest", 120),
    ("Stop", 10),
];

/// Antigravity (agy) wraps the tool events in its own invocation names.
const ANTIGRAVITY_HOOK_EVENTS: &[(&str, u64)] = &[
    ("PreInvocation", 10),
    ("PreToolUse", 10),
    ("PostToolUse", 10),
    ("PostInvocation", 10),
    ("Stop", 10),
];

/// Gemini/agy builds that still emit the legacy lifecycle names. They are routed
/// to the same agent pill so a session is never half-tracked.
const ANTIGRAVITY_LIFECYCLE_EVENTS: &[(&str, u64)] = &[
    ("SessionStart", 10),
    ("SessionEnd", 10),
    ("UserPromptSubmit", 10),
    ("Stop", 10),
];

/// Marker that identifies a Coucou entry inside an agent's settings file.
const MARKER: &str = "coucou-hook";

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HookStatus {
    pub installed: bool,
    /// Whether this is Coucou's own file, and so Coucou may update or remove it.
    ///
    /// False means something else is there — most likely a Pi extension you have
    /// edited yourself. Coucou will not overwrite or delete it, because silently
    /// replacing a working hook with a built-in one loses work nobody can get
    /// back. The UI says so instead of offering a destructive button.
    pub managed: bool,
    pub settings_path: String,
    pub hook_path: String,
    pub hook_ready: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HookPreview {
    pub diff: String,
    pub backup: String,
    pub settings_path: String,
    /// Identifies the bytes this diff was computed from; handed back to `write`
    /// so we only ever apply what the user actually looked at.
    pub fingerprint: String,
}

/// Where each agent keeps its hook configuration. "claudeCode" — and anything
/// unknown — falls back to `~/.claude/settings.json`.
pub fn settings_path_for_agent(agent: &str) -> PathBuf {
    match agent {
        "pi" => platform::home_dir()
            .join(".pi")
            .join("agent")
            .join("settings.json"),
        "copilot" => platform::home_dir()
            .join(".copilot")
            .join("hooks")
            .join("coucou.json"),
        "antigravity" => platform::home_dir()
            .join(".gemini")
            .join("config")
            .join("hooks.json"),
        "codex" => platform::home_dir()
            .join(".codex")
            .join("hooks")
            .join("hooks.json"),
        _ => platform::home_dir().join(".claude").join("settings.json"),
    }
}

/// Reads an agent's settings file.
///
/// The only error that means "start from nothing" is the file not being there.
/// Everything else — a lock held by another process, a permission problem, JSON
/// we cannot parse — is reported, because the alternative is treating somebody's
/// unreadable settings as an empty object and then writing that back over them.
fn read_settings(agent: &str) -> Result<Value, String> {
    let path = settings_path_for_agent(agent);
    match std::fs::read(&path) {
        Ok(bytes) => parse_settings(&bytes, &path.display().to_string()),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(json!({})),
        // A lock, a permission problem, a bad drive: all of them mean we do not
        // know what is in there, and not knowing is not the same as empty.
        Err(err) => Err(format!("Can't read {}: {err}", path.display())),
    }
}

/// The parsing half of `read_settings`, split out so it can be tested without a
/// home directory.
fn parse_settings(bytes: &[u8], path: &str) -> Result<Value, String> {
    // PowerShell writes a UTF-8 BOM with `Set-Content -Encoding utf8`, and
    // serde_json refuses it. Stripping it is safe and well defined; guessing at
    // anything else is not.
    let text = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(bytes);
    if text.iter().all(u8::is_ascii_whitespace) {
        return Ok(json!({}));
    }
    match serde_json::from_slice::<Value>(text) {
        Ok(v) if v.is_object() => Ok(v),
        Ok(_) => Err(format!("{path} isn't a JSON object — Coucou won't touch it.")),
        Err(err) => Err(format!(
            "{path} isn't valid JSON ({err}). Fix or move it, then try again — Coucou won't overwrite it."
        )),
    }
}

/// The settings as they are, or an empty object when we cannot tell. Only for
/// read-only paths like `status()`, which must never fail loudly; anything that
/// writes uses `read_settings()` and surfaces the error instead.
fn read_settings_lossy(agent: &str) -> Value {
    read_settings(agent).unwrap_or_else(|_| json!({}))
}

/// The `--agent <name>` tag is what routes an event to the right pill, so every
/// command carries one. A Claude Code hook installed by an older build simply
/// has no tag and lands on the Claude pill unchanged.
#[cfg(windows)]
fn hook_command(agent: &str, event: &str) -> String {
    let exe = settings::hook_exe_path()
        .to_string_lossy()
        .replace('\\', "/");
    format!("\"{exe}\" --agent {agent} {event}")
}

/// Claude Code runs the command through `sh`, which still reads `$`, `` ` ``
/// and `\` inside double quotes. Single quotes keep the path a path, whatever
/// the home directory is called.
#[cfg(unix)]
fn hook_command(agent: &str, event: &str) -> String {
    format!(
        "{} --agent {agent} {event}",
        sh_quote(&settings::hook_exe_path().to_string_lossy())
    )
}

/// `s` as one single-quoted shell word: `'` becomes `'\''`, nothing else is
/// special inside single quotes.
#[cfg(unix)]
fn sh_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

/// True for any entry Coucou wrote, in either the Claude shape
/// (`hooks[].command`) or the Copilot shape (a flat `exec`).
fn entry_is_ours(entry: &Value) -> bool {
    let command_match = entry
        .get("hooks")
        .and_then(Value::as_array)
        .map(|hooks| {
            hooks.iter().any(|h| {
                h.get("command")
                    .and_then(Value::as_str)
                    .map(|c| c.contains(MARKER))
                    .unwrap_or(false)
            })
        })
        .unwrap_or(false);
    let exec_match = entry
        .get("exec")
        .and_then(Value::as_str)
        .map(|exec| exec.contains(MARKER))
        .unwrap_or(false);
    command_match || exec_match
}

// ── Copilot CLI ───────────────────────────────────────────────────────────────

/// Copilot's config is a flat object rather than a matcher block, so its entries
/// carry `exec` / `args` / `timeoutSec` directly instead of nesting a command.
fn copilot_entry(agent: &str, event: &str, timeout: u64) -> Value {
    json!({
        "type": "command",
        "exec": settings::hook_exe_path().to_string_lossy(),
        "args": ["--agent", agent, event],
        "timeoutSec": timeout,
    })
}

fn copilot_merged(existing: &Value) -> Value {
    let mut root = existing.as_object().cloned().unwrap_or_default();
    let mut hooks = root
        .get("hooks")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_else(Map::new);

    for (event, timeout) in COPILOT_HOOK_EVENTS {
        let mut list = hooks
            .get(*event)
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        list.retain(|entry| !entry_is_ours(entry));
        list.push(copilot_entry("copilot", event, *timeout));
        hooks.insert((*event).to_string(), Value::Array(list));
    }

    root.insert("version".into(), json!(1));
    root.insert("hooks".into(), Value::Object(hooks));
    Value::Object(root)
}

fn copilot_without_ours(existing: &Value) -> Value {
    let mut root = existing.as_object().cloned().unwrap_or_default();
    let Some(hooks) = root.get("hooks").and_then(Value::as_object).cloned() else {
        return Value::Object(root);
    };
    let mut out = Map::new();
    for (event, value) in hooks {
        match value.as_array() {
            Some(list) => {
                let kept: Vec<Value> = list
                    .iter()
                    .filter(|entry| !entry_is_ours(entry))
                    .cloned()
                    .collect();
                if !kept.is_empty() {
                    out.insert(event, Value::Array(kept));
                }
            }
            None => {
                out.insert(event, value);
            }
        }
    }
    if out.is_empty() {
        root.remove("hooks");
    } else {
        root.insert("hooks".into(), Value::Object(out));
    }
    Value::Object(root)
}

// ── Antigravity ───────────────────────────────────────────────────────────────

/// Codex nests its hooks the same way Claude Code and Antigravity do, so the
/// matcher shape carries over and only the event names differ. Matches the set
/// the macOS app installs, so one agent behaves the same on both platforms.
const CODEX_HOOK_EVENTS: &[(&str, u64)] = &[
    ("SessionStart", 10),
    ("UserPromptSubmit", 10),
    ("PreToolUse", 10),
    ("PermissionRequest", 120),
    ("PostToolUse", 10),
    ("Stop", 10),
    ("SubagentStop", 10),
    ("SessionEnd", 3),
];

/// The matcher-map merge shared by every agent that nests its hooks.
fn matcher_merged(agent: &str, existing: &Value, events: &[(&str, u64)]) -> Value {
    let cleaned = without_ours(agent, existing);
    let mut root = cleaned.as_object().cloned().unwrap_or_default();
    let mut hooks = root
        .get("hooks")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_else(Map::new);

    for (event, timeout) in events {
        let mut list = hooks
            .get(*event)
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        list.retain(|entry| !entry_is_ours(entry));
        list.push(json!({
            "hooks": [{
                "type": "command",
                "command": hook_command(agent, event),
                "timeout": timeout,
            }]
        }));
        hooks.insert((*event).to_string(), Value::Array(list));
    }

    root.insert("hooks".into(), Value::Object(hooks));
    Value::Object(root)
}

fn codex_merged(existing: &Value) -> Value {
    matcher_merged("codex", existing, CODEX_HOOK_EVENTS)
}

/// Antigravity nests its hooks like Claude Code does, so the same matcher shape
/// works; only the event names differ.
fn antigravity_merged(existing: &Value) -> Value {
    let mut events: Vec<(&str, u64)> = ANTIGRAVITY_HOOK_EVENTS
        .iter()
        .chain(ANTIGRAVITY_LIFECYCLE_EVENTS.iter())
        .copied()
        .collect();
    events.dedup();
    matcher_merged("antigravity", existing, &events)
}

// ── Claude Code / Pi ──────────────────────────────────────────────────────────

/// Settings with Coucou's hooks added; everything else is left untouched.
fn merged(agent: &str, existing: &Value) -> Value {
    let mut root = existing.as_object().cloned().unwrap_or_default();
    let mut hooks = root
        .get("hooks")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_else(Map::new);

    for (event, timeout) in HOOK_EVENTS {
        let mut list = hooks
            .get(*event)
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        list.retain(|entry| !entry_is_ours(entry));
        list.push(json!({
            "hooks": [{
                "type": "command",
                "command": hook_command(agent, event),
                "timeout": timeout,
            }]
        }));
        hooks.insert((*event).to_string(), Value::Array(list));
    }

    root.insert("hooks".into(), Value::Object(hooks));
    Value::Object(root)
}

/// Settings with every Coucou entry removed, and nothing else changed.
fn without_ours(_agent: &str, existing: &Value) -> Value {
    let mut root = existing.as_object().cloned().unwrap_or_default();
    let Some(hooks) = root.get("hooks").and_then(Value::as_object).cloned() else {
        return Value::Object(root);
    };
    let mut out = Map::new();
    for (event, value) in hooks {
        match value.as_array() {
            Some(list) => {
                let kept: Vec<Value> = list.iter().filter(|e| !entry_is_ours(e)).cloned().collect();
                if !kept.is_empty() {
                    out.insert(event, Value::Array(kept));
                }
            }
            None => {
                out.insert(event, value);
            }
        }
    }
    if out.is_empty() {
        root.remove("hooks");
    } else {
        root.insert("hooks".into(), Value::Object(out));
    }
    Value::Object(root)
}

fn pretty(v: &Value) -> String {
    serde_json::to_string_pretty(v).unwrap_or_default()
}

/// Down to the second: installing then uninstalling in the same minute must not
/// quietly overwrite the first backup.
fn stamp() -> String {
    let t = platform::local_time();
    format!(
        "{:04}{:02}{:02}-{:02}{:02}{:02}",
        t.year, t.month, t.day, t.hour, t.minute, t.second
    )
}

fn backup_path(agent: &str) -> PathBuf {
    let p = settings_path_for_agent(agent);
    p.with_file_name(format!("settings.json.bak-{}", stamp()))
}

/// Identifies the exact bytes a preview was computed from. FNV-1a is plenty:
/// the question is only "is this still the file I showed the user?".
fn fingerprint(bytes: &[u8]) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for b in bytes {
        hash ^= *b as u64;
        hash = hash.wrapping_mul(0x1000_0000_01b3);
    }
    format!("{hash:016x}")
}

fn current_fingerprint(agent: &str) -> String {
    match std::fs::read(settings_path_for_agent(agent)) {
        Ok(bytes) => fingerprint(&bytes),
        Err(_) => fingerprint(b""),
    }
}

// ── Pi ────────────────────────────────────────────────────────────────────────

/// Pi loads TypeScript extensions rather than a settings.json hook map, so for
/// Pi "install" means writing one extension file and "uninstall" means removing
/// it. Nothing of the user's is in that file, so there is nothing to merge with.
/// The extension source with the relay's real path substituted in.
///
/// JSON-escaped, because a Windows path is mostly backslashes and an unescaped
/// one would not survive being a JavaScript string literal.
pub fn pi_extension_code() -> String {
    let path = settings::hook_exe_path().to_string_lossy().to_string();
    let literal = Value::String(path).to_string();
    PI_EXTENSION_CODE.replace("__COUCOU_HOOK_EXE__", &literal)
}

pub fn pi_extension_path() -> PathBuf {
    platform::home_dir()
        .join(".pi")
        .join("agent")
        .join("extensions")
        .join("coucou.ts")
}

pub const PI_EXTENSION_CODE: &str = r#"// Coucou hook relay extension for Pi (pi.dev)
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";

// Replaced with the relay path Rust actually resolved before this file is
// written. Guessing it from the home directory would miss a redirected
// LOCALAPPDATA, and a Pi extension pointing at a relay that is not there fails
// silently — the session simply never reaches the island.
const HOOK_EXE = __COUCOU_HOOK_EXE__;

// Fire-and-forget for normal events (non-blocking)
function sendHook(eventName: string, data: Record<string, any> = {}): void {
  const payload = JSON.stringify({ hook_event_name: eventName, ...data });
  try {
    const proc = spawn(HOOK_EXE, ["--agent", "pi", eventName], {
      stdio: ["pipe", "ignore", "ignore"],
      timeout: 2000,
    });
    proc.stdin?.write(payload + "\n", () => {
      if (proc.stdin) proc.stdin.end();
    });
    proc.on("error", () => {});
    setTimeout(() => { try { proc.kill(); } catch {} }, 2000);
  } catch {}
}

export default function coucouExtension(pi: ExtensionAPI) {
  // Session lifecycle
  pi.on("session_start", (_event, ctx) => {
    sendHook("SessionStart", { reason: (ctx as any)?.reason });
  });

  pi.on("session_shutdown", () => {
    sendHook("SessionEnd", {});
  });

  // User prompt submission
  pi.on("before_agent_start", (event) => {
    // `prompt` is the field; there is no `text`. Asking for `text` sent
    // undefined, so the island ticker showed nothing for every prompt.
    sendHook("UserPromptSubmit", { text: event.prompt });
  });

  // Generation phase indicator (typing/working pill)
  pi.on("turn_start", () => {
    sendHook("PreToolUse", { tool_name: "generating" });
  });

  // Debounced keep-alive during streaming (~1 update per 500ms)
  let keepAliveTimer: ReturnType<typeof setTimeout> | null = null;
  pi.on("message_update", () => {
    if (keepAliveTimer) clearTimeout(keepAliveTimer);
    keepAliveTimer = setTimeout(() => {
      sendHook("PostToolUse", { tool_name: "generating", result: { note: "streaming…" } });
      keepAliveTimer = null;
    }, 500);
  });

  // Tool execution hooks
  pi.on("tool_execution_start", (event) => {
    sendHook("PreToolUse", { tool_name: event.toolName, tool_input: event.args });
  });

  pi.on("tool_execution_end", (event) => {
    const payload: Record<string, any> = { tool_name: event.toolName };
    if (event.result !== undefined) payload.result = event.result;
    if (event.isError) {
      sendHook("PostToolUseFailure", payload);
    } else {
      sendHook("PostToolUse", payload);
    }
  });

  pi.on("turn_end", () => {
    sendHook("PostToolUse", { tool_name: "turn_complete" });
  });

  // Agent settled — summary + stop
  pi.on("agent_settled", (_event, ctx) => {
    const entries = ctx.sessionManager.getEntries();
    const toolCalls: string[] = [];
    for (const entry of entries) {
      if (entry.type === "message" && entry.message?.role === "assistant") {
        const content = entry.message.content;
        if (Array.isArray(content)) {
          for (const block of content) {
            if (block.type === "toolCall" && typeof block.name === "string") {
              toolCalls.push(block.name);
            }
          }
        }
      }
    }
    const summary = toolCalls.length > 0
      ? `${toolCalls.length} tool call(s): ${[...new Set(toolCalls)].join(", ")}`
      : "No tools used";
    sendHook("PostToolUse", { tool_name: "summary", tool_input: { note: summary } });
    setTimeout(() => sendHook("Stop", {}), 500);
  });

  // ── Permissions ───────────────────────────────────────────────────────────
  //
  // Deliberately empty, and that is load-bearing rather than an omission.
  //
  // Permission decisions belong to Pi's own permission extension. It asks Coucou
  // through its own forwarding path and falls back to Pi's dialog when Coucou
  // cannot answer, so asking from here as well would produce two cards and two
  // answers for one decision.
  //
  // This extension used to ask from a tool_call handler, and it did so badly in
  // two ways worth recording:
  //
  //   1. It waited 800ms for a human to notice a card and click Allow. Nobody
  //      does that in 800ms, so nearly every request fell through to Pi while the
  //      Coucou card sat there unanswered. Coucou looked broken exactly when it
  //      was working, which is the hardest kind of bug to notice.
  //   2. It returned { block: true } when ctx.hasUI was false, denying every
  //      bash, write and edit in print and JSON mode — a decision with nothing to
  //      do with the call being made.
  //
  // Everything else Coucou shows — sessions, tool calls, completion — is still
  // reported from here. Only permissions are somebody else's job.
}"#;

/// The fingerprint of the extension file as it is right now; empty when absent.
fn fingerprint_of_body() -> String {
    pi_extension_body()
        .map(|b| fingerprint(b.as_bytes()))
        .unwrap_or_default()
}

/// The extension on disk, if there is one.
fn pi_extension_body() -> Option<String> {
    std::fs::read_to_string(pi_extension_path()).ok()
}

/// The stable signature that marks an extension as Coucou's.
///
/// Byte-equality with what Coucou generates cannot be the ownership test. The
/// relay path is substituted per-machine, and the file has been corrected by
/// hand as the integration matured, so the generated bytes drift away from what
/// is installed while the file is still plainly Coucou's. Testing for that drift
/// meant a working extension was reported as a stranger's, install and uninstall
/// were both permanently refused, and the reason given named the wrong file.
///
/// Every Coucou extension must name the relay to work at all, and no unrelated
/// Pi extension has any reason to. That is the signature worth testing for.
const PI_EXTENSION_SIGNATURE: &str = "coucou-hook";

/// True when the file at the extension path is Coucou's to manage.
///
/// The safety property this keeps is the one that matters: an extension Coucou
/// did not write is never overwritten on install and never deleted on uninstall,
/// whatever the button says. That still holds — a hand-written extension of your
/// own carries no relay reference, so it is not ours and is left alone.
fn pi_extension_is_ours() -> bool {
    let Some(body) = pi_extension_body() else {
        return false;
    };
    body.contains(PI_EXTENSION_SIGNATURE)
}

/// Writes or removes the Pi extension file. The fingerprint covers the file that
/// is about to be replaced, so an extension edited since the preview is refused.
///
/// There is deliberately no backup. The extension is generated — it lives in this
/// binary as `PI_EXTENSION_CODE`, with the relay path substituted at write time —
/// so any version Coucou has ever written can be regenerated exactly, and an old
/// generated file is never something worth restoring. The only thing a backup
/// could preserve is a hand-edit to Coucou's own extension, and the next Coucou
/// update would overwrite that edit regardless; keeping a copy of it would just
/// leave a stray file behind implying it could be recovered.
///
/// What replaces a backup is the preview. Install and uninstall both show a diff
/// of the current file first, so a difference is visible and confirmed rather
/// than silently destroyed.
fn pi_write(install: bool, expected: &str) -> Result<String, String> {
    let path = pi_extension_path();
    let existing = std::fs::read(&path).ok();
    let current_fp = fingerprint_of_body();
    if current_fp != expected {
        return Err("Settings changed since the preview was taken. Nothing was written.".into());
    }

    // An extension Coucou did not write is the user's, and this check is the
    // last line of defence: even if the UI were bypassed, neither installing nor
    // uninstalling may touch it. Without this, reinstalling Coucou's hooks would
    // replace a working hand-edited extension with Coucou's built-in one.
    if existing.is_some() && !pi_extension_is_ours() {
        return Err(format!(
            "{} already holds an extension Coucou did not write, so it has been left exactly as it is. \
             Reinstalling would replace it, and there is no way to recover it from here — \
             Coucou is not going to do that to you. \
             If you want Coucou's version, move your file aside first.",
            path.display()
        ));
    }

    if !install {
        if path.exists() {
            let _ = std::fs::remove_file(&path);
        }
        return Ok("Removed Coucou's extension from Pi.".into());
    }

    let dir = path.parent().unwrap_or(Path::new("."));
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;

    std::fs::write(&path, pi_extension_code()).map_err(|e| format!("write failed: {e}"))?;
    Ok(format!("Wrote {}.", path.display()))
}

// ── Public API ────────────────────────────────────────────────────────────────

/// Whether one agent's hooks are installed, and where they would be written.
///
/// Pi's answer comes from whether the extension file exists rather than from a
/// settings map, because that is the shape Pi actually loads.
pub fn status(agent: &str) -> HookStatus {
    let installed = if agent == "pi" {
        pi_extension_path().exists()
    } else {
        let current = read_settings_lossy(agent);
        current
            .get("hooks")
            .and_then(Value::as_object)
            .map(|hooks| {
                hooks
                    .values()
                    .filter_map(Value::as_array)
                    .flatten()
                    .any(entry_is_ours)
            })
            .unwrap_or(false)
    };
    let hook_path = settings::hook_exe_path();
    // Every agent except Pi merges into a settings file and only ever adds or
    // removes Coucou's own entries, so those are always safe to update. Pi's
    // extension is a whole file, so it can be one of yours instead.
    let managed = agent != "pi" || !installed || pi_extension_is_ours();
    // Pi's artefact is the extension file, not ~/.pi/agent/settings.json. Reporting
    // the settings path made the UI name a file Coucou never wrote and does not
    // manage, which is what produced a message about the wrong file entirely.
    let settings_path = if agent == "pi" {
        pi_extension_path()
    } else {
        settings_path_for_agent(agent)
    };
    HookStatus {
        installed,
        managed,
        settings_path: settings_path.to_string_lossy().to_string(),
        hook_ready: hook_path.exists(),
        hook_path: hook_path.to_string_lossy().to_string(),
    }
}

pub fn preview(agent: &str, install: bool) -> Result<HookPreview, String> {
    if agent == "pi" {
        return pi_preview(install);
    }
    let current = read_settings(agent)?;
    let next = merged_for(agent, &current, install);
    Ok(HookPreview {
        diff: unified_diff(&pretty(&current), &pretty(&next)),
        backup: backup_path(agent).to_string_lossy().to_string(),
        settings_path: settings_path_for_agent(agent).to_string_lossy().to_string(),
        fingerprint: current_fingerprint(agent),
    })
}

/// Pi's preview is a file, not a diff: a green line when it will be written and
/// a red one when it will be removed.
fn pi_preview(install: bool) -> Result<HookPreview, String> {
    let path = pi_extension_path();
    // With a user-owned extension in place, a diff of "what Coucou would write"
    // would be a lie by implication: nothing is going to be written. Say what is
    // actually true instead.
    if install && pi_extension_body().is_some() && !pi_extension_is_ours() {
        return Ok(HookPreview {
            diff: format!(
                "{}\n\nThis file already exists and is not the extension Coucou writes — most likely your own, \
                 with your own changes.\n\nCoucou will leave it exactly as it is. Reinstalling would replace it, \
                 and this is not something Coucou can undo, so it will not.\n\n\
                 Your Pi keeps reporting to the island either way: the relay is already listening, and the file on \
                 disk is what Pi loads.\n\nMove your file aside first if you do want Coucou's version.",
                path.display()
            ),
            backup: String::new(),
            settings_path: path.to_string_lossy().to_string(),
            fingerprint: fingerprint_of_body(),
        });
    }
    let next = if install {
        pi_extension_code()
    } else {
        String::new()
    };
    let mut diff = String::new();
    for line in next.lines() {
        diff.push_str(&format!("+{line}\n"));
    }
    let fingerprint = fingerprint_of_body();
    Ok(HookPreview {
        diff,
        // Nothing is backed up: the extension is generated and can always be
        // rewritten. See pi_write.
        backup: String::new(),
        settings_path: path.to_string_lossy().to_string(),
        fingerprint,
    })
}

/// One place that decides what "installed" means for each agent, so the preview
/// and the write can never disagree about what they are about to do.
fn merged_for(agent: &str, current: &Value, install: bool) -> Value {
    match (agent, install) {
        (_, false) => match agent {
            "copilot" => copilot_without_ours(current),
            _ => without_ours(agent, current),
        },
        ("copilot", true) => copilot_merged(current),
        ("antigravity", true) => antigravity_merged(current),
        ("codex", true) => codex_merged(current),
        _ => merged(agent, current),
    }
}

/// Writes the merged (or cleaned) settings after taking a dated backup.
///
/// `fingerprint` is the one the preview was computed from. If the file changed
/// in between — another tool, another window, the user's own editor — we stop
/// and make them look at a fresh diff, because the only thing worse than not
/// installing the hooks is silently reverting somebody else's edit.
pub fn write(agent: &str, install: bool, fingerprint: &str) -> Result<String, String> {
    if agent == "pi" {
        return pi_write(install, fingerprint);
    }
    let path = settings_path_for_agent(agent);
    let dir = path.parent().unwrap_or(Path::new("."));
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;

    // Read before the backup: an unreadable file must abort before we touch
    // anything at all.
    let current = read_settings(agent)?;
    if current_fingerprint(agent) != fingerprint {
        return Err(format!(
            "{} changed since the preview. Nothing was written — review the new diff.",
            path.display()
        ));
    }

    let backup = backup_path(agent);
    if path.exists() {
        std::fs::copy(&path, &backup).map_err(|e| format!("backup failed: {e}"))?;
    }

    let next = merged_for(agent, &current, install);
    let mut text = pretty(&next);
    text.push('\n');

    // A dotfiles setup often makes settings.json a symlink: write to the file it
    // points at, so the link survives the rename below.
    #[cfg(unix)]
    let path = std::fs::canonicalize(&path).unwrap_or(path);

    // Write beside the target and rename over it: a crash or a full disk leaves
    // the original settings.json intact rather than half a file.
    let temp = path.with_extension(format!("json.coucou-{}", std::process::id()));
    if let Err(err) = write_like(&temp, &path, text.as_bytes()) {
        let _ = std::fs::remove_file(&temp);
        return Err(format!("write failed: {err}"));
    }
    if let Err(err) = std::fs::rename(&temp, &path) {
        let _ = std::fs::remove_file(&temp);
        return Err(format!("write failed: {err}"));
    }
    Ok(backup.to_string_lossy().to_string())
}

/// Writes `bytes` to `temp`, which is about to replace `original`.
///
/// On Linux a fresh file would get the umask's 0644, and settings.json can hold
/// API keys in its `env` block: the new file is created readable by us only,
/// then given the original's permissions, so the rename never widens them.
fn write_like(temp: &Path, original: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let mut file = options.open(temp)?;
    file.write_all(bytes)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(original)
            .map(|m| m.permissions().mode() & 0o777)
            .unwrap_or(0o600);
        file.set_permissions(std::fs::Permissions::from_mode(mode))?;
    }
    #[cfg(not(unix))]
    let _ = original;
    Ok(())
}

/// Copies the relay (coucou-hook.exe / coucou-hook) into the local data dir's
/// bin/ on launch. In a bundled install it comes from the app resources; in
/// `tauri dev` it sits next to the app binary in the workspace target directory.
///
/// Every candidate is tried rather than just the first, because getting this
/// wrong is silent and fatal: `resources` used to be a glob, which made NSIS
/// mirror the source path into `_up_\target\release\`, no candidate matched, and
/// the relay was simply never installed. It only looked healthy on a developer
/// machine, where a leftover copy from `tauri dev` was already sitting in bin/.
pub fn ensure_hook_exe(app: &AppHandle) {
    let dest = settings::hook_exe_path();
    let Some(dir) = dest.parent() else { return };
    // Nobody else may swap the relay Claude Code runs: its folder is ours only.
    if platform::ensure_private_dir(&settings::local_dir()).is_err()
        || std::fs::create_dir_all(dir).is_err()
    {
        return;
    }

    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Ok(p) = app
        .path()
        .resolve(platform::HOOK_EXE, tauri::path::BaseDirectory::Resource)
    {
        candidates.push(p);
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(parent) = exe.parent() {
            // Installed build, then `tauri dev` (target/debug) next to the
            // release hook the pre-build step produces.
            candidates.push(parent.join(platform::HOOK_EXE));
            candidates.push(parent.join("../release").join(platform::HOOK_EXE));
            // Belt and braces: where the old glob form used to land it.
            candidates.push(parent.join("_up_/target/release").join(platform::HOOK_EXE));
        }
    }

    let tried: Vec<String> = candidates.iter().map(|p| p.display().to_string()).collect();
    let Some(src) = candidates.into_iter().find(|p| p.exists()) else {
        crate::log::line(format!(
            "{} not found — Claude Code hooks cannot work. Looked in: {}",
            platform::HOOK_EXE,
            tried.join(", ")
        ));
        return;
    };
    install_relay(&src, &dest);
}

#[cfg(windows)]
fn install_relay(src: &Path, dest: &Path) {
    let same = match (std::fs::metadata(src), std::fs::metadata(dest)) {
        (Ok(a), Ok(b)) => a.len() == b.len() && a.modified().ok() == b.modified().ok(),
        _ => false,
    };
    if same {
        return;
    }
    // A hook may be running right now and hold the file open; keeping the old
    // copy is fine, it is the same relay.
    if let Err(err) = std::fs::copy(src, dest) {
        if !dest.exists() {
            crate::log::line(format!("could not install {}: {err}", platform::HOOK_EXE));
        }
    }
}

/// Linux does not keep the modification time on copy, so the contents decide.
/// The new relay is written beside the old one and renamed over it: a hook
/// starting at that moment runs either the old relay or the new one, never half
/// of one, and a relay that is running right now does not block the update.
#[cfg(unix)]
fn install_relay(src: &Path, dest: &Path) {
    use std::os::unix::fs::PermissionsExt;
    if matches!((std::fs::read(src), std::fs::read(dest)), (Ok(a), Ok(b)) if a == b) {
        return;
    }
    let temp = dest.with_extension(format!("new-{}", std::process::id()));
    let result = std::fs::copy(src, &temp)
        .and_then(|_| std::fs::set_permissions(&temp, std::fs::Permissions::from_mode(0o755)))
        .and_then(|_| std::fs::rename(&temp, dest));
    if let Err(err) = result {
        let _ = std::fs::remove_file(&temp);
        crate::log::line(format!("could not install {}: {err}", platform::HOOK_EXE));
    }
}

// ── Minimal unified diff (LCS) ────────────────────────────────────────────────

/// settings.json is short, so a plain O(n·m) LCS is the simplest honest diff.
fn unified_diff(before: &str, after: &str) -> String {
    let a: Vec<&str> = before.lines().collect();
    let b: Vec<&str> = after.lines().collect();
    let (n, m) = (a.len(), b.len());

    let mut lcs = vec![vec![0usize; m + 1]; n + 1];
    for i in (0..n).rev() {
        for j in (0..m).rev() {
            lcs[i][j] = if a[i] == b[j] {
                lcs[i + 1][j + 1] + 1
            } else {
                lcs[i + 1][j].max(lcs[i][j + 1])
            };
        }
    }

    let mut out: Vec<String> = Vec::new();
    let (mut i, mut j) = (0usize, 0usize);
    while i < n && j < m {
        if a[i] == b[j] {
            out.push(format!("  {}", a[i]));
            i += 1;
            j += 1;
        } else if lcs[i + 1][j] >= lcs[i][j + 1] {
            out.push(format!("- {}", a[i]));
            i += 1;
        } else {
            out.push(format!("+ {}", b[j]));
            j += 1;
        }
    }
    while i < n {
        out.push(format!("- {}", a[i]));
        i += 1;
    }
    while j < m {
        out.push(format!("+ {}", b[j]));
        j += 1;
    }

    // Keep three lines of context around each change so the panel stays readable.
    let changed: Vec<usize> = out
        .iter()
        .enumerate()
        .filter(|(_, l)| l.starts_with('+') || l.starts_with('-'))
        .map(|(i, _)| i)
        .collect();
    if changed.is_empty() {
        return "No change.".into();
    }
    let mut keep = vec![false; out.len()];
    for idx in changed {
        let lo = idx.saturating_sub(3);
        let hi = (idx + 4).min(out.len());
        for k in lo..hi {
            keep[k] = true;
        }
    }
    let mut result = String::new();
    let mut gap = false;
    for (idx, line) in out.iter().enumerate() {
        if keep[idx] {
            result.push_str(line);
            result.push('\n');
            gap = false;
        } else if !gap {
            result.push_str("  …\n");
            gap = true;
        }
    }
    result
}

/// `platform::home_dir()` reads an environment variable, so every test that
/// redirects the home directory changes process-wide state. They all take this
/// lock so two of them can never interleave and write into each other's tree.
#[cfg(test)]
static HOME_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[cfg(test)]
mod tests {
    use super::HOME_LOCK;
    use super::*;

    const WHERE: &str = "settings.json";

    #[test]
    fn a_utf8_bom_is_stripped_not_treated_as_corruption() {
        // PowerShell 5's `Set-Content -Encoding utf8` produces exactly this.
        let mut bytes = vec![0xEF, 0xBB, 0xBF];
        bytes.extend_from_slice(br#"{"model":"opus","hooks":{}}"#);
        let parsed = parse_settings(&bytes, WHERE).expect("a BOM must not defeat the parser");
        assert_eq!(parsed["model"], "opus");
    }

    #[test]
    fn unreadable_content_is_an_error_never_an_empty_object() {
        // This is the whole bug: returning {} here meant `merged()` produced a
        // file containing nothing but Coucou's hooks, and the write replaced
        // everything the user had.
        for bad in [&b"{ not json"[..], &b"[1,2,3]"[..], &b"\"a string\""[..]] {
            assert!(
                parse_settings(bad, WHERE).is_err(),
                "content we cannot use must refuse, not come back empty"
            );
        }
    }

    #[test]
    fn empty_and_whitespace_files_start_from_nothing() {
        assert_eq!(parse_settings(b"", WHERE).unwrap(), json!({}));
        assert_eq!(
            parse_settings(
                b"  
	 ", WHERE
            )
            .unwrap(),
            json!({})
        );
    }

    #[test]
    fn merging_keeps_every_other_setting_and_every_foreign_hook() {
        let existing = serde_json::json!({
            "model": "claude-opus-5",
            "theme": "dark",
            "enabledPlugins": ["a", "b"],
            "hooks": {
                "PreToolUse": [
                    { "hooks": [{ "type": "command", "command": "someone-elses-tool.exe" }] }
                ],
                "SomeEventWeDoNotTouch": [
                    { "hooks": [{ "type": "command", "command": "keep-me.exe" }] }
                ]
            }
        });

        let after = merged("claudeCode", &existing);
        assert_eq!(after["model"], "claude-opus-5");
        assert_eq!(after["theme"], "dark");
        assert_eq!(after["enabledPlugins"], serde_json::json!(["a", "b"]));

        let pre = after["hooks"]["PreToolUse"].as_array().unwrap();
        assert!(
            pre.iter().any(|e| serde_json::to_string(e)
                .unwrap()
                .contains("someone-elses-tool.exe")),
            "another tool's hook was dropped"
        );
        assert!(pre.iter().any(entry_is_ours), "our own hook was not added");
        assert!(after["hooks"]["SomeEventWeDoNotTouch"].is_array());

        // And removing ours puts it back exactly as it was.
        let cleaned = without_ours("claudeCode", &after);
        assert_eq!(cleaned, existing);
    }

    #[test]
    fn every_agent_gets_its_own_settings_file() {
        let _guard = HOME_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let tmp = std::env::temp_dir().join("coucou-test-agent-paths");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();
        let real_home = std::env::var(platform::HOME_VAR).ok();
        std::env::set_var(platform::HOME_VAR, &tmp);
        // Pi extension backups live under platform::local_dir(), which reads
        // LOCALAPPDATA directly. Overriding only the home directory would let a
        // test write into the real %LOCALAPPDATA%\Coucou\backups instead of the
        // sandbox — which is exactly what happened before this was noticed.
        let real_local = std::env::var_os("LOCALAPPDATA");
        std::env::set_var("LOCALAPPDATA", &tmp);

        for agent in ["claudeCode", "pi", "copilot", "antigravity", "codex"] {
            let path = settings_path_for_agent(agent);
            assert!(
                path.starts_with(&tmp),
                "{agent} must not touch the real home"
            );
        }
        // Two agents must never share a file, or installing one would clobber
        // the other's hooks.
        let mut seen = std::collections::HashSet::new();
        for agent in ["claudeCode", "pi", "copilot", "antigravity"] {
            assert!(
                seen.insert(settings_path_for_agent(agent)),
                "{agent} collided"
            );
        }
        // An unknown name falls back to Claude Code rather than inventing a path.
        assert_eq!(
            settings_path_for_agent("something-else"),
            settings_path_for_agent("claudeCode")
        );

        if let Some(home) = real_home {
            std::env::set_var(platform::HOME_VAR, home);
        }
        let _ = std::fs::remove_dir_all(&tmp);
        match real_local {
            Some(v) => std::env::set_var("LOCALAPPDATA", v),
            None => std::env::remove_var("LOCALAPPDATA"),
        }
    }

    #[test]
    fn a_copilot_hook_is_a_flat_exec_entry() {
        let existing = json!({
            "version": 1,
            "hooks": {
                "PreToolUse": [{ "type": "command", "exec": "their-tool" }]
            }
        });
        let after = copilot_merged(&existing);
        let pre = after["hooks"]["PreToolUse"].as_array().unwrap();
        assert!(
            pre.iter().any(|e| e["exec"] == "their-tool"),
            "their entry was dropped"
        );
        let ours = pre
            .iter()
            .find(|e| entry_is_ours(e))
            .expect("our entry is missing");
        assert_eq!(ours["args"][0], "--agent");
        assert_eq!(ours["args"][1], "copilot");
        assert_eq!(
            ours["timeoutSec"], 10,
            "PreToolUse must not block for a human"
        );

        // PermissionRequest is the one that waits, so it needs the long timeout.
        let perm = after["hooks"]["PermissionRequest"].as_array().unwrap();
        let ours = perm.iter().find(|e| entry_is_ours(e)).unwrap();
        assert_eq!(ours["timeoutSec"], 120);

        // Uninstall takes ours out and leaves theirs exactly as it was.
        let cleaned = copilot_without_ours(&after);
        assert_eq!(cleaned, existing);
    }

    #[test]
    fn codex_uses_the_matcher_shape_and_leaves_foreign_hooks_alone() {
        // Codex nests hooks exactly as Claude Code does, so a foreign hook with
        // the same event name must survive untouched beside ours.
        let existing = json!({
            "model": "gpt-5",
            "hooks": {
                "PreToolUse": [
                    { "hooks": [{ "type": "command", "command": "my-own-linter" }] }
                ]
            }
        });
        let after = codex_merged(&existing);
        assert_eq!(after["model"], "gpt-5", "unrelated config was lost");

        let list = after["hooks"]["PreToolUse"].as_array().unwrap();
        let mine = list
            .iter()
            .find(|e| entry_is_ours(e))
            .expect("Coucou's entry is missing");
        assert!(
            mine["hooks"][0]["command"]
                .as_str()
                .unwrap()
                .contains("--agent codex"),
            "the command is not tagged as codex"
        );
        assert!(
            list.iter()
                .any(|e| e["hooks"][0]["command"] == "my-own-linter"),
            "the user's own PreToolUse hook was dropped"
        );

        // SessionEnd is 3s on macOS, not the usual 10s — it only has to note
        // that the session closed.
        assert_eq!(
            after["hooks"]["SessionEnd"][0]["hooks"][0]["timeout"], 3,
            "SessionEnd timeout does not match the macOS app"
        );

        // Round trip: removing ours must leave the foreign hook exactly as it was.
        let stripped = without_ours("codex", &after);
        let list = stripped["hooks"]["PreToolUse"].as_array().unwrap();
        assert!(
            !list.iter().any(entry_is_ours),
            "an entry survived uninstall"
        );
        assert_eq!(list.len(), 1, "uninstall disturbed a foreign hook");
    }

    #[test]
    fn codex_and_antigravity_do_not_share_a_file() {
        let _guard = HOME_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        assert_ne!(
            settings_path_for_agent("codex"),
            settings_path_for_agent("antigravity"),
            "Codex and Antigravity would clobber each other"
        );
        assert_ne!(
            settings_path_for_agent("codex"),
            settings_path_for_agent("copilot"),
            "Codex and Copilot would clobber each other"
        );
    }

    #[test]
    fn antigravity_uses_its_own_invocation_events() {
        let existing = json!({ "mcpServers": { "keep": { "command": "npx" } } });
        let after = antigravity_merged(&existing);
        assert_eq!(
            after["mcpServers"]["keep"]["command"], "npx",
            "unrelated config was lost"
        );
        for event in [
            "PreInvocation",
            "PostInvocation",
            "PreToolUse",
            "PostToolUse",
        ] {
            let list = after["hooks"][event]
                .as_array()
                .unwrap_or_else(|| panic!("{event} missing"));
            assert!(list.iter().any(entry_is_ours), "{event} has no Coucou hook");
        }
        // The legacy lifecycle names are installed too, so an older build that
        // still emits them does not end up half-tracked.
        assert!(after["hooks"]["SessionStart"]
            .as_array()
            .unwrap()
            .iter()
            .any(entry_is_ours));

        let cleaned = without_ours("antigravity", &after);
        assert_eq!(cleaned, existing, "uninstall must restore the file exactly");
    }

    #[test]
    fn installing_twice_does_not_double_the_hooks() {
        let once = copilot_merged(&json!({}));
        let twice = copilot_merged(&once);
        let pre = twice["hooks"]["PreToolUse"].as_array().unwrap();
        assert_eq!(pre.iter().filter(|e| entry_is_ours(e)).count(), 1);

        let claude_once = merged("claudeCode", &json!({}));
        let claude_twice = merged("claudeCode", &claude_once);
        let pre = claude_twice["hooks"]["PreToolUse"].as_array().unwrap();
        assert_eq!(pre.iter().filter(|e| entry_is_ours(e)).count(), 1);
    }

    #[test]
    fn the_pi_extension_is_a_written_file_not_a_merged_map() {
        let _guard = HOME_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let tmp = std::env::temp_dir().join("coucou-test-pi-ext");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();
        let real_home = std::env::var(platform::HOME_VAR).ok();
        std::env::set_var(platform::HOME_VAR, &tmp);
        // Pi extension backups live under platform::local_dir(), which reads
        // LOCALAPPDATA directly. Overriding only the home directory would let a
        // test write into the real %LOCALAPPDATA%\Coucou\backups instead of the
        // sandbox — which is exactly what happened before this was noticed.
        let real_local = std::env::var_os("LOCALAPPDATA");
        std::env::set_var("LOCALAPPDATA", &tmp);

        assert!(!status("pi").installed, "nothing installed yet");

        let plan = preview("pi", true).expect("preview");
        assert!(
            plan.diff.contains("coucou-hook"),
            "the preview must show the file"
        );
        assert!(
            plan.fingerprint.is_empty(),
            "a missing file fingerprints as empty"
        );

        write("pi", true, &plan.fingerprint).expect("install");
        assert!(pi_extension_path().exists());
        assert!(status("pi").installed);
        let body = std::fs::read_to_string(pi_extension_path()).unwrap();
        assert!(
            body.contains("--agent"),
            "the extension must tag its events"
        );
        assert!(
            !body.contains("__COUCOU_HOOK_EXE__"),
            "the relay path placeholder was never substituted"
        );
        // A Windows path is mostly backslashes; JSON-escaping doubles them, and
        // the extension has to carry the path Rust actually resolved.
        assert!(
            body.contains(
                &settings::hook_exe_path()
                    .to_string_lossy()
                    .replace('\\', "\\\\")
            ),
            "the extension must carry the relay path Rust resolved"
        );
        // Permissions belong to the Pi permission extension, which asks Coucou
        // itself. If this file ever intercepts tool_call again, two extensions
        // answer one decision and the island card races the terminal for it.
        assert!(
            !body.contains("pi.on(\"tool_call\""),
            "the shipped extension must not register a tool_call handler"
        );
        assert!(
            !body.contains("COUCOU_TOOLS"),
            "and must not carry its own tool allowlist"
        );

        // A second install of an untouched file is accepted and stays single.
        let again = preview("pi", true).unwrap();
        write("pi", true, &again.fingerprint).expect("reinstall");
        assert_eq!(std::fs::read_to_string(pi_extension_path()).unwrap(), body);

        // An extension edited since the preview is refused.
        std::fs::write(pi_extension_path(), "// edited by hand\n").unwrap();
        assert!(
            write("pi", true, &again.fingerprint).is_err(),
            "stale write must fail"
        );
        assert!(std::fs::read_to_string(pi_extension_path())
            .unwrap()
            .contains("edited by hand"));

        // Editing it turned it into the user's file, so uninstall is refused
        // too — it no longer reports as Coucou's own.
        assert!(!status("pi").managed);
        let remove = preview("pi", false).unwrap();
        assert!(
            write("pi", false, &remove.fingerprint).is_err(),
            "uninstall must refuse a file Coucou did not write"
        );
        assert!(
            pi_extension_path().exists(),
            "and the file must still be there"
        );

        // Coucou's own file is removable, and says plainly that it did so.
        std::fs::write(pi_extension_path(), body).unwrap();
        assert!(status("pi").managed, "a Coucou extension is ours to manage");
        let remove = preview("pi", false).unwrap();
        let said = write("pi", false, &remove.fingerprint).unwrap();
        assert!(
            said.contains("Removed"),
            "uninstall should say what it did, got: {said}"
        );
        assert!(!pi_extension_path().exists());
        assert!(!status("pi").installed);

        // Nothing is written outside Pi's extensions directory. There is no
        // backup by design, and no stray file should appear anywhere else.
        assert!(
            !remove.backup.contains("settings.json"),
            "no Pi operation may touch a settings backup, got: {}",
            remove.backup
        );

        if let Some(home) = real_home {
            std::env::set_var(platform::HOME_VAR, home);
        }
        let _ = std::fs::remove_dir_all(&tmp);
        match real_local {
            Some(v) => std::env::set_var("LOCALAPPDATA", v),
            None => std::env::remove_var("LOCALAPPDATA"),
        }
    }

    #[test]
    fn a_hand_corrected_coucou_extension_is_still_ours_to_manage() {
        let _guard = HOME_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let tmp = std::env::temp_dir().join("coucou-test-pi-drift");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();
        let real_home = std::env::var(platform::HOME_VAR).ok();
        std::env::set_var(platform::HOME_VAR, &tmp);
        // Pi extension backups live under platform::local_dir(), which reads
        // LOCALAPPDATA directly. Overriding only the home directory would let a
        // test write into the real %LOCALAPPDATA%\Coucou\backups instead of the
        // sandbox — which is exactly what happened before this was noticed.
        let real_local = std::env::var_os("LOCALAPPDATA");
        std::env::set_var("LOCALAPPDATA", &tmp);

        // A working Coucou extension that has drifted from the generated bytes:
        // a rewritten header and a hand-resolved relay path, both of which happen
        // whenever the integration is corrected on a live machine. Byte-equality
        // used to call this a stranger's file, which refused install and uninstall
        // permanently and named the wrong path while doing it.
        let drifted = format!(
            "// Coucou hook relay extension for Pi.\n\
             // Corrected by hand: see the note below.\n\
             import {{ spawn }} from \"node:child_process\";\n\
             const HOOK_EXE = \"{}\";\n",
            settings::hook_exe_path().to_string_lossy()
        );
        std::fs::create_dir_all(pi_extension_path().parent().unwrap()).unwrap();
        std::fs::write(pi_extension_path(), &drifted).unwrap();

        let status = status("pi");
        assert!(status.installed, "the file is there, so Pi is wired up");
        assert!(
            status.managed,
            "a Coucou extension with cosmetic drift must still be ours to manage"
        );
        assert_eq!(
            status.settings_path,
            pi_extension_path().to_string_lossy(),
            "status must name the extension file, not Pi's settings.json"
        );
        assert!(
            !status.settings_path.ends_with("settings.json"),
            "Pi's settings.json is not Coucou's artefact and must never be named"
        );

        // And it is genuinely manageable: the preview offers to write rather than
        // to refuse. No backup is offered, because the extension is generated and
        // can always be written again.
        let plan = preview("pi", true).unwrap();
        assert!(
            plan.diff.contains("coucou-hook"),
            "install was refused instead of offered, got: {}",
            plan.diff
        );
        assert!(
            plan.backup.is_empty(),
            "nothing is backed up; the preview should not promise a backup"
        );
        std::env::remove_var(platform::HOME_VAR);
        if let Some(h) = real_home {
            std::env::set_var(platform::HOME_VAR, h);
        }
        match real_local {
            Some(v) => std::env::set_var("LOCALAPPDATA", v),
            None => std::env::remove_var("LOCALAPPDATA"),
        }
    }

    #[test]
    fn coucou_never_overwrites_or_deletes_an_extension_it_did_not_write() {
        let _guard = HOME_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let tmp = std::env::temp_dir().join("coucou-test-pi-foreign");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();
        let real_home = std::env::var(platform::HOME_VAR).ok();
        std::env::set_var(platform::HOME_VAR, &tmp);
        // Pi extension backups live under platform::local_dir(), which reads
        // LOCALAPPDATA directly. Overriding only the home directory would let a
        // test write into the real %LOCALAPPDATA%\Coucou\backups instead of the
        // sandbox — which is exactly what happened before this was noticed.
        let real_local = std::env::var_os("LOCALAPPDATA");
        std::env::set_var("LOCALAPPDATA", &tmp);

        // This is the real hazard: an extension that works, with the user's own
        // changes in it. It exists, so a naive `installed` check says yes.
        let yours = "// my own Pi hook, with my own changes\nexport default () => {};\n";
        std::fs::create_dir_all(pi_extension_path().parent().unwrap()).unwrap();
        std::fs::write(pi_extension_path(), yours).unwrap();

        let status = status("pi");
        assert!(status.installed, "the file is there, so Pi is wired up");
        assert!(
            !status.managed,
            "an extension Coucou did not write must not be reported as Coucou's"
        );

        // Reinstalling must refuse, not overwrite.
        let plan = preview("pi", true).unwrap();
        assert!(
            plan.diff.contains("leave it exactly as it is"),
            "the preview must say the file is kept, got: {}",
            plan.diff
        );
        assert!(
            plan.backup.is_empty(),
            "nothing is written, so there is no backup"
        );
        let err = write("pi", true, &plan.fingerprint).unwrap_err();
        assert!(err.contains("left exactly as it is"), "got: {err}");
        assert_eq!(
            std::fs::read_to_string(pi_extension_path()).unwrap(),
            yours,
            "the user's extension must be byte-for-byte untouched"
        );

        // So must uninstalling.
        let removal = preview("pi", false).unwrap();
        let err = write("pi", false, &removal.fingerprint).unwrap_err();
        assert!(err.contains("left exactly as it is"), "got: {err}");
        assert_eq!(
            std::fs::read_to_string(pi_extension_path()).unwrap(),
            yours,
            "uninstall must not delete the user's extension either"
        );

        // Move it aside and Coucou's version installs cleanly, as it should.
        std::fs::rename(
            pi_extension_path(),
            pi_extension_path().with_extension("ts.mine"),
        )
        .unwrap();
        assert!(!pi_extension_is_ours());
        let fresh = preview("pi", true).unwrap();
        write("pi", true, &fresh.fingerprint).expect("install with nothing in the way");
        assert!(
            pi_extension_is_ours(),
            "what Coucou writes must be recognisable as Coucou's"
        );
        let body = std::fs::read_to_string(pi_extension_path()).unwrap();
        assert!(
            body.contains("--agent"),
            "the installed extension must tag its events"
        );

        // And once it is Coucou's file again, a reinstall is allowed and is
        // idempotent — this is the button a user can safely press.
        let again = preview("pi", true).unwrap();
        write("pi", true, &again.fingerprint).expect("reinstall our own file");
        assert_eq!(std::fs::read_to_string(pi_extension_path()).unwrap(), body);

        if let Some(home) = real_home {
            std::env::set_var(platform::HOME_VAR, home);
        }
        let _ = std::fs::remove_dir_all(&tmp);
        match real_local {
            Some(v) => std::env::set_var("LOCALAPPDATA", v),
            None => std::env::remove_var("LOCALAPPDATA"),
        }
    }

    #[test]
    fn a_fingerprint_notices_any_change() {
        assert_eq!(fingerprint(b"{}"), fingerprint(b"{}"));
        assert_ne!(fingerprint(b"{}"), fingerprint(b"{ }"));
        assert_ne!(fingerprint(b""), fingerprint(b"{}"));
    }

    #[cfg(unix)]
    #[test]
    fn the_hook_path_is_one_shell_word_whatever_it_contains() {
        assert_eq!(sh_quote("/home/a b/x"), "'/home/a b/x'");
        // $, backticks, backslashes and double quotes stay literal in single quotes.
        assert_eq!(sh_quote(r#"/h/$(id)`x`\"y"#), r#"'/h/$(id)`x`\"y'"#);
        // A single quote closes, escapes and reopens.
        assert_eq!(sh_quote("/h/it's"), r"'/h/it'\''s'");
    }

    /// settings.json can carry API keys in its `env` block: rewriting it must
    /// never make it readable by more people than before.
    #[cfg(unix)]
    #[test]
    fn rewriting_settings_never_widens_its_permissions() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("coucou-perm-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let original = dir.join("settings.json");
        let temp = dir.join("settings.json.new");
        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;

        for wanted in [0o600, 0o640, 0o644] {
            std::fs::write(&original, b"{}").unwrap();
            std::fs::set_permissions(&original, std::fs::Permissions::from_mode(wanted)).unwrap();
            let _ = std::fs::remove_file(&temp);
            write_like(&temp, &original, b"{\"a\":1}").unwrap();
            assert_eq!(mode(&temp), wanted, "the rewrite must keep {wanted:o}");
        }

        // No original: ours only.
        std::fs::remove_file(&original).unwrap();
        let _ = std::fs::remove_file(&temp);
        write_like(&temp, &original, b"{}").unwrap();
        assert_eq!(mode(&temp), 0o600);

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Everything filesystem-shaped lives in one test on purpose: it points
    /// the home directory at a temp directory, and that is process-wide.
    #[test]
    fn writing_backs_up_preserves_and_refuses_a_changed_file() {
        let _guard = HOME_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let tmp = std::env::temp_dir().join(format!("coucou-hooks-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(tmp.join(".claude")).unwrap();
        std::env::set_var(platform::HOME_VAR, &tmp);

        let path = settings_path_for_agent("claudeCode");
        assert!(
            path.starts_with(&tmp),
            "the test must not touch the real home"
        );

        // A real-shaped file, written the way PowerShell 5 would: UTF-8 with BOM.
        let original = r#"{"model":"claude-opus-5","theme":"dark","tui":{"x":1},"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"other-tool.exe"}]}]}}"#;
        let mut bytes = vec![0xEF, 0xBB, 0xBF];
        bytes.extend_from_slice(original.as_bytes());
        std::fs::write(&path, &bytes).unwrap();

        // Install.
        let plan = preview("claudeCode", true).expect("a BOM must not stop the preview");
        assert!(
            plan.diff.contains("coucou-hook"),
            "the diff must show what changes"
        );
        let backup = write("claudeCode", true, &plan.fingerprint).expect("install should succeed");

        // The backup holds the original bytes, BOM and all.
        assert_eq!(std::fs::read(&backup).unwrap(), bytes);

        // Everything else survived, and so did the other tool's hook.
        let after: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(after["model"], "claude-opus-5");
        assert_eq!(after["theme"], "dark");
        assert_eq!(after["tui"]["x"], 1);
        let pre = after["hooks"]["PreToolUse"].as_array().unwrap();
        assert!(pre
            .iter()
            .any(|e| serde_json::to_string(e).unwrap().contains("other-tool.exe")));
        assert!(status("claudeCode").installed);

        // A file that moved since the preview is refused, and left alone.
        let stale = preview("claudeCode", false).unwrap();
        std::fs::write(&path, br#"{"model":"someone-else-edited-this"}"#).unwrap();
        let err = write("claudeCode", false, &stale.fingerprint).unwrap_err();
        assert!(err.contains("changed since the preview"), "got: {err}");
        let untouched: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(untouched["model"], "someone-else-edited-this");

        // Content we cannot parse is refused before anything is written.
        std::fs::write(&path, b"{ broken").unwrap();
        assert!(preview("claudeCode", true).is_err());
        assert!(write("claudeCode", true, "whatever").is_err());
        assert_eq!(std::fs::read(&path).unwrap(), b"{ broken");

        let _ = std::fs::remove_dir_all(&tmp);
    }
}
