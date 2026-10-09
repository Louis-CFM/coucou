// Hook and plugin installers for every agent other than Claude Code (hooks.rs).
//
// Each agent is a list of file edits handed to config_file.rs, which applies the
// CLAUDE.md rules once for all of them: strict read, refuse unexpected types,
// diff, dated backup that must succeed, fingerprint check, atomic write. What
// lives here is only *what* changes in each agent's config, and the command
// line that starts the relay in the shell that agent uses.
//
// Formats and paths follow the Mac app (Nova/Sources/App/HookServer.swift)
// so a config shared between machines (dotfiles) looks the same everywhere.

use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_json::{json, Map, Value};

use crate::config_file::{self, FileEdit, Plan};
use crate::{platform, settings};

/// Marker that identifies a Nova entry: the relay's file name.
const MARKER: &str = "nova-hook";

// ── The relay command line ────────────────────────────────────────────────────

/// The shell an agent runs its hook commands through on Windows. On Linux every
/// agent uses `sh` (or bash), so there is only one way to quote.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Shell {
    /// Git Bash on Windows (Claude Code), `sh` on Linux.
    Sh,
    /// `powershell -Command` (Gemini CLI, Copilot CLI's `powershell` field).
    PowerShell,
    /// `cmd /C`, or a process started directly (Codex, Cursor, Antigravity, Muse).
    Cmd,
}

/// Where the relay is and which OS the command is for. Kept apart from the
/// real install so tests can build both the Windows and the Linux command.
pub struct Relay {
    pub exe: String,
    pub windows: bool,
}

impl Relay {
    pub fn current() -> Self {
        Self {
            exe: settings::hook_exe_path().to_string_lossy().to_string(),
            windows: cfg!(windows),
        }
    }

    /// The relay followed by `args`, as one command line for `shell`.
    pub fn command(&self, shell: Shell, args: &str) -> String {
        if !self.windows {
            return format!("{} {args}", sh_quote(&self.exe));
        }
        let exe = match shell {
            // Git Bash reads backslashes as escapes: forward slashes, quoted.
            Shell::Sh => format!("\"{}\"", self.exe.replace('\\', "/")),
            // A quoted string alone is an expression in PowerShell: `&` runs it.
            // Inside single quotes only `'` is special, and it doubles.
            Shell::PowerShell => format!("& '{}'", self.exe.replace('\'', "''")),
            // cmd /C keeps the quotes of a lone quoted program name; a plain path
            // goes unquoted so it also works if the agent turns out to use
            // PowerShell. A Windows path cannot contain `"`.
            Shell::Cmd if is_plain(&self.exe) => self.exe.clone(),
            Shell::Cmd => format!("\"{}\"", self.exe),
        };
        format!("{exe} {args}")
    }
}

/// The relay command for the running OS, for `args`.
pub fn relay_command(shell: Shell, args: &str) -> String {
    Relay::current().command(shell, args)
}

/// `s` as one single-quoted POSIX shell word: `'` becomes `'\''`, nothing else
/// is special inside single quotes.
fn sh_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

/// A path no Windows shell would split or interpret.
fn is_plain(path: &str) -> bool {
    path.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '\\' | ':' | '.' | '_' | '-'))
}

// ── Agents ────────────────────────────────────────────────────────────────────

type JsonChange = Box<dyn Fn(&Value) -> Result<Option<Value>, String>>;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Agent {
    Gemini,
    Antigravity,
    Cursor,
    Codex,
    Copilot,
    Muse,
    OpenCode,
    Amp,
    Hermes,
}

