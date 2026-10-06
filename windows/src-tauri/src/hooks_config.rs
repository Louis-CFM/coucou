//! Pure, testable hook configuration edits. Never runs a hook or changes trust.

use std::fs::OpenOptions;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{atomic::{AtomicU64, Ordering}, Mutex};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

#[derive(Clone, Copy, Debug, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum HookAgent {
    #[default]
    Claude,
    Codex,
}

const CLAUDE_EVENTS: &[(&str, u64)] = &[
    ("SessionStart", 10), ("SessionEnd", 10), ("UserPromptSubmit", 10),
    ("PreToolUse", 10), ("PostToolUse", 10), ("PostToolUseFailure", 10),
    ("PermissionRequest", 120), ("Notification", 10), ("Stop", 10),
    ("StopFailure", 10), ("SubagentStart", 10), ("SubagentStop", 10),
];

// Codex caps SessionEnd and Interrupt at three seconds. The relay normally
// exits immediately if Coucou is absent; only approval waits for a human.
const CODEX_EVENTS: &[(&str, u64)] = &[
    ("SessionStart", 10), ("SessionEnd", 3), ("UserPromptSubmit", 10),
    ("PreToolUse", 10), ("PostToolUse", 10), ("PermissionRequest", 120),
    ("Stop", 10), ("SubagentStart", 10), ("SubagentStop", 10), ("Interrupt", 3),
];

