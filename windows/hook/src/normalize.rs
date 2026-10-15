//! Every agent's hook payload, mapped onto the events and fields the island
//! knows (Claude Code's). Same table as `normalize_event` /
//! `normalize_tool_fields` in the Mac relay (HookServer.swift), plus Cursor's
//! events.

use serde_json::{Map, Value};

/// The canonical name of an agent's event. Unknown names pass through.
pub fn event(name: &str) -> &str {
    match name {
        // Gemini CLI
        "BeforeTool" | "BeforeToolSelection" => "PreToolUse",
        "AfterTool" | "AfterModel" => "PostToolUse",
        "BeforeAgent" => "UserPromptSubmit",
        "AfterAgent" => "Stop",
        "startup" => "SessionStart",
        "exit" => "SessionEnd",
        // Antigravity
        "PreInvocation" => "UserPromptSubmit",
        "PostInvocation" => "PostToolUse",
        // snake_case relays
        "pre_tool_use" => "PreToolUse",
        "post_tool_use" => "PostToolUse",
        "user_prompt_submit" => "UserPromptSubmit",
        "session_start" => "SessionStart",
        "session_end" => "SessionEnd",
        "stop" => "Stop",
        // Copilot CLI (camelCase) — Cursor shares most of these
        "sessionStart" => "SessionStart",
        "userPromptSubmitted" => "UserPromptSubmit",
        "agentStop" => "Stop",
        "notification" => "Notification",
        "preToolUse" => "PreToolUse",
        "postToolUse" => "PostToolUse",
        "permissionRequest" => "PermissionRequest",
        "sessionEnd" => "SessionEnd",
        // Cursor
        "beforeSubmitPrompt" => "UserPromptSubmit",
        "postToolUseFailure" => "PostToolUseFailure",
        "subagentStart" => "SubagentStart",
        "subagentStop" => "SubagentStop",
        other => other,
    }
}

/// Keys of Antigravity's `toolCall.args` the island reads under another name.
const ARG_ALIASES: &[(&str, &str)] = &[
    ("CommandLine", "command"),
    ("FilePath", "file_path"),
    ("Path", "path"),
    ("Url", "url"),
    ("Query", "query"),
    ("Pattern", "pattern"),
];

fn non_empty_str<'a>(map: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    map.get(key).and_then(Value::as_str).filter(|s| !s.is_empty())
}

/// Fills `tool_name`, `tool_input`, `session_id` and `cwd` from wherever the
/// agent put them. A field the payload already has is never overwritten.
/// `env` reads an environment variable (a parameter so tests stay pure).
pub fn fields(map: &mut Map<String, Value>, env: &dyn Fn(&str) -> Option<String>) {
    let tool_call = map.get("toolCall").and_then(Value::as_object).cloned();

    if !map.contains_key("tool_name") {
        // Copilot: toolName. Gemini CLI / Antigravity: toolCall.name. Others: tool.
        let name = non_empty_str(map, "toolName")
            .or_else(|| tool_call.as_ref().and_then(|t| non_empty_str(t, "name")))
            .or_else(|| non_empty_str(map, "tool"))
            .map(str::to_string);
        if let Some(name) = name {
            map.insert("tool_name".into(), Value::String(name));
        }
    }

    if !map.contains_key("tool_input") {
        // Copilot sends toolArgs as an object, or as the JSON text of one.
        let args = match map.get("toolArgs") {
            Some(Value::Object(o)) => Some(o.clone()),
            Some(Value::String(s)) => serde_json::from_str::<Value>(s)
                .ok()
                .and_then(|v| v.as_object().cloned()),
            _ => None,
        };
        let input = args.or_else(|| {
            let mut flat = tool_call.as_ref()?.get("args")?.as_object()?.clone();
            for (from, to) in ARG_ALIASES {
                if let Some(v) = flat.get(*from).cloned() {
                    flat.insert((*to).to_string(), v);
                }
            }
            Some(flat)
        });
        if let Some(input) = input {
            map.insert("tool_input".into(), Value::Object(input));
        }
    }

    if non_empty_str(map, "session_id").is_none() {
        let sid = ["conversationId", "conversation_id", "sessionId", "GEMINI_SESSION_ID"]
            .iter()
            .find_map(|k| non_empty_str(map, k))
            .map(str::to_string)
            .or_else(|| env("GEMINI_SESSION_ID").filter(|s| !s.is_empty()));
        if let Some(sid) = sid {
            map.insert("session_id".into(), Value::String(sid));
        }
    }

    if non_empty_str(map, "cwd").is_none() {
        // Copilot: workdir. Gemini CLI / Antigravity: workspacePaths. Cursor: workspace_roots.
        let cwd = non_empty_str(map, "workdir").map(str::to_string).or_else(|| {
            ["workspacePaths", "workspace_roots"].iter().find_map(|k| {
                map.get(*k)?.as_array()?.first()?.as_str().filter(|s| !s.is_empty()).map(str::to_string)
            })
        });
        if let Some(cwd) = cwd {
            map.insert("cwd".into(), Value::String(cwd));
        }
    }
}