impl Agent {
    pub const ALL: &'static [Agent] = &[
        Agent::Codex,
        Agent::Copilot,
        Agent::Muse,
        Agent::Gemini,
        Agent::Antigravity,
        Agent::Cursor,
        Agent::OpenCode,
        Agent::Amp,
        Agent::Hermes,
    ];

    /// The `--agent` name; the pill is `agent_<id>` (PillCatalog.swift).
    pub fn id(self) -> &'static str {
        match self {
            Agent::Gemini => "gemini",
            Agent::Antigravity => "antigravity",
            Agent::Cursor => "cursor",
            Agent::Codex => "codex",
            Agent::Copilot => "copilot",
            Agent::Muse => "muse",
            Agent::OpenCode => "opencode",
            Agent::Amp => "amp",
            Agent::Hermes => "hermes",
        }
    }

    pub fn from_id(id: &str) -> Option<Agent> {
        Self::ALL.iter().copied().find(|a| a.id() == id)
    }

    /// The files this agent's install touches, under `home`.
    fn files(self, home: &Path) -> Vec<PathBuf> {
        match self {
            Agent::Gemini => vec![home.join(".gemini").join("settings.json")],
            Agent::Antigravity => vec![home.join(".gemini").join("config").join("hooks.json")],
            Agent::Cursor => vec![home.join(".cursor").join("hooks.json")],
            Agent::Codex => vec![home.join(".codex").join("hooks.json")],
            Agent::Copilot => vec![home.join(".copilot").join("hooks").join("nova.json")],
            Agent::Muse => vec![home.join(".config").join("muse").join("settings.json")],
            // OpenCode and Amp read ~/.config on Windows too.
            Agent::OpenCode => vec![home.join(".config").join("opencode").join("plugins").join("nova.js")],
            Agent::Amp => vec![home.join(".config").join("amp").join("plugins").join("nova.ts")],
            Agent::Hermes => {
                let dir = home.join(".hermes").join("plugins").join("nova");
                vec![dir.join("__init__.py"), dir.join("plugin.yaml")]
            }
        }
    }

    /// The edits that install (or remove) Nova for this agent.
    fn edits(self, home: &Path, relay: &Relay, install: bool) -> Vec<FileEdit<'static>> {
        let files = self.files(home);
        if let Some(contents) = self.plugin(relay) {
            return files.into_iter().zip(contents).map(|(path, text)| plugin_edit(path, text, install)).collect();
        }
        let path = files[0].clone();
        let label = path.display().to_string();
        let change = self.json_change(relay, install);
        vec![FileEdit { path, edit: config_file::json_edit(label, change) }]
    }

    /// For an agent that loads a plugin rather than running hook commands, the
    /// contents of each of its files (same order as `files`).
    fn plugin(self, relay: &Relay) -> Option<Vec<String>> {
        // A JSON string is also a valid JavaScript, TypeScript and Python one.
        let hook = serde_json::to_string(&relay.exe).unwrap_or_default();
        match self {
            Agent::OpenCode => Some(vec![OPENCODE_PLUGIN.replace("{HOOK}", &hook)]),
            Agent::Amp => Some(vec![AMP_PLUGIN.replace("{HOOK}", &hook)]),
            Agent::Hermes => Some(vec![HERMES_PLUGIN.replace("{HOOK}", &hook), HERMES_PLUGIN_YAML.to_string()]),
            _ => None,
        }
    }

    /// The change to this agent's JSON config: the new object, or `None` to
    /// remove a file that is Nova's alone. Command lines are built here, up
    /// front, so the change itself is pure.
    fn json_change(self, relay: &Relay, install: bool) -> JsonChange {
        match (self, install) {
            (Agent::Gemini, false) => Box::new(|v| groups_uninstall(v, "gemini").map(Some)),
            (Agent::Gemini, true) => {
                let commands: Vec<(String, String, u64)> = GEMINI_EVENTS
                    .iter()
                    .map(|(event, said, timeout)| {
                        let command = relay.command(Shell::PowerShell, &format!("--agent gemini {said}"));
                        (event.to_string(), command, *timeout)
                    })
                    .collect();
                Box::new(move |v| gemini_install(v, &commands).map(Some))
            }
            (Agent::Antigravity, false) => Box::new(|v| antigravity_uninstall(v).map(Some)),
            (Agent::Antigravity, true) => {
                let block = antigravity_block(relay);
                Box::new(move |v| antigravity_install(v, &block).map(Some))
            }
            (Agent::Cursor, false) => Box::new(|v| groups_uninstall(v, "cursor").map(Some)),
            (Agent::Cursor, true) => {
                let command = relay.command(Shell::Cmd, "--agent cursor");
                Box::new(move |v| cursor_install(v, &command).map(Some))
            }
            (Agent::Codex, false) => Box::new(|v| groups_uninstall(v, "codex").map(Some)),
            (Agent::Codex, true) => {
                let command = relay.command(Shell::Cmd, "--agent codex");
                Box::new(move |v| codex_install(v, &command).map(Some))
            }
            (Agent::Copilot, false) => Box::new(copilot_uninstall),
            (Agent::Copilot, true) => {
                let entries: Vec<(String, Value)> = COPILOT_EVENTS
                    .iter()
                    .map(|(event, timeout)| (event.to_string(), copilot_entry(relay, event, *timeout)))
                    .collect();
                Box::new(move |v| copilot_install(v, &entries).map(Some))
            }
            (Agent::Muse, false) => Box::new(|v| groups_uninstall(v, "muse").map(Some)),
            (Agent::Muse, true) => {
                let commands: Vec<(String, String, u64)> = MUSE_EVENTS
                    .iter()
                    .map(|(event, seconds)| {
                        let command = relay.command(Shell::Cmd, &format!("--agent muse {event}"));
                        (event.to_string(), command, seconds * 1000)
                    })
                    .collect();
                Box::new(move |v| muse_install(v, &commands).map(Some))
            }
            // Plugins are whole files (see `plugin`), never merged into JSON.
            (Agent::OpenCode | Agent::Amp | Agent::Hermes, _) => {
                Box::new(|_| Err(crate::i18n::t("This agent takes a plugin, not hook entries.")))
            }
        }
    }

    /// True when the agent's config already routes to Nova. Never fails: a
    /// file we cannot read just reads as "not installed".
    fn installed(self, home: &Path) -> bool {
        let files = self.files(home);
        if matches!(self, Agent::OpenCode | Agent::Amp | Agent::Hermes) {
            return std::fs::read_to_string(&files[0]).is_ok_and(|text| is_our_plugin(&text));
        }
        let json = || {
            config_file::read(&files[0])
                .ok()
                .flatten()
                .and_then(|b| config_file::parse_json(Some(&b), "").ok())
                .unwrap_or_else(|| json!({}))
        };
        match self {
            Agent::Gemini => groups_have_ours(&json(), "gemini"),
            Agent::Antigravity => json().get("nova").is_some_and(antigravity_is_ours),
            Agent::Cursor => groups_have_ours(&json(), "cursor"),
            Agent::Codex => groups_have_ours(&json(), "codex"),
            Agent::Copilot => json()
                .get("hooks")
                .and_then(Value::as_object)
                .is_some_and(|h| h.values().filter_map(Value::as_array).flatten().any(copilot_entry_is_ours)),
            Agent::Muse => groups_have_ours(&json(), "muse"),
            Agent::OpenCode | Agent::Amp | Agent::Hermes => false,
        }
    }

    /// Whether the island can answer this agent's permission requests. Must
    /// match `takes_decisions` in the relay (hook/src/reply.rs).
    fn approvals(self) -> bool {
        matches!(self, Agent::Codex | Agent::Copilot | Agent::Muse)
    }
}

// ── Strings shown in Settings ─────────────────────────────────────────────────

// English keys, shown in the interface language (i18n.rs). Agent names are not translated.

impl Agent {
    pub fn name(self) -> &'static str {
        match self {
            Agent::Gemini => "Gemini CLI",
            Agent::Antigravity => "Antigravity",
            Agent::Cursor => "Cursor Agent",
            Agent::Codex => "Codex",
            Agent::Copilot => "GitHub Copilot CLI",
            Agent::Muse => "Muse Code",
            Agent::OpenCode => "OpenCode",
            Agent::Amp => "Amp",
            Agent::Hermes => "Hermes Agent",
        }
    }

    /// What to do once the file is written, shown with the result.
    fn note(self) -> String {
        use crate::i18n::t;
        match self {
            Agent::Gemini => t("Start a new Gemini CLI session to pick the hooks up."),
            Agent::Antigravity => t("Start a new Antigravity conversation to pick the hooks up."),
            Agent::Cursor => t("Restart Cursor to pick the hooks up."),
            Agent::Codex => t("Codex runs new hooks only once you trust them: start Codex and review them once with /hooks."),
            Agent::Copilot => t("Start a new Copilot CLI session to pick the hooks up."),
            Agent::Muse => t("Start a new Muse Code session to pick the hooks up."),
            Agent::OpenCode => t("Restart OpenCode to load the plugin."),
            Agent::Amp => t("Restart Amp to load the plugin."),
            Agent::Hermes => t("Turn it on once with `hermes plugins enable nova`, then start a new Hermes session."),
        }
    }
}

// ── Public API ────────────────────────────────────────────────────────────────

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentStatus {
    pub id: &'static str,
    pub name: &'static str,
    pub installed: bool,
    /// The file (or files, one per line) Nova writes.
    pub path: String,
    pub hook_ready: bool,
    /// The island can allow or deny this agent's permission requests.
    pub approvals: bool,
    pub note: String,
}

fn find(id: &str) -> Result<Agent, String> {
    Agent::from_id(id).ok_or_else(|| crate::i18n::tf("Unknown agent \"{id}\".", &[("id", id)]))
}