impl HookAgent {
    fn events(self) -> &'static [(&'static str, u64)] {
        match self { Self::Claude => CLAUDE_EVENTS, Self::Codex => CODEX_EVENTS }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HookPreview {
    pub diff: String,
    pub backup: String,
    pub settings_path: String,
    /// Binds the reviewed bytes, operation, agent, paths and proposed result.
    pub fingerprint: String,
}

pub struct HookConfig {
    pub agent: HookAgent,
    pub path: PathBuf,
    pub hook_path: PathBuf,
}

/// Resolve an explicit CODEX_HOME in the same working directory as Coucou.
/// Never silently substitute the current directory for a missing user profile.
pub fn config_path(
    agent: HookAgent,
    user_profile: Option<PathBuf>,
    codex_home: Option<PathBuf>,
) -> Result<PathBuf, String> {
    let codex_home = codex_home.filter(|path| !path.as_os_str().is_empty());
    let directory = match (agent, codex_home) {
        (HookAgent::Codex, Some(path)) => path,
        _ => {
            let home = user_profile.filter(|path| path.is_absolute())
                .ok_or("The user home must name an absolute directory; Coucou won't guess a hook configuration location")?;
            home.join(if agent == HookAgent::Codex { ".codex" } else { ".claude" })
        }
    };
    let filename = if agent == HookAgent::Codex { "hooks.json" } else { "settings.json" };
    std::path::absolute(directory.join(filename))
        .map_err(|err| format!("Can't resolve the hook configuration location: {err}"))
}

struct Snapshot {
    bytes: Option<Vec<u8>>,
    value: Value,
}

fn parse(bytes: &[u8], path: &Path) -> Result<Value, String> {
    let bytes = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(bytes);
    let value: Value = serde_json::from_slice(bytes)
        .map_err(|err| format!("{} isn't valid JSON ({err}). Coucou won't overwrite it.", path.display()))?;
    validate(&value).map_err(|err| format!("{}: {err}. Coucou won't overwrite it.", path.display()))?;
    Ok(value)
}

fn validate(value: &Value) -> Result<(), String> {
    let root = value.as_object().ok_or("configuration must be a JSON object")?;
    if let Some(hooks) = root.get("hooks") {
        let hooks = hooks.as_object().ok_or("hooks must be an object")?;
        for (event, groups) in hooks {
            let groups = groups.as_array().ok_or_else(|| format!("hooks.{event} must be an array"))?;
            for group in groups {
                let group = group.as_object().ok_or_else(|| format!("hooks.{event} contains a non-object group"))?;
                let handlers = group.get("hooks").and_then(Value::as_array)
                    .ok_or_else(|| format!("hooks.{event} group must contain a hooks array"))?;
                for handler in handlers {
                    let handler = handler.as_object().ok_or_else(|| format!("hooks.{event} contains a non-object handler"))?;
                    let kind = handler.get("type").and_then(Value::as_str)
                        .ok_or_else(|| format!("hooks.{event} handler must have a type"))?;
                    if kind == "command" && handler.get("command").and_then(Value::as_str).is_none() {
                        return Err(format!("hooks.{event} command handler must have a command string"));
                    }
                }
            }
        }
    }
    Ok(())
}

impl HookConfig {
    fn validate_paths(&self) -> Result<(), String> {
        if !self.path.is_absolute() {
            return Err("Hook configuration must use an absolute path".into());
        }
        if !self.hook_path.is_absolute() {
            return Err("The hook relay must use an absolute path; check LOCALAPPDATA".into());
        }
        #[cfg(windows)]
        let executable = self.hook_path.to_str().ok_or("The hook relay path isn't valid Unicode")?;
        // Both agents pass this through a shell. Quotes protect spaces and '&'
        // but not cmd.exe %variables% / delayed !variables!, or Bash $() and
        // backticks. Refuse these uncommon installation paths instead of
        // guessing at cross-shell escaping or executing a different command.
        #[cfg(windows)]
        let unsafe_path = executable.chars().any(|ch| {
            matches!(ch, '"' | '\r' | '\n' | '\0') || match self.agent {
                HookAgent::Codex => matches!(ch, '%' | '!'),
                HookAgent::Claude => matches!(ch, '$' | '`'),
            }
        });
        #[cfg(windows)]
        if unsafe_path {
            return Err("The hook relay path contains shell expansion characters. Move Coucou to a path without them before installing hooks".into());
        }
        Ok(())
    }

    fn read(&self) -> Result<Snapshot, String> {
        self.validate_paths()?;
        match std::fs::read(&self.path) {
            Ok(bytes) => Ok(Snapshot { value: parse(&bytes, &self.path)?, bytes: Some(bytes) }),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(Snapshot { bytes: None, value: json!({}) }),
            Err(err) => Err(format!("Can't read {}: {err}", self.path.display())),
        }
    }

    fn command(&self, event: &str) -> String {
        let path = self.hook_path.to_string_lossy();
        #[cfg(windows)]
        let exe = format!("\"{}\"", path.replace('\\', "/"));
        #[cfg(unix)]
        let exe = format!("'{}'", path.replace('\'', "'\\''"));
        match self.agent {
            HookAgent::Claude => format!("{exe} {event}"),
            HookAgent::Codex => format!("{exe} --agent codex {event}"),
        }
    }

    fn owns(&self, event: &str, handler: &Value) -> bool {
        // Never use a substring marker: a logger mentioning coucou-hook is not
        // ours. A changed Windows override is another command, so preserve it.
        self.agent.events().iter().any(|(name, _)| *name == event)
            && handler.get("type").and_then(Value::as_str) == Some("command")
            && handler.get("command").and_then(Value::as_str) == Some(self.command(event).as_str())
            && ["commandWindows", "command_windows"].iter().all(|key| {
                handler.get(*key).map_or(true, |v| v.as_str() == Some(self.command(event).as_str()))
            })
    }

    fn changed(&self, current: &Value, install: bool) -> Value {
        let mut next = current.clone();
        if let Some(hooks) = next.get_mut("hooks").and_then(Value::as_object_mut) {
            let had_events = !hooks.is_empty();
            hooks.retain(|event, groups| {
                let groups = groups.as_array_mut().expect("validated hook groups");
                let was_empty = groups.is_empty();
                groups.retain_mut(|group| {
                    let handlers = group["hooks"].as_array_mut().expect("validated handlers");
                    let previous_len = handlers.len();
                    handlers.retain(|handler| !self.owns(event, handler));
                    // Preserve empty foreign groups, and all metadata / foreign
                    // handlers when one matcher group contains several hooks.
                    previous_len == handlers.len() || !handlers.is_empty()
                });
                was_empty || !groups.is_empty()
            });
            if had_events && hooks.is_empty() {
                next.as_object_mut().unwrap().remove("hooks");
            }
        }
        if install {
            let hooks = next.as_object_mut().unwrap().entry("hooks").or_insert_with(|| json!({}));
            for (event, timeout) in self.agent.events() {
                let groups = hooks.as_object_mut().unwrap().entry(*event).or_insert_with(|| json!([]));
                groups.as_array_mut().unwrap().push(json!({ "hooks": [{
                    "type": "command", "command": self.command(event), "timeout": timeout,
                }] }));
            }
        }
        next
    }

    pub fn installed(&self) -> Result<bool, String> {
        let snapshot = self.read()?;
        Ok(snapshot.value.get("hooks").and_then(Value::as_object).is_some_and(|hooks| {
            hooks.iter().any(|(event, groups)| groups.as_array().unwrap().iter()
                .any(|group| group["hooks"].as_array().unwrap().iter().any(|handler| self.owns(event, handler))))
        }))
    }

    fn fingerprint(&self, snapshot: &Snapshot, install: bool) -> String {
        // Hash a structured envelope, including missing-vs-existing state. Read
        // once: hashing a second read could approve bytes different from the diff.
        let envelope = json!([
            format!("{:?}", self.agent), self.path, self.hook_path, install,
            snapshot.bytes, self.changed(&snapshot.value, install),
        ]);
        let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
        for b in serde_json::to_vec(&envelope).expect("JSON envelope") {
            hash ^= b as u64;
            hash = hash.wrapping_mul(0x100_0000_01b3);
        }
        format!("{hash:016x}")
    }

    fn backup_base(&self, stamp: &str) -> PathBuf {
        let name = self.path.file_name().unwrap_or_default().to_string_lossy();
        self.path.with_file_name(format!("{name}.bak-{stamp}"))
    }

    pub fn preview(&self, install: bool, stamp: &str) -> Result<HookPreview, String> {
        let current = self.read()?;
        let next = self.changed(&current.value, install);
        Ok(HookPreview {
            diff: unified_diff(&pretty(&current.value), &pretty(&next)),
            backup: self.backup_base(stamp).to_string_lossy().into_owned(),
            settings_path: self.path.to_string_lossy().into_owned(),
            fingerprint: self.fingerprint(&current, install),
        })
    }

    pub fn write(&self, install: bool, fingerprint: &str, stamp: &str) -> Result<String, String> {
        self.write_checked(install, fingerprint, stamp, || {})
    }

    fn write_checked(&self, install: bool, fingerprint: &str, stamp: &str, before_replace: impl FnOnce()) -> Result<String, String> {
        static WRITES: Mutex<()> = Mutex::new(());
        let _lock = WRITES.lock().map_err(|_| "Hook configuration writer is unavailable")?;
        let current = self.read()?;
        let stale = || format!("{} changed since the preview. Nothing was written â€” review the new diff.", self.path.display());
        if self.fingerprint(&current, install) != fingerprint { return Err(stale()); }
        let next = self.changed(&current.value, install);
        if next == current.value { return Ok(String::new()); }
        let dir = self.path.parent().ok_or("Hook configuration has no parent directory")?;
        std::fs::create_dir_all(dir).map_err(|err| err.to_string())?;

        let backup = if let Some(bytes) = current.bytes.as_deref() {
            // create_new reserves a distinct backup, even for repeated changes
            // within one second. Copy the reviewed bytes, never a second read.
            let (path, mut file) = unique_file(&self.backup_base(stamp))?;
            file.write_all(bytes).and_then(|_| file.sync_all()).map_err(|err| format!("backup failed: {err}"))?;
            path.to_string_lossy().into_owned()
        } else { String::new() };

        let (temp, mut file) = unique_file(&self.path.with_extension("json.coucou-tmp"))?;
        let write_result = (|| {
            file.write_all(format!("{}\n", pretty(&next)).as_bytes())
                .and_then(|_| file.sync_all()).map_err(|err| format!("write failed: {err}"))?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let mode = std::fs::metadata(&self.path)
                    .map(|m| m.permissions().mode() & 0o777).unwrap_or(0o600);
                file.set_permissions(std::fs::Permissions::from_mode(mode))
                    .map_err(|err| format!("permissions failed: {err}"))?;
            }
            drop(file);
            before_replace();
            // Catch edits made during backup / serialization as well as stale
            // previews. Other applications do not participate in our mutex.
            if self.read()?.bytes != current.bytes { return Err(stale()); }
            std::fs::rename(&temp, &self.path).map_err(|err| format!("write failed: {err}"))
        })();
        if write_result.is_err() { let _ = std::fs::remove_file(&temp); }
        write_result?;
        Ok(backup)
    }
}