/// The event once the payload is known: a stop that reports an error (Cursor's
/// `status: "error"`) is a StopFailure.
pub fn refine(event: &str, map: &Map<String, Value>) -> String {
    if event == "Stop" && map.get("status").and_then(Value::as_str) == Some("error") {
        return "StopFailure".into();
    }
    event.to_string()
}

/// Kiro CLI's shell tools.
const KIRO_SHELL_TOOLS: &[&str] = &["execute_bash", "shell"];

/// What `agent`'s event means to the island. Kiro asks nothing of its own: its
/// PreToolUse of a shell command is the one that can wait for a click, so it
/// becomes a PermissionRequest. Kiro's final answer is `assistant_response`.
pub fn for_agent(agent: &str, event: String, map: &mut Map<String, Value>) -> String {
    if agent != "kiro" {
        return event;
    }
    if !map.contains_key("last_assistant_message") {
        if let Some(text) = map.get("assistant_response").cloned() {
            map.insert("last_assistant_message".into(), text);
        }
    }
    let tool = map.get("tool_name").and_then(Value::as_str).unwrap_or("");
    if event == "PreToolUse" && KIRO_SHELL_TOOLS.contains(&tool) {
        return "PermissionRequest".into();
    }
    event
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn obj(v: Value) -> Map<String, Value> {
        v.as_object().unwrap().clone()
    }

    fn no_env(_: &str) -> Option<String> {
        None
    }

    #[test]
    fn every_agents_event_names_map_onto_claude_codes() {
        for (raw, canonical) in [
            ("BeforeTool", "PreToolUse"),
            ("BeforeToolSelection", "PreToolUse"),
            ("AfterTool", "PostToolUse"),
            ("AfterModel", "PostToolUse"),
            ("BeforeAgent", "UserPromptSubmit"),
            ("AfterAgent", "Stop"),
            ("startup", "SessionStart"),
            ("exit", "SessionEnd"),
            ("PreInvocation", "UserPromptSubmit"),
            ("PostInvocation", "PostToolUse"),
            ("pre_tool_use", "PreToolUse"),
            ("post_tool_use", "PostToolUse"),
            ("user_prompt_submit", "UserPromptSubmit"),
            ("session_start", "SessionStart"),
            ("session_end", "SessionEnd"),
            ("stop", "Stop"),
            ("sessionStart", "SessionStart"),
            ("userPromptSubmitted", "UserPromptSubmit"),
            ("agentStop", "Stop"),
            ("notification", "Notification"),
            ("preToolUse", "PreToolUse"),
            ("postToolUse", "PostToolUse"),
            ("permissionRequest", "PermissionRequest"),
            ("sessionEnd", "SessionEnd"),
            ("beforeSubmitPrompt", "UserPromptSubmit"),
            ("postToolUseFailure", "PostToolUseFailure"),
            ("subagentStart", "SubagentStart"),
            ("subagentStop", "SubagentStop"),
        ] {
            assert_eq!(event(raw), canonical, "{raw}");
        }
        // Claude Code's own names, and anything unknown, pass through.
        for same in ["PreToolUse", "PermissionRequest", "Stop", "Interrupt", "somethingNew"] {
            assert_eq!(event(same), same);
        }
    }

    #[test]
    fn antigravity_and_gemini_tool_calls_become_tool_name_and_input() {
        let mut m = obj(json!({
            "conversationId": "conv-1",
            "workspacePaths": ["C:\\Projects\\test"],
            "toolCall": { "name": "run_command", "args": { "CommandLine": "cargo check" } }
        }));
        fields(&mut m, &no_env);
        assert_eq!(m["tool_name"], "run_command");
        assert_eq!(m["tool_input"]["command"], "cargo check");
        assert_eq!(m["tool_input"]["CommandLine"], "cargo check");
        assert_eq!(m["session_id"], "conv-1");
        assert_eq!(m["cwd"], "C:\\Projects\\test");
    }

    #[test]
    fn copilot_tool_name_args_and_workdir_are_read() {
        let mut m = obj(json!({
            "toolName": "bash",
            "toolArgs": "{\"command\":\"npm test\"}",
            "sessionId": "s-9",
            "workdir": "/home/me/app"
        }));
        fields(&mut m, &no_env);
        assert_eq!(m["tool_name"], "bash");
        assert_eq!(m["tool_input"]["command"], "npm test");
        assert_eq!(m["session_id"], "s-9");
        assert_eq!(m["cwd"], "/home/me/app");

        let mut m = obj(json!({ "toolName": "edit", "toolArgs": { "path": "a.rs" } }));
        fields(&mut m, &no_env);
        assert_eq!(m["tool_input"]["path"], "a.rs");
    }

    #[test]
    fn cursor_conversation_and_workspace_become_session_and_cwd() {
        let mut m = obj(json!({ "conversation_id": "c-1", "workspace_roots": ["/w/proj"] }));
        fields(&mut m, &no_env);
        assert_eq!(m["session_id"], "c-1");
        assert_eq!(m["cwd"], "/w/proj");
    }

    #[test]
    fn what_the_payload_already_says_is_never_overwritten() {
        let mut m = obj(json!({
            "tool_name": "Bash", "tool_input": { "command": "ls" },
            "session_id": "keep", "cwd": "/keep",
            "toolName": "other", "toolArgs": { "command": "rm" },
            "conversationId": "no", "workdir": "/no"
        }));
        fields(&mut m, &|_| Some("env".into()));
        assert_eq!(m["tool_name"], "Bash");
        assert_eq!(m["tool_input"]["command"], "ls");
        assert_eq!(m["session_id"], "keep");
        assert_eq!(m["cwd"], "/keep");
    }

    #[test]
    fn gemini_session_comes_from_the_environment_last() {
        let mut m = obj(json!({}));
        fields(&mut m, &|k| (k == "GEMINI_SESSION_ID").then(|| "g-7".to_string()));
        assert_eq!(m["session_id"], "g-7");
    }

    #[test]
    fn odd_shapes_are_ignored_not_trusted() {
        let mut m = obj(json!({ "toolCall": "nope", "toolArgs": "not json", "workspacePaths": "x", "tool": 3 }));
        fields(&mut m, &no_env);
        assert!(!m.contains_key("tool_name"));
        assert!(!m.contains_key("tool_input"));
        assert!(!m.contains_key("cwd"));
    }

    #[test]
    fn only_kiros_shell_commands_wait_for_a_click() {
        let mut m = obj(json!({ "tool_name": "execute_bash" }));
        assert_eq!(for_agent("kiro", "PreToolUse".into(), &mut m), "PermissionRequest");
        let mut m = obj(json!({ "tool_name": "fs_read" }));
        assert_eq!(for_agent("kiro", "PreToolUse".into(), &mut m), "PreToolUse");
        let mut m = obj(json!({ "tool_name": "execute_bash" }));
        assert_eq!(for_agent("cursor", "PreToolUse".into(), &mut m), "PreToolUse");
        assert_eq!(for_agent("", "PreToolUse".into(), &mut m), "PreToolUse");
    }

    #[test]
    fn kiros_final_answer_is_read_like_claude_codes() {
        let mut m = obj(json!({ "assistant_response": "Done." }));
        for_agent("kiro", "Stop".into(), &mut m);
        assert_eq!(m["last_assistant_message"], "Done.");
        let mut m = obj(json!({ "assistant_response": "no", "last_assistant_message": "keep" }));
        for_agent("kiro", "Stop".into(), &mut m);
        assert_eq!(m["last_assistant_message"], "keep");
    }

    #[test]
    fn a_stop_with_an_error_status_is_a_failure() {
        assert_eq!(refine("Stop", &obj(json!({ "status": "error" }))), "StopFailure");
        for status in ["completed", "aborted"] {
            assert_eq!(refine("Stop", &obj(json!({ "status": status }))), "Stop");
        }
        assert_eq!(refine("PreToolUse", &obj(json!({ "status": "error" }))), "PreToolUse");
    }
}