pub fn list() -> Vec<AgentStatus> {
    let home = platform::home_dir();
    let hook_ready = settings::hook_exe_path().exists();
    Agent::ALL
        .iter()
        .map(|&a| AgentStatus {
            id: a.id(),
            name: a.name(),
            installed: a.installed(&home),
            path: a.files(&home).iter().map(|p| p.display().to_string()).collect::<Vec<_>>().join("\n"),
            hook_ready,
            approvals: a.approvals(),
            note: a.note(),
        })
        .collect()
}

pub fn preview(id: &str, install: bool) -> Result<Plan, String> {
    let agent = find(id)?;
    config_file::preview(&agent.edits(&platform::home_dir(), &Relay::current(), install))
}

/// Only ever called from an explicit click. Returns the backups taken, one per line.
pub fn apply(id: &str, install: bool, fingerprint: &str) -> Result<String, String> {
    let agent = find(id)?;
    apply_in(agent, &platform::home_dir(), &Relay::current(), install, fingerprint)
}

fn apply_in(agent: Agent, home: &Path, relay: &Relay, install: bool, fingerprint: &str) -> Result<String, String> {
    let backups = config_file::apply(&agent.edits(home, relay, install), fingerprint)?;
    // Hermes loads every folder under plugins/: an empty `nova` one goes too.
    if agent == Agent::Hermes && !install {
        if let Some(dir) = agent.files(home)[0].parent() {
            let _ = std::fs::remove_dir(dir);
        }
    }
    Ok(backups.iter().map(|p| p.display().to_string()).collect::<Vec<_>>().join("\n"))
}

// ── Shared JSON helpers ───────────────────────────────────────────────────────

fn unexpected(what: &str) -> String {
    crate::i18n::tf("{what} has an unexpected type — Nova has not touched it.", &[("what", what)])
}

/// `root[key]` as an object to edit: absent is empty, anything else is refused.
fn object_at(root: &Map<String, Value>, key: &str) -> Result<Map<String, Value>, String> {
    match root.get(key) {
        None => Ok(Map::new()),
        Some(Value::Object(m)) => Ok(m.clone()),
        Some(_) => Err(unexpected(&format!("\"{key}\""))),
    }
}

/// `hooks[event]` as a list to edit: absent is empty, anything else is refused.
fn list_at(hooks: &Map<String, Value>, event: &str) -> Result<Vec<Value>, String> {
    match hooks.get(event) {
        None => Ok(Vec::new()),
        Some(Value::Array(list)) => Ok(list.clone()),
        Some(_) => Err(unexpected(&format!("\"hooks\".\"{event}\""))),
    }
}

/// A command line written by Nova for `agent`.
fn is_our_command(command: Option<&Value>, agent: &str) -> bool {
    command
        .and_then(Value::as_str)
        .is_some_and(|c| c.contains(MARKER) && c.contains(&format!("--agent {agent}")))
}

/// Claude-style groups (`{"matcher"?, "hooks": [{"command"}]}`, or a legacy
/// flat `{"command"}`) without Nova's entries for `agent`. A group left
/// empty goes; everything else stays exactly as it was.
fn without_ours_in_groups(groups: &[Value], agent: &str) -> Vec<Value> {
    groups
        .iter()
        .filter_map(|group| {
            if is_our_command(group.get("command"), agent) {
                return None;
            }
            let Some(inner) = group.get("hooks").and_then(Value::as_array) else {
                return Some(group.clone());
            };
            let kept: Vec<Value> =
                inner.iter().filter(|h| !is_our_command(h.get("command"), agent)).cloned().collect();
            if kept.len() == inner.len() {
                return Some(group.clone());
            }
            if kept.is_empty() {
                return None;
            }
            let mut group = group.clone();
            group["hooks"] = Value::Array(kept);
            Some(group)
        })
        .collect()
}

/// `root` with one Nova group per event, built by `group(event)`. Earlier
/// Nova entries for `agent` are replaced; nobody else's are touched.
fn groups_install(
    root: &Value,
    agent: &str,
    events: impl IntoIterator<Item = (String, Value)>,
) -> Result<Map<String, Value>, String> {
    let mut root = root.as_object().cloned().unwrap_or_default();
    let mut hooks = object_at(&root, "hooks")?;
    for (event, group) in events {
        let mut list = without_ours_in_groups(&list_at(&hooks, &event)?, agent);
        list.push(group);
        hooks.insert(event, Value::Array(list));
    }
    root.insert("hooks".into(), Value::Object(hooks));
    Ok(root)
}