#[cfg(all(test, windows))]
mod tests {
    use super::*;
    use std::ops::Deref;

    struct TestConfig { dir: PathBuf, config: HookConfig }

    impl TestConfig {
        fn new(agent: HookAgent) -> Self {
            static NEXT: AtomicU64 = AtomicU64::new(0);
            let nonce = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
            let dir = std::env::temp_dir().join(format!("coucou-hooks-{}-{nonce}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)));
            std::fs::create_dir(&dir).unwrap();
            let config = HookConfig {
                agent,
                path: dir.join("hooks.json"),
                hook_path: PathBuf::from("C:/Test User/AppData/Local/Coucou/bin/coucou-hook.exe"),
            };
            Self { dir, config }
        }
    }
    impl Deref for TestConfig { type Target = HookConfig; fn deref(&self) -> &Self::Target { &self.config } }
    impl Drop for TestConfig { fn drop(&mut self) { let _ = std::fs::remove_dir_all(&self.dir); } }

    #[test]
    fn parses_a_powershell_utf8_bom() {
        let mut bytes = vec![0xef, 0xbb, 0xbf];
        bytes.extend_from_slice(br#"{"theme":"dark","hooks":{}}"#);
        assert_eq!(parse(&bytes, Path::new("test.json")).unwrap()["theme"], "dark");
    }

    #[test]
    fn resolves_codex_home_without_changing_process_environment() {
        let profile = PathBuf::from("C:/Test User");
        assert_eq!(config_path(HookAgent::Claude, Some(profile.clone()), Some(PathBuf::from("C:/Codex"))).unwrap(), profile.join(".claude/settings.json"));
        assert_eq!(config_path(HookAgent::Codex, Some(profile.clone()), None).unwrap(), profile.join(".codex/hooks.json"));
        assert_eq!(config_path(HookAgent::Codex, None, Some(PathBuf::from("C:/Custom Codex"))).unwrap(), PathBuf::from("C:/Custom Codex/hooks.json"));
        let relative = config_path(HookAgent::Codex, None, Some(PathBuf::from("custom-codex"))).unwrap();
        assert!(relative.is_absolute());
        assert_eq!(relative, std::env::current_dir().unwrap().join("custom-codex/hooks.json"));
        assert!(config_path(HookAgent::Claude, None, None).is_err());
        assert!(config_path(HookAgent::Codex, Some(PathBuf::from("relative-profile")), None).is_err());
    }

    #[test]
    fn refuses_relay_paths_that_shells_would_expand() {
        for (agent, unsafe_names) in [
            (HookAgent::Codex, ["%PATH%", "!PATH!", "broken\npath", "broken\"path"]),
            (HookAgent::Claude, ["$(command)", "`command`", "broken\rpath", "broken\"path"]),
        ] {
            let mut config = TestConfig::new(agent);
            for name in unsafe_names {
                config.config.hook_path = PathBuf::from(format!("C:/{name}/coucou-hook.exe"));
                assert!(config.preview(true, "20260930-120000").is_err());
                assert!(config.write(true, "anything", "20260930-120000").is_err());
                assert_eq!(std::fs::read_dir(&config.dir).unwrap().count(), 0);
            }
            config.config.hook_path = PathBuf::from("relative/coucou-hook.exe");
            assert!(config.validate_paths().is_err());
            config.config.hook_path = PathBuf::from("C:/Test User & Team/coucou-hook.exe");
            assert!(config.validate_paths().is_ok(), "quoted spaces and ampersands are literal");
        }
    }

    #[test]
    fn refuses_malformed_json_and_hook_structure_without_writing() {
        let config = TestConfig::new(HookAgent::Codex);
        for bytes in [b"".as_slice(), b"  ", b"{ broken", b"[]", b"null",
            br#"{"hooks":[]}"#, br#"{"hooks":{"Stop":{}}}"#,
            br#"{"hooks":{"Stop":[null]}}"#, br#"{"hooks":{"Stop":[{}]}}"#,
            br#"{"hooks":{"Stop":[{"hooks":[{}]}]}}"#,
            br#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":42}]}]}}"#] {
            std::fs::write(&config.path, bytes).unwrap();
            assert!(config.preview(true, "20260930-120000").is_err());
            assert!(config.write(true, "anything", "20260930-120000").is_err());
            assert_eq!(std::fs::read(&config.path).unwrap(), bytes);
            assert_eq!(std::fs::read_dir(&config.dir).unwrap().count(), 1, "must not create a backup or temp for malformed input");
        }
    }

    #[test]
    fn codex_uses_supported_events_and_short_shutdown_timeouts() {
        let config = TestConfig::new(HookAgent::Codex);
        let next = config.changed(&json!({}), true);
        let hooks = next["hooks"].as_object().unwrap();
        assert_eq!(hooks.len(), 10);
        for event in ["Notification", "PostToolUseFailure", "StopFailure"] { assert!(!hooks.contains_key(event)); }
        for event in ["Interrupt", "SessionEnd"] { assert_eq!(hooks[event][0]["hooks"][0]["timeout"], 3); }
        assert_eq!(hooks["PermissionRequest"][0]["hooks"][0]["timeout"], 120);
        assert_eq!(hooks["Stop"][0]["hooks"][0]["command"], "\"C:/Test User/AppData/Local/Coucou/bin/coucou-hook.exe\" --agent codex Stop");
        assert_eq!(config.changed(&next, true), next, "install must be idempotent");
    }

    #[test]
    fn claude_command_and_events_stay_compatible() {
        let config = TestConfig::new(HookAgent::Claude);
        let next = config.changed(&json!({}), true);
        assert_eq!(next["hooks"].as_object().unwrap().len(), 12);
        assert_eq!(next["hooks"]["Stop"][0]["hooks"][0]["command"], "\"C:/Test User/AppData/Local/Coucou/bin/coucou-hook.exe\" Stop");
        assert!(next["hooks"]["Notification"].is_array());
        assert_eq!(config.changed(&next, false), json!({}));
    }

    #[test]
    fn preserves_foreign_handlers_and_group_metadata_when_removing_ours() {
        let config = TestConfig::new(HookAgent::Codex);
        let foreign = json!({"type":"command", "command":"logger.exe coucou-hook"});
        let different_override = json!({"type":"command", "command":config.command("Stop"), "commandWindows":"someone-else.exe"});
        let original = json!({ "description":"Keep me", "extra":{"theme":"dark"}, "hooks":{
            "Stop":[{"matcher":".*", "metadata":{"keep":true}, "hooks":[
                foreign.clone(), {"type":"command", "command":config.command("Stop")}, different_override.clone()
            ]}],
            "OtherFutureEvent":[{"hooks":[{"type":"mcp_tool","server":"policy","tool":"check"}]}],
            "PostToolUse":[], "PreToolUse":[{"hooks":[], "keep":true}]
        }});
        let mut expected = original.clone();
        expected["hooks"]["Stop"][0]["hooks"] = json!([foreign, different_override]);
        assert_eq!(config.changed(&original, false), expected);
        let installed = config.changed(&expected, true);
        // An event containing only our newly added handler is removed again;
        // empty event arrays have no handlers to preserve.
        expected["hooks"].as_object_mut().unwrap().remove("PostToolUse");
        assert_eq!(config.changed(&installed, false), expected);
    }

    #[test]
    fn keeps_commands_for_another_agent_or_install_path() {
        let config = TestConfig::new(HookAgent::Codex);
        let foreign = json!({"hooks":{"Stop":[{"hooks":[
            {"type":"command","command":"\"C:/Other/coucou-hook.exe\" --agent codex Stop"},
            {"type":"command","command":"\"C:/Test User/AppData/Local/Coucou/bin/coucou-hook.exe\" Stop"},
            {"type":"command","command":format!("{} && other.exe", config.command("Stop"))}
        ]}]}});
        assert_eq!(config.changed(&foreign, false), foreign);
        assert_eq!(config.changed(&json!({"hooks":{}}), false), json!({"hooks":{}}));
    }

    #[test]
    fn preview_binds_agent_operation_paths_and_missing_state() {
        let config = TestConfig::new(HookAgent::Codex);
        let snapshot = config.read().unwrap();
        let install = config.fingerprint(&snapshot, true);
        assert_ne!(install, config.fingerprint(&snapshot, false));
        for other in [
            HookConfig { agent: HookAgent::Claude, path: config.path.clone(), hook_path: config.hook_path.clone() },
            HookConfig { agent: HookAgent::Codex, path: config.dir.join("other.json"), hook_path: config.hook_path.clone() },
            HookConfig { agent: HookAgent::Codex, path: config.path.clone(), hook_path: PathBuf::from("C:/Other/coucou-hook.exe") },
        ] { assert_ne!(install, other.fingerprint(&snapshot, true)); }
        std::fs::write(&config.path, b"{}").unwrap();
        assert_ne!(install, config.fingerprint(&config.read().unwrap(), true));
        assert!(config.write(true, &install, "20260930-120000").is_err());
        assert_eq!(std::fs::read(&config.path).unwrap(), b"{}");
    }

    #[test]
    fn backs_up_exact_bytes_and_never_overwrites_same_second_backups() {
        let config = TestConfig::new(HookAgent::Codex);
        let bytes = b"\xef\xbb\xbf{\"description\":\"preserve\",\"hooks\":{\"PreToolUse\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"other.exe\"}]}]}}";
        std::fs::write(&config.path, bytes).unwrap();
        let plan = config.preview(true, "20260930-120000").unwrap();
        assert!(plan.diff.contains("--agent codex"));
        let first = config.write(true, &plan.fingerprint, "20260930-120000").unwrap();
        assert_eq!(std::fs::read(&first).unwrap(), bytes);
        assert!(config.installed().unwrap());
        let installed_bytes = std::fs::read(&config.path).unwrap();
        let plan = config.preview(false, "20260930-120000").unwrap();
        let second = config.write(false, &plan.fingerprint, "20260930-120000").unwrap();
        assert_ne!(first, second);
        assert_eq!(std::fs::read(first).unwrap(), bytes);
        assert_eq!(std::fs::read(second).unwrap(), installed_bytes);
        assert_eq!(config.read().unwrap().value, parse(bytes, &config.path).unwrap());
        assert!(!config.installed().unwrap());
    }

    #[test]
    fn changed_file_is_refused_before_a_backup() {
        let config = TestConfig::new(HookAgent::Codex);
        std::fs::write(&config.path, b"{}").unwrap();
        let plan = config.preview(true, "20260930-120000").unwrap();
        std::fs::write(&config.path, b"{\"description\":\"external edit\"}").unwrap();
        assert!(config.write(true, &plan.fingerprint, "20260930-120000").unwrap_err().contains("changed since the preview"));
        assert_eq!(config.read().unwrap().value["description"], "external edit");
        assert_eq!(std::fs::read_dir(&config.dir).unwrap().count(), 1);
    }

    #[test]
    fn edit_during_backup_is_not_overwritten_and_temp_is_cleaned_up() {
        let config = TestConfig::new(HookAgent::Codex);
        std::fs::write(&config.path, b"{}").unwrap();
        let plan = config.preview(true, "20260930-120000").unwrap();
        let external = br#"{"description":"changed while writing"}"#;
        let err = config.write_checked(true, &plan.fingerprint, "20260930-120000", || {
            std::fs::write(&config.path, external).unwrap();
        }).unwrap_err();
        assert!(err.contains("changed since the preview"));
        assert_eq!(std::fs::read(&config.path).unwrap(), external);
        assert_eq!(std::fs::read(config.backup_base("20260930-120000")).unwrap(), b"{}");
        assert_eq!(std::fs::read_dir(&config.dir).unwrap().count(), 2, "failed writes must remove temporary files");
    }

    #[test]
    fn missing_file_install_and_noop_uninstall_need_no_fake_backup() {
        let config = TestConfig::new(HookAgent::Codex);
        let plan = config.preview(false, "20260930-120000").unwrap();
        assert_eq!(config.write(false, &plan.fingerprint, "20260930-120000").unwrap(), "");
        assert!(!config.path.exists());
        let plan = config.preview(true, "20260930-120000").unwrap();
        assert_eq!(config.write(true, &plan.fingerprint, "20260930-120000").unwrap(), "");
        assert!(config.installed().unwrap());
        assert_eq!(std::fs::read_dir(&config.dir).unwrap().count(), 1);
    }
}

fn unique_file(base: &Path) -> Result<(PathBuf, std::fs::File), String> {
    static SEQUENCE: AtomicU64 = AtomicU64::new(0);
    for attempt in 0..100 {
        let path = if attempt == 0 { base.to_owned() } else {
            base.with_file_name(format!("{}.{}-{}", base.file_name().unwrap_or_default().to_string_lossy(),
                std::process::id(), SEQUENCE.fetch_add(1, Ordering::Relaxed)))
        };
        let mut options = OpenOptions::new();
        options.create_new(true).write(true);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
        match options.open(&path) {
            Ok(file) => return Ok((path, file)),
            Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(err) => return Err(format!("Can't create {}: {err}", path.display())),
        }
    }
    Err("Can't reserve a unique hook configuration backup or temporary file".into())
}

fn pretty(value: &Value) -> String { serde_json::to_string_pretty(value).expect("JSON settings") }

/// settings.json is short, so a plain O(nÂ·m) LCS is the simplest honest diff.
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
            result.push_str("  â€¦\n");
            gap = true;
        }
    }
    result
}