/// `root` without any Nova group for `agent`; an event left empty goes, and
/// so does `hooks` when nothing is left in it.
fn groups_uninstall(root: &Value, agent: &str) -> Result<Value, String> {
    let mut root = root.as_object().cloned().unwrap_or_default();
    if !root.contains_key("hooks") {
        return Ok(Value::Object(root));
    }
    let hooks = object_at(&root, "hooks")?;
    let mut out = Map::new();
    for (event, value) in hooks {
        match value.as_array() {
            Some(list) => {
                let kept = without_ours_in_groups(list, agent);
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
    Ok(Value::Object(root))
}

fn groups_have_ours(root: &Value, agent: &str) -> bool {
    let ours = |group: &Value| {
        is_our_command(group.get("command"), agent)
            || group
                .get("hooks")
                .and_then(Value::as_array)
                .is_some_and(|inner| inner.iter().any(|h| is_our_command(h.get("command"), agent)))
    };
    root.get("hooks")
        .and_then(Value::as_object)
        .is_some_and(|hooks| hooks.values().filter_map(Value::as_array).flatten().any(ours))
}

// ── Gemini CLI — ~/.gemini/settings.json ──────────────────────────────────────
//
// Claude-style groups with a `*` matcher and timeouts in milliseconds. The
// event name the relay should report goes on the command line. On Windows,
// Gemini CLI runs hooks with `powershell -Command`. AfterModel is left out: it
// fires on every response chunk and would flood the island.

const GEMINI_EVENTS: &[(&str, &str, u64)] = &[
    ("SessionStart", "SessionStart", 10000),
    ("SessionEnd", "SessionEnd", 10000),
    ("BeforeTool", "PreToolUse", 5000),
    ("AfterTool", "PostToolUse", 5000),
    ("BeforeAgent", "UserPromptSubmit", 5000),
    ("AfterAgent", "Stop", 5000),
];

fn gemini_install(root: &Value, commands: &[(String, String, u64)]) -> Result<Value, String> {
    let events = commands.iter().map(|(event, command, timeout)| {
        (
            event.clone(),
            json!({ "matcher": "*", "hooks": [{ "type": "command", "command": command, "timeout": timeout }] }),
        )
    });
    groups_install(root, "gemini", events).map(Value::Object)
}

// ── Antigravity — ~/.gemini/config/hooks.json ─────────────────────────────────
//
// Hooks are named groups at the top level; Nova's is `nova`. Tool events
// take matcher groups, lifecycle events take handlers directly; timeouts are
// in seconds. Merge and removal come from #298 (kobaltgit). The relay answers
// PreToolUse with "{}" — no decision — never with an allow: Antigravity's own
// permission rules stay in charge.

const ANTIGRAVITY_TOOL_EVENTS: &[&str] = &["PreToolUse", "PostToolUse"];
const ANTIGRAVITY_LIFECYCLE_EVENTS: &[&str] = &["PreInvocation", "PostInvocation", "Stop"];

fn antigravity_block(relay: &Relay) -> Value {
    let handler = |event: &str| {
        json!({
            "type": "command",
            "command": relay.command(Shell::Cmd, &format!("--agent antigravity {event}")),
            "timeout": 10,
        })
    };
    let mut block = Map::new();
    for event in ANTIGRAVITY_TOOL_EVENTS {
        block.insert((*event).into(), json!([{ "matcher": "*", "hooks": [handler(event)] }]));
    }
    for event in ANTIGRAVITY_LIFECYCLE_EVENTS {
        block.insert((*event).into(), json!([handler(event)]));
    }
    Value::Object(block)
}

/// A `nova` group Nova wrote (it runs the relay as `--agent antigravity`).
fn antigravity_is_ours(group: &Value) -> bool {
    let text = group.to_string();
    text.contains(MARKER) && text.contains("--agent antigravity")
}

fn antigravity_install(root: &Value, block: &Value) -> Result<Value, String> {
    let mut root = root.as_object().cloned().unwrap_or_default();
    if root.get("nova").is_some_and(|g| !antigravity_is_ours(g)) {
        return Err(crate::i18n::t("A hook group named \"nova\" that Nova did not write is already there — Nova has not touched it."));
    }
    root.insert("nova".into(), block.clone());
    Ok(Value::Object(root))
}

/// Removes Nova's group, and only if it is Nova's.
fn antigravity_uninstall(root: &Value) -> Result<Value, String> {
    let mut root = root.as_object().cloned().unwrap_or_default();
    if root.get("nova").is_some_and(antigravity_is_ours) {
        root.remove("nova");
    }
    Ok(Value::Object(root))
}

// ── Cursor Agent — ~/.cursor/hooks.json ───────────────────────────────────────
//
// `{"version": 1, "hooks": {"<event>": [{"command": …}]}}`, camelCase events
// (from #231, BeyondBirthday07). The relay maps them, turns a stop with
// `status: "error"` into StopFailure, and prints nothing back: no permission is
// ever given on Cursor's behalf. Every session lands on the one `agent_cursor`
// pill.

const CURSOR_EVENTS: &[&str] = &[
    "sessionStart",
    "sessionEnd",
    "beforeSubmitPrompt",
    "preToolUse",
    "postToolUse",
    "postToolUseFailure",
    "stop",
];

fn cursor_install(root: &Value, command: &str) -> Result<Value, String> {
    let events = CURSOR_EVENTS.iter().map(|e| (e.to_string(), json!({ "command": command })));
    let mut root = groups_install(root, "cursor", events)?;
    root.entry("version").or_insert(json!(1));
    Ok(Value::Object(root))
}

// ── Codex — ~/.codex/hooks.json ───────────────────────────────────────────────
//
// Claude-style groups without a matcher, timeouts in seconds; Codex sends the
// event name in the payload. PermissionRequest waits for the island (120 s,
// with a status line shown in Codex meanwhile) and is answered with Claude
// Code's hookSpecificOutput — only after a click. Codex runs hook commands with
// `cmd /C` on Windows and `$SHELL -lc` elsewhere, and only once the user has
// trusted them with /hooks.

const CODEX_EVENTS: &[(&str, u64)] = &[
    ("SessionStart", 10),
    ("UserPromptSubmit", 10),
    ("PreToolUse", 10),
    ("PermissionRequest", 120),
    ("PostToolUse", 10),
    ("Stop", 10),
    ("SubagentStart", 10),
    ("SubagentStop", 10),
    ("Interrupt", 3),
    ("SessionEnd", 3),
];

const CODEX_WAITING: &str = "Waiting for your answer in the island (Nova)";

fn codex_install(root: &Value, command: &str) -> Result<Value, String> {
    let events = CODEX_EVENTS.iter().map(|(event, timeout)| {
        let mut hook = json!({ "type": "command", "command": command, "timeout": timeout });
        if *event == "PermissionRequest" {
            hook["statusMessage"] = json!(CODEX_WAITING);
        }
        (event.to_string(), json!({ "hooks": [hook] }))
    });
    groups_install(root, "codex", events).map(Value::Object)
}

// ── GitHub Copilot CLI — ~/.copilot/hooks/nova.json ─────────────────────────
//
// A file of Nova's own in Copilot's hooks folder: camelCase events, each
// entry `{"type": "command", "bash": …, "timeoutSec": N}`, plus `powershell`
// on Windows, where Copilot runs that one. The event goes on the command line
// because Copilot does not put it in the payload. Copilot is fail-closed on
// permissionRequest: the relay always answers it with valid JSON — "ask" when
// nobody clicked. Removing the last of Nova's entries removes the file.

const COPILOT_EVENTS: &[(&str, u64)] = &[
    ("sessionStart", 10),
    ("userPromptSubmitted", 10),
    ("preToolUse", 10),
    ("permissionRequest", 120),
    ("postToolUse", 10),
    ("agentStop", 10),
    ("sessionEnd", 3),
    ("notification", 10),
];

fn copilot_entry(relay: &Relay, event: &str, timeout: u64) -> Value {
    let args = format!("--agent copilot {event}");
    let mut entry = json!({ "type": "command", "bash": relay.command(Shell::Sh, &args), "timeoutSec": timeout });
    if relay.windows {
        entry["powershell"] = json!(relay.command(Shell::PowerShell, &args));
    }
    entry
}

fn copilot_entry_is_ours(entry: &Value) -> bool {
    ["bash", "powershell", "command"].iter().any(|k| is_our_command(entry.get(*k), "copilot"))
}

fn copilot_install(root: &Value, entries: &[(String, Value)]) -> Result<Value, String> {
    let mut root = root.as_object().cloned().unwrap_or_default();
    let mut hooks = object_at(&root, "hooks")?;
    for (event, entry) in entries {
        let mut list = list_at(&hooks, event)?;
        list.retain(|e| !copilot_entry_is_ours(e));
        list.push(entry.clone());
        hooks.insert(event.clone(), Value::Array(list));
    }
    root.insert("hooks".into(), Value::Object(hooks));
    root.insert("version".into(), json!(1));
    Ok(Value::Object(root))
}

fn copilot_uninstall(root: &Value) -> Result<Option<Value>, String> {
    let mut root = root.as_object().cloned().unwrap_or_default();
    if root.contains_key("hooks") {
        let mut hooks = object_at(&root, "hooks")?;
        for list in hooks.values_mut() {
            if let Value::Array(entries) = list {
                entries.retain(|e| !copilot_entry_is_ours(e));
            }
        }
        hooks.retain(|_, v| !v.as_array().is_some_and(Vec::is_empty));
        if hooks.is_empty() {
            root.remove("hooks");
        } else {
            root.insert("hooks".into(), Value::Object(hooks));
        }
    }
    // Nothing of anyone else's left: the file was Nova's, and goes.
    if root.keys().all(|k| k == "version") {
        return Ok(None);
    }
    Ok(Some(Value::Object(root)))
}

// ── Muse Code — ~/.config/muse/settings.json ──────────────────────────────────
//
// Claude-style groups with a `*` matcher, PascalCase events, timeouts in
// milliseconds. Permission requests get the island's card and a bare
// permissionDecision back.

const MUSE_EVENTS: &[(&str, u64)] = &[
    ("SessionStart", 10),
    ("UserPromptSubmit", 5),
    ("PreToolUse", 5),
    ("PermissionRequest", 120),
    ("PostToolUse", 5),
    ("Stop", 5),
    ("SessionEnd", 3),
];

fn muse_install(root: &Value, commands: &[(String, String, u64)]) -> Result<Value, String> {
    let fresh = root.as_object().is_none_or(Map::is_empty);
    let events = commands.iter().map(|(event, command, timeout)| {
        (
            event.clone(),
            json!({ "matcher": "*", "hooks": [{ "type": "command", "command": command, "timeout": timeout }] }),
        )
    });
    let mut root = groups_install(root, "muse", events)?;
    if fresh {
        root.insert("schema_version".into(), json!(1));
    }
    Ok(Value::Object(root))
}

// ── Plugins: OpenCode, Amp, Hermes ────────────────────────────────────────────
//
// These agents load code rather than run hook commands. The Mac's plugins
// start `/bin/sh` on a script at a macOS path; these start the relay itself,
// at this machine's path, with no shell in between. Every one is
// fire-and-forget: the agent never waits on Nova, and if Nova is closed
// nothing happens. None of them ever answers a permission: Hermes keeps its
// approvals (as on the Mac), and Amp's steps come from `tool.result` so the
// plugin never has to return a verdict from `tool.call`.

/// Every plugin file Nova writes says so; only such a file is replaced or removed.
const GENERATED: &str = "generated by Nova";

fn is_our_plugin(text: &str) -> bool {
    text.contains(GENERATED)
}

fn plugin_edit(path: PathBuf, content: String, install: bool) -> FileEdit<'static> {
    let label = path.display().to_string();
    let name = label.clone();
    let edit = config_file::text_edit(label, move |current| match (install, current) {
        (_, Some(text)) if !is_our_plugin(text) => {
            Err(crate::i18n::tf("{name} wasn't written by Nova — Nova has not touched it.", &[("name", &name.to_string())]))
        }
        (true, _) => Ok(Some(content.clone())),
        (false, _) => Ok(None),
    });
    FileEdit { path, edit }
}

const OPENCODE_PLUGIN: &str = r#"// Nova plugin for OpenCode — generated by Nova.
// Forwards OpenCode's events to Nova's relay (nova-hook), fire-and-forget:
// OpenCode never waits on it, and nothing happens when Nova is closed.
import { spawn } from 'node:child_process';

const HOOK = {HOOK};
const EVENT_MAP = {
  'session.created': 'SessionStart',
  'session.idle': 'Stop',
  'session.error': 'StopFailure',
  'session.deleted': 'SessionEnd',
};

function forward(hook_event_name, payload) {
  try {
    const p = spawn(HOOK, ['--agent', 'opencode'], {
      stdio: ['pipe', 'ignore', 'ignore'],
      detached: process.platform !== 'win32',
      windowsHide: true,
    });
    p.on('error', () => {});
    p.stdin.on('error', () => {});
    p.stdin.end(JSON.stringify({ hook_event_name, ...payload }) + '\n');
    p.unref();
  } catch {}
}

export const NovaPlugin = async ({ directory } = {}) => ({
  event: async ({ event }) => {
    const hook_event_name = EVENT_MAP[event?.type];
    if (!hook_event_name) return;
    const props = event.properties || {};
    forward(hook_event_name, {
      session_id: props.sessionID || props.info?.id || '',
      cwd: directory || '',
    });
  },
  'tool.execute.before': async (input, output) => {
    forward('PreToolUse', {
      session_id: input?.sessionID || '',
      cwd: directory || '',
      tool_name: typeof input?.tool === 'string' ? input.tool : '',
      tool_input: output?.args ?? null,
    });
  },
  'tool.execute.after': async (input) => {
    forward('PostToolUse', {
      session_id: input?.sessionID || '',
      cwd: directory || '',
      tool_name: typeof input?.tool === 'string' ? input.tool : '',
    });
  },
});
"#;

const AMP_PLUGIN: &str = r#"// Nova plugin for Amp — generated by Nova.
// Forwards Amp's events to Nova's relay (nova-hook), fire-and-forget and
// display only: Amp never waits on it, and it never decides anything for Amp.
import { spawn } from 'node:child_process';

const HOOK = {HOOK};

function forward(hook_event_name: string, fields: Record<string, unknown>): void {
  try {
    const p = spawn(HOOK, ['--agent', 'amp'], {
      stdio: ['pipe', 'ignore', 'ignore'],
      detached: process.platform !== 'win32',
      windowsHide: true,
    });
    p.on('error', () => {});
    p.stdin?.on('error', () => {});
    p.stdin?.end(JSON.stringify({ hook_event_name, ...fields }) + '\n');
    p.unref();
  } catch {}
}

export default function (amp: any): void {
  const session = (e: any) => ({ session_id: e?.thread?.id ?? '' });
  amp.on('session.start', (e: any) => { forward('SessionStart', session(e)); });
  amp.on('agent.start', (e: any) => {
    forward('UserPromptSubmit', { ...session(e), prompt: typeof e?.message === 'string' ? e.message : '' });
  });
  // A step per tool once it has run: listening to tool.call would mean
  // returning a verdict for Amp, and Nova never makes one.
  amp.on('tool.result', (e: any) => {
    forward('PreToolUse', { ...session(e), tool_name: typeof e?.tool === 'string' ? e.tool : '', tool_input: e?.input ?? null });
  });
  amp.on('agent.end', (e: any) => { forward('Stop', { ...session(e), status: e?.status ?? '' }); });
}
"#;

const HERMES_PLUGIN: &str = r#"# Nova plugin for Hermes Agent — generated by Nova.
# Session and tool events go to Nova's relay (nova-hook), fire-and-forget:
# Hermes never waits on it, and keeps every approval decision to itself.
import json, os, subprocess, threading

HOOK = {HOOK}
_current_session_id = ''


def _fire(fields):
    """Non-blocking: start the relay and return at once. Reaps it in a thread."""
    def _run():
        try:
            extra = {'start_new_session': True} if os.name != 'nt' else {
                'creationflags': getattr(subprocess, 'CREATE_NO_WINDOW', 0)}
            p = subprocess.Popen([HOOK, '--agent', 'hermes'], stdin=subprocess.PIPE,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, **extra)
            p.stdin.write(json.dumps(fields).encode() + b'\n')
            p.stdin.close()
            p.wait(timeout=5)
        except Exception:
            pass
    threading.Thread(target=_run, daemon=True).start()


def register(ctx):
    def on_session_start(**kwargs):
        global _current_session_id
        sid = kwargs.get('session_id', '')
        _current_session_id = sid
        platform = kwargs.get('platform', 'cli') or 'cli'
        _fire({'hook_event_name': 'SessionStart', 'session_id': sid, 'platform': platform})

    def on_session_end(**kwargs):
        # Stop comes from post_llm_call, which has the last answer.
        if kwargs.get('interrupted'):
            _fire({'hook_event_name': 'StopFailure', 'session_id': kwargs.get('session_id', '')})

    def post_llm_call(**kwargs):
        _fire({'hook_event_name': 'Stop',
               'session_id': kwargs.get('session_id', '') or _current_session_id,
               'last_assistant_message': kwargs.get('assistant_response', '')})

    def pre_tool_call(**kwargs):
        _fire({'hook_event_name': 'PreToolUse',
               'session_id': kwargs.get('session_id', '') or _current_session_id,
               'tool_name': kwargs.get('tool_name', ''),
               'tool_input': kwargs.get('args') or {}})

    def post_tool_call(**kwargs):
        _fire({'hook_event_name': 'PostToolUse',
               'session_id': kwargs.get('session_id', '') or _current_session_id,
               'tool_name': kwargs.get('tool_name', '')})

    def pre_approval_request(**kwargs):
        # Observer only: Hermes asks and decides; the island just says so.
        _fire({'hook_event_name': 'PreToolUse',
               'session_id': kwargs.get('session_key', '') or _current_session_id,
               'tool_name': '⏳ Approval pending in Hermes',
               'tool_input': {'command': kwargs.get('command', ''),
                              'description': kwargs.get('description', '')}})

    ctx.register_hook('on_session_start', on_session_start)
    ctx.register_hook('on_session_end', on_session_end)
    ctx.register_hook('post_llm_call', post_llm_call)
    ctx.register_hook('pre_tool_call', pre_tool_call)
    ctx.register_hook('post_tool_call', post_tool_call)
    ctx.register_hook('pre_approval_request', pre_approval_request)
"#;

const HERMES_PLUGIN_YAML: &str = r#"name: nova
version: "1.0"
description: Nova island integration — generated by Nova
"#;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config_file::tests::scratch;

    fn linux() -> Relay {
        Relay { exe: "/home/me/.local/share/nova/bin/nova-hook".into(), windows: false }
    }

    fn windows(exe: &str) -> Relay {
        Relay { exe: exe.into(), windows: true }
    }

    const WIN: &str = r"C:\Users\me\AppData\Local\Nova\bin\nova-hook.exe";
    const WIN_SPACE: &str = r"C:\Users\Jane O'Neil\AppData\Local\Nova\bin\nova-hook.exe";

    /// Installs then uninstalls `agent` in a fresh home holding `existing` in
    /// its first file, and returns (installed file, uninstalled file).
    fn round_trip(agent: Agent, existing: Option<&str>) -> (PathBuf, Value, Option<Value>) {
        // Tests run in parallel: every round trip gets a home of its own.
        static RUN: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let run = RUN.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let home = scratch(&format!("agent-{}-{run}", agent.id()));
        let file = agent.files(&home)[0].clone();
        if let Some(text) = existing {
            std::fs::create_dir_all(file.parent().unwrap()).unwrap();
            std::fs::write(&file, text).unwrap();
        }
        let relay = linux();
        let plan = config_file::preview(&agent.edits(&home, &relay, true)).unwrap();
        assert!(plan.diff.contains(MARKER), "{}", plan.diff);
        apply_in(agent, &home, &relay, true, &plan.fingerprint).unwrap();
        assert!(agent.installed(&home), "{agent:?} should read as installed");
        let installed = read_json(&file);

        let plan = config_file::preview(&agent.edits(&home, &relay, false)).unwrap();
        apply_in(agent, &home, &relay, false, &plan.fingerprint).unwrap();
        assert!(!agent.installed(&home), "{agent:?} should read as removed");
        let removed = file.exists().then(|| read_json(&file));
        (home, installed, removed)
    }

    fn read_json(path: &Path) -> Value {
        serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
    }

    #[test]
    fn the_command_is_quoted_for_the_shell_that_runs_it() {
        assert_eq!(
            linux().command(Shell::Cmd, "--agent codex"),
            "'/home/me/.local/share/nova/bin/nova-hook' --agent codex"
        );
        let w = windows(WIN);
        assert_eq!(
            w.command(Shell::Sh, "Stop"),
            "\"C:/Users/me/AppData/Local/Nova/bin/nova-hook.exe\" Stop"
        );
        assert_eq!(
            w.command(Shell::PowerShell, "--agent gemini Stop"),
            format!("& '{WIN}' --agent gemini Stop")
        );
        // A plain path is left bare, so cmd and PowerShell both run it.
        assert_eq!(w.command(Shell::Cmd, "--agent cursor"), format!("{WIN} --agent cursor"));

        let spaced = windows(WIN_SPACE);
        assert_eq!(spaced.command(Shell::Cmd, "x"), format!("\"{WIN_SPACE}\" x"));
        assert_eq!(
            spaced.command(Shell::PowerShell, "x"),
            r"& 'C:\Users\Jane O''Neil\AppData\Local\Nova\bin\nova-hook.exe' x"
        );
    }

    #[test]
    fn the_hook_path_is_one_shell_word_whatever_it_contains() {
        assert_eq!(sh_quote("/home/a b/x"), "'/home/a b/x'");
        assert_eq!(sh_quote(r#"/h/$(id)`x`\"y"#), r#"'/h/$(id)`x`\"y'"#);
        assert_eq!(sh_quote("/h/it's"), r"'/h/it'\''s'");
    }

    #[test]
    fn every_agent_id_is_a_valid_pill_name() {
        for agent in Agent::ALL {
            let id = agent.id();
            assert!(id.len() <= 24 && id.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-'));
            assert_eq!(Agent::from_id(id), Some(*agent));
        }
        assert!(find("claude").is_err());
    }

    #[test]
    fn gemini_keeps_foreign_hooks_and_removes_only_its_own() {
        let existing = r#"{"theme":"dark","hooks":{"BeforeTool":[{"matcher":"other","hooks":[{"type":"command","command":"custom.exe"}]}]}}"#;
        let (home, installed, removed) = round_trip(Agent::Gemini, Some(existing));
        assert_eq!(installed["theme"], "dark");
        let before_tool = installed["hooks"]["BeforeTool"].as_array().unwrap();
        assert_eq!(before_tool.len(), 2);
        assert_eq!(before_tool[0]["matcher"], "other");
        assert_eq!(before_tool[1]["matcher"], "*");
        assert_eq!(before_tool[1]["hooks"][0]["timeout"], 5000);
        let cmd = before_tool[1]["hooks"][0]["command"].as_str().unwrap();
        assert!(cmd.ends_with("--agent gemini PreToolUse"), "{cmd}");
        assert!(installed["hooks"]["AfterModel"].is_null());
        assert_eq!(removed.unwrap(), serde_json::from_str::<Value>(existing).unwrap());
        let _ = std::fs::remove_dir_all(home);
    }

    #[test]
    fn installing_twice_leaves_one_entry_per_event() {
        let once = gemini_install(&json!({}), &[("BeforeTool".into(), "'x/nova-hook' --agent gemini PreToolUse".into(), 5000)]).unwrap();
        let twice = gemini_install(&once, &[("BeforeTool".into(), "'y/nova-hook' --agent gemini PreToolUse".into(), 5000)]).unwrap();
        assert_eq!(twice["hooks"]["BeforeTool"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn unexpected_types_are_refused_for_every_json_agent() {
        for agent in Agent::ALL {
            let home = scratch(&format!("odd-{}", agent.id()));
            let file = agent.files(&home)[0].clone();
            if file.extension().is_some_and(|e| e == "json") {
                std::fs::create_dir_all(file.parent().unwrap()).unwrap();
                let shaped: &[&str] = match agent {
                    Agent::Antigravity => &[r#"{"nova":"nope"}"#],
                    _ => &[r#"{"hooks":"nope"}"#, r#"{"hooks":[1]}"#],
                };
                for odd in shaped.iter().copied().chain(["[1,2]", "{ broken", "\"text\""]) {
                    std::fs::write(&file, odd).unwrap();
                    let edits = agent.edits(&home, &linux(), true);
                    assert!(config_file::preview(&edits).is_err(), "{agent:?} accepted {odd}");
                    assert_eq!(std::fs::read_to_string(&file).unwrap(), odd);
                }
            }
            let _ = std::fs::remove_dir_all(home);
        }
    }

    #[test]
    fn antigravity_gets_its_own_named_group_and_nothing_else_changes() {
        let existing = r#"{"my-guard":{"PreToolUse":[{"matcher":"run_command","hooks":[{"command":"/bin/guard"}]}]}}"#;
        let (home, installed, removed) = round_trip(Agent::Antigravity, Some(existing));
        assert_eq!(installed["my-guard"]["PreToolUse"][0]["matcher"], "run_command");
        let ours = &installed["nova"];
        for event in ANTIGRAVITY_TOOL_EVENTS {
            assert_eq!(ours[event][0]["matcher"], "*");
            let cmd = ours[event][0]["hooks"][0]["command"].as_str().unwrap();
            assert!(cmd.ends_with(&format!("--agent antigravity {event}")), "{cmd}");
        }
        for event in ANTIGRAVITY_LIFECYCLE_EVENTS {
            assert_eq!(ours[event][0]["timeout"], 10);
            assert!(ours[event][0]["command"].as_str().unwrap().contains(MARKER));
        }
        assert_eq!(removed.unwrap(), serde_json::from_str::<Value>(existing).unwrap());
        let _ = std::fs::remove_dir_all(home);
    }

    #[test]
    fn a_nova_group_someone_else_wrote_is_neither_replaced_nor_removed() {
        let theirs = json!({ "nova": { "Stop": [{ "command": "/bin/notify" }] } });
        assert!(antigravity_install(&theirs, &antigravity_block(&linux())).is_err());
        assert_eq!(antigravity_uninstall(&theirs).unwrap(), theirs);
    }

    #[test]
    fn on_windows_antigravity_runs_the_relay_path_quoted_only_when_needed() {
        let block = antigravity_block(&windows(WIN));
        assert_eq!(block["Stop"][0]["command"], format!("{WIN} --agent antigravity Stop"));
        let block = antigravity_block(&windows(WIN_SPACE));
        assert_eq!(block["Stop"][0]["command"], format!("\"{WIN_SPACE}\" --agent antigravity Stop"));
    }

    #[test]
    fn cursor_uses_its_native_format_and_keeps_the_users_hooks() {
        let existing = r#"{"version":1,"hooks":{"afterFileEdit":[{"command":"./format.sh"}],"stop":[{"command":"./notify.sh"}]}}"#;
        let (home, installed, removed) = round_trip(Agent::Cursor, Some(existing));
        assert_eq!(installed["version"], 1);
        for event in CURSOR_EVENTS {
            let last = installed["hooks"][event].as_array().unwrap().last().unwrap().clone();
            assert!(last["command"].as_str().unwrap().ends_with("--agent cursor"), "{event}");
        }
        assert_eq!(installed["hooks"]["stop"][0]["command"], "./notify.sh");
        assert_eq!(installed["hooks"]["afterFileEdit"][0]["command"], "./format.sh");
        assert_eq!(removed.unwrap(), serde_json::from_str::<Value>(existing).unwrap());
        let _ = std::fs::remove_dir_all(home);
    }

    #[test]
    fn a_new_cursor_file_gets_its_version() {
        let after = cursor_install(&json!({}), "'x/nova-hook' --agent cursor").unwrap();
        assert_eq!(after["version"], 1);
        // A version the user set is theirs.
        let after = cursor_install(&json!({ "version": 2 }), "c").unwrap();
        assert_eq!(after["version"], 2);
    }

    #[test]
    fn codex_hooks_match_the_macs_and_leave_the_rest_alone() {
        let existing = r#"{"description":"mine","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"guard.sh"}]}]}}"#;
        let (home, installed, removed) = round_trip(Agent::Codex, Some(existing));
        assert_eq!(installed["description"], "mine");
        for (event, timeout) in CODEX_EVENTS {
            let ours = installed["hooks"][event].as_array().unwrap().last().unwrap()["hooks"][0].clone();
            assert_eq!(ours["timeout"], *timeout, "{event}");
            assert!(ours["command"].as_str().unwrap().ends_with("--agent codex"), "{event}");
            assert_eq!(ours.get("statusMessage").is_some(), *event == "PermissionRequest");
        }
        assert_eq!(installed["hooks"]["PreToolUse"][0]["matcher"], "Bash");
        assert_eq!(removed.unwrap(), serde_json::from_str::<Value>(existing).unwrap());
        assert!(Agent::Codex.approvals());
        let _ = std::fs::remove_dir_all(home);
    }

    #[test]
    fn on_windows_codex_gets_a_command_cmd_can_run() {
        let after = codex_install(&json!({}), &windows(WIN_SPACE).command(Shell::Cmd, "--agent codex")).unwrap();
        assert_eq!(after["hooks"]["Stop"][0]["hooks"][0]["command"], format!("\"{WIN_SPACE}\" --agent codex"));
    }

    #[test]
    fn copilot_gets_a_file_of_its_own_which_goes_when_nova_leaves() {
        let (home, installed, removed) = round_trip(Agent::Copilot, None);
        assert_eq!(installed["version"], 1);
        for (event, timeout) in COPILOT_EVENTS {
            let entry = &installed["hooks"][event][0];
            assert_eq!(entry["timeoutSec"], *timeout);
            assert!(entry["bash"].as_str().unwrap().ends_with(&format!("--agent copilot {event}")));
            // No PowerShell line on Linux.
            assert!(entry.get("powershell").is_none());
        }
        assert!(removed.is_none(), "the file should be gone");
        let _ = std::fs::remove_dir_all(home);
    }

    #[test]
    fn copilot_keeps_what_someone_else_added_to_the_file() {
        let existing = r#"{"version":1,"hooks":{"sessionStart":[{"type":"command","bash":"echo hi","timeoutSec":5}]}}"#;
        let (home, installed, removed) = round_trip(Agent::Copilot, Some(existing));
        assert_eq!(installed["hooks"]["sessionStart"].as_array().unwrap().len(), 2);
        assert_eq!(removed.unwrap(), serde_json::from_str::<Value>(existing).unwrap());
        let _ = std::fs::remove_dir_all(home);
    }

    #[test]
    fn on_windows_copilot_gets_a_powershell_line_too() {
        let entry = copilot_entry(&windows(WIN), "preToolUse", 10);
        assert_eq!(entry["powershell"], format!("& '{WIN}' --agent copilot preToolUse"));
        assert_eq!(
            entry["bash"],
            "\"C:/Users/me/AppData/Local/Nova/bin/nova-hook.exe\" --agent copilot preToolUse"
        );
    }

    #[test]
    fn muse_hooks_use_milliseconds_and_a_schema_version_for_a_new_file() {
        let (home, installed, removed) = round_trip(Agent::Muse, None);
        assert_eq!(installed["schema_version"], 1);
        assert_eq!(installed["hooks"]["PermissionRequest"][0]["hooks"][0]["timeout"], 120_000);
        assert_eq!(installed["hooks"]["PreToolUse"][0]["matcher"], "*");
        assert!(installed["hooks"]["Stop"][0]["hooks"][0]["command"].as_str().unwrap().ends_with("--agent muse Stop"));
        // Only Nova's hooks go; the file and its schema_version stay.
        assert_eq!(removed.unwrap(), json!({ "schema_version": 1 }));
        let _ = std::fs::remove_dir_all(home);

        let existing = r#"{"model":"m","hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"say done"}]}]}}"#;
        let (home, installed, removed) = round_trip(Agent::Muse, Some(existing));
        assert!(installed.get("schema_version").is_none());
        assert_eq!(removed.unwrap(), serde_json::from_str::<Value>(existing).unwrap());
        let _ = std::fs::remove_dir_all(home);
    }

    #[test]
    fn only_codex_copilot_and_muse_take_approvals() {
        let with: Vec<&str> = Agent::ALL.iter().filter(|a| a.approvals()).map(|a| a.id()).collect();
        assert_eq!(with, ["codex", "copilot", "muse"]);
    }

    #[test]
    fn plugins_call_the_relay_directly_and_go_away_whole() {
        for agent in [Agent::OpenCode, Agent::Amp, Agent::Hermes] {
            let home = scratch(&format!("plugin-{}", agent.id()));
            let relay = linux();
            let plan = config_file::preview(&agent.edits(&home, &relay, true)).unwrap();
            apply_in(agent, &home, &relay, true, &plan.fingerprint).unwrap();
            assert!(agent.installed(&home), "{agent:?}");
            let main = std::fs::read_to_string(&agent.files(&home)[0]).unwrap();
            // The relay itself, at this machine's path, as a string literal: no
            // shell, no macOS path.
            assert!(main.contains(r#""/home/me/.local/share/nova/bin/nova-hook""#), "{agent:?}");
            assert!(!main.contains("/bin/sh") && !main.contains("nb-hook"), "{agent:?}");
            assert!(main.contains(&format!("'--agent', '{}'", agent.id())), "{agent:?}");
            // Never a verdict for the agent.
            assert!(!main.contains("action: 'allow'") && !main.contains("register_approval_transport"));

            let plan = config_file::preview(&agent.edits(&home, &relay, false)).unwrap();
            apply_in(agent, &home, &relay, false, &plan.fingerprint).unwrap();
            assert!(!agent.installed(&home));
            for file in agent.files(&home) {
                assert!(!file.exists(), "{}", file.display());
            }
            let _ = std::fs::remove_dir_all(home);
        }
    }

    #[test]
    fn a_plugin_file_nova_did_not_write_is_left_alone() {
        let home = scratch("plugin-foreign");
        let file = Agent::OpenCode.files(&home)[0].clone();
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(&file, "export const Mine = async () => ({});\n").unwrap();
        for install in [true, false] {
            let err = config_file::preview(&Agent::OpenCode.edits(&home, &linux(), install)).unwrap_err();
            assert!(err.contains("wasn't written by Nova"), "{err}");
        }
        assert_eq!(std::fs::read_to_string(&file).unwrap(), "export const Mine = async () => ({});\n");
        let _ = std::fs::remove_dir_all(home);
    }

    #[test]
    fn a_windows_path_is_a_valid_string_in_every_plugin() {
        let plugins = Agent::Hermes.plugin(&windows(WIN_SPACE)).unwrap();
        let literal = serde_json::to_string(WIN_SPACE).unwrap();
        assert!(plugins[0].contains(&format!("HOOK = {literal}")));
        assert!(literal.contains(r"C:\\Users\\Jane O'Neil"));
        // plugin.yaml is ours too, so removing it is allowed.
        assert!(is_our_plugin(&plugins[1]));
    }

    #[test]
    fn another_tools_entry_for_an_event_with_the_wrong_shape_is_refused() {
        let odd = json!({ "hooks": { "BeforeTool": { "matcher": "x" } } });
        assert!(gemini_install(&odd, &[("BeforeTool".into(), "c".into(), 1)]).is_err());
    }
}