#[cfg(all(test, unix))]
mod unix_tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn shell_paths_and_rewrites_preserve_linux_security() {
        let dir = std::env::temp_dir().join(format!("coucou-config-port-{}", std::process::id()));
        std::fs::create_dir(&dir).unwrap();
        let config = HookConfig { agent: HookAgent::Claude,
            path: dir.join("settings.json"), hook_path: PathBuf::from("/home/a b/it's$(id)/coucou-hook") };
        assert_eq!(config.command("Stop"), "'/home/a b/it'\\''s$(id)/coucou-hook' Stop");
        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        for wanted in [0o600, 0o640, 0o644] {
            std::fs::write(&config.path, br#"{"env":{"PRIVATE":"test-only"},"hooks":{"Custom":[{"hooks":[{"type":"command","command":"other"}]}]}}"#).unwrap();
            std::fs::set_permissions(&config.path, std::fs::Permissions::from_mode(wanted)).unwrap();
            let plan = config.preview(true, "test").unwrap();
            let backup = config.write(true, &plan.fingerprint, "test").unwrap();
            assert_eq!(mode(&config.path), wanted);
            assert_eq!(mode(Path::new(&backup)), 0o600);
            assert_eq!(config.read().unwrap().value["env"]["PRIVATE"], "test-only");
            assert!(config.read().unwrap().value["hooks"]["Custom"].is_array());
        }
        std::fs::remove_file(&config.path).unwrap();
        let plan = config.preview(true, "new").unwrap();
        config.write(true, &plan.fingerprint, "new").unwrap();
        assert_eq!(mode(&config.path), 0o600);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
