use super::*;
use serde_json::json;

fn args(agent: Agent, event: &str) -> Args {
    let agent_tag = match agent {
        Agent::Claude => None,
        Agent::Codex => Some("codex".into()),
        Agent::External => Some("my-tool".into()),
    };
    Args { agent, event: event.into(), agent_tag }
}

fn prepared(agent: Agent, event: &str, input: Value) -> Value {
    let (line, received_event, received_agent) = prepare_event(input.to_string().as_bytes(), &args(agent, event), Some(r"C:\fallback")).unwrap();
    assert_eq!(received_event, event);
    assert_eq!(received_agent, agent);
    assert!(line.ends_with('\n'));
    serde_json::from_str(&line).unwrap()
}

#[test]
fn parses_legacy_and_explicit_provider_commands() {
    let parse = |a: &[&str]| parse_args(&a.iter().map(|s| s.to_string()).collect::<Vec<_>>());
    assert_eq!(parse(&[]), Some(args(Agent::Claude, "")));
    assert_eq!(parse(&["Stop"]), Some(args(Agent::Claude, "Stop")));
    assert_eq!(parse(&["--agent", "codex", "Stop"]), Some(args(Agent::Codex, "Stop")));
    let claude = parse(&["--agent", "claude", "Stop"]).unwrap();
    assert_eq!(claude.agent, Agent::Claude);
    assert_eq!(claude.agent_tag.as_deref(), Some("claude"));
    assert_eq!(parse(&["--agent", "my-tool"]), Some(args(Agent::External, "")));
    assert_eq!(parse(&["--agent", "my-tool", "Stop"]), Some(args(Agent::External, "Stop")));
    assert_eq!(parse(&["--agent"]).unwrap().agent, Agent::Claude);
    for invalid in [vec!["--agent", "codex"], vec!["Stop", "extra"], vec!["--agent", "codex", ""]] {
        assert!(parse(&invalid).is_none());
    }
}

#[test]
fn codex_activity_is_allowlisted_and_preserves_routing() {
    for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStop", "Stop"] {
        let value = prepared(Agent::Codex, event, json!({
            "session_id": "s", "turn_id": "t", "cwd": "C:\\project", "tool_name": "Bash",
            "tool_use_id": "call", "agent_id": "child", "agent_type": "review",
            "prompt": "secret", "message": "secret", "last_assistant_message": "secret",
            "transcript_path": "secret", "agent_transcript_path": "secret",
            "tool_input": {"command": "secret"}, "tool_response": "secret",
            "future_field": {"nested": "secret"}, "coucou_agent": "spoof"
        }));
        assert_eq!(value, json!({
            "hook_event_name": event, "coucou_agent": "codex", "session_id": "s", "turn_id": "t",
            "cwd": "C:\\project", "tool_name": "Bash", "tool_use_id": "call", "agent_id": "child", "agent_type": "review"
        }));
        assert!(!value.to_string().contains("secret"));
    }
}

#[test]
fn approvals_preserve_complete_command_and_context_for_both_agents() {
    let command = format!("{}; Remove-Item sensitive", "é".repeat(4000));
    let input = json!({"command": command, "description": "Needs elevated access", "nested": ["all arguments", {"flag": true}]});
    for agent in [Agent::Claude, Agent::Codex] {
        let value = prepared(agent, "PermissionRequest", json!({
            "session_id": "s", "tool_name": "Bash", "tool_input": input,
            "permission_mode": "default", "prompt": "not forwarded by Codex"
        }));
        assert_eq!(value["tool_input"], input);
        assert_eq!(value["permission_mode"], "default");
        assert_eq!(value["cwd"], r"C:\fallback");
        if agent == Agent::Codex {
            assert!(value.get("prompt").is_none());
            assert_eq!(value["coucou_tool_input_json"], input.to_string());
        }
    }
}

#[test]
fn codex_accepts_complete_non_object_tool_arguments() {
    for input in [json!(["arg", 4]), json!("raw tool argument")] {
        let value = prepared(Agent::Codex, "PermissionRequest", json!({"session_id":"s", "tool_name":"mcp__test", "tool_input":input}));
        assert_eq!(value["tool_input"], input);
    }
}

#[test]
fn codex_approval_keeps_exact_numeric_argument_text() {
    // Both Value and JSON.parse would otherwise round these MCP arguments.
    let input = r#"{ "amount": 9007199254740993, "decimal": 0.100000000000000000001, "large": 99999999999999999999999999 }"#;
    let raw = format!(r#"{{"session_id":"s","tool_name":"mcp__test","tool_input":{input}}}"#);
    let (line, _, _) = prepare_event(raw.as_bytes(), &args(Agent::Codex, "PermissionRequest"), None).unwrap();
    let value: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(value["coucou_tool_input_json"], input);
}

#[test]
fn incomplete_or_mismatched_codex_approvals_are_not_forwarded() {
    for input in [
        json!({"session_id":"s", "tool_name":"Bash"}),
        json!({"session_id":"s", "tool_name":"Bash", "tool_input":null}),
        json!({"session_id":"s", "tool_input":{}}),
        json!({"tool_name":"Bash", "tool_input":{}}),
        json!({"session_id":"s", "tool_name":"Bash", "tool_input":{}, "hook_event_name":"PreToolUse"}),
    ] {
        assert!(prepare_event(input.to_string().as_bytes(), &args(Agent::Codex, "PermissionRequest"), None).is_none());
    }
}

#[test]
fn oversized_or_invalid_input_is_rejected_instead_of_truncated() {
    let large = json!({"session_id":"s", "tool_name":"Bash", "tool_input":{"command":"x".repeat(MAX_PAYLOAD)}}).to_string();
    assert!(prepare_event(large.as_bytes(), &args(Agent::Codex, "PermissionRequest"), None).is_none());
    // Raw JSON fits exactly but adding the tag/newline exceeds the pipe frame.
    let small = json!({"session_id":"s", "tool_name":"Bash", "tool_input":{"command":""}}).to_string();
    let exact = small.replace("\"command\":\"\"", &format!("\"command\":\"{}\"", "x".repeat(MAX_PAYLOAD - small.len())));
    assert_eq!(exact.len(), MAX_PAYLOAD);
    assert!(prepare_event(exact.as_bytes(), &args(Agent::Codex, "PermissionRequest"), None).is_none());
    for raw in [b"bad".as_slice(), b"[]", b"null", b""] {
        assert!(prepare_event(raw, &args(Agent::Codex, "Stop"), None).is_none());
    }
}

#[test]
fn bounded_reader_stops_an_endless_stream() {
    assert!(read_bounded(std::io::repeat(b'x'), 32).is_none());
    assert_eq!(read_bounded(&b"1234"[..], 4).unwrap(), b"1234");
}

#[test]
fn bom_and_missing_json_event_use_explicit_event() {
    let mut raw = vec![0xEF, 0xBB, 0xBF];
    raw.extend_from_slice(br#"{"session_id":"s"}"#);
    let (line, event, _) = prepare_event(&raw, &args(Agent::Codex, "Stop"), None).unwrap();
    assert_eq!(event, "Stop");
    assert_eq!(serde_json::from_str::<Value>(&line).unwrap()["coucou_agent"], "codex");
}

#[test]
fn codex_stop_output_stays_neutral_without_a_server_or_with_bad_reply() {
    for event in ["Stop", "SubagentStop"] {
        for reply in [None, Some("allow"), Some("deny"), Some("nonsense")] {
            assert_eq!(output_json(Agent::Codex, event, reply).as_deref(), Some("{}"));
        }
        assert!(output_json(Agent::Claude, event, None).is_none());
    }
    for event in ["SessionStart", "SessionEnd", "Interrupt", "UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStart"] {
        assert!(output_json(Agent::Codex, event, Some("allow")).is_none());
    }
    assert!(output_json(Agent::Codex, "PermissionRequest", None).is_none());
}

#[test]
fn decision_json_matches_the_documented_shape_for_both_agents() {
    for agent in [Agent::Claude, Agent::Codex] {
        assert_eq!(output_json(agent, "PermissionRequest", Some("allow")).unwrap(), r#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#);
        assert_eq!(output_json(agent, "PermissionRequest", Some("deny")).unwrap(), r#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from Coucou"}}}"#);
        assert!(output_json(agent, "PermissionRequest", Some("always")).unwrap().contains(r#""behavior":"allow""#));
        for invalid in ["", "maybe", "allow\ndeny", r#"{"permissionDecision":"allow"}"#] {
            assert!(output_json(agent, "PermissionRequest", Some(invalid)).is_none());
        }
    }
}

#[test]
fn legacy_activity_still_drops_outputs_and_truncates_on_char_boundary() {
    let value = prepared(Agent::Claude, "PreToolUse", json!({
        "tool_input":{"content":"é".repeat(4000)}, "prompt":"legacy prompt",
        "tool_response":"large output", "transcript_path":"private", "coucou_agent":"INVALID"
    }));
    let content = value["tool_input"]["content"].as_str().unwrap();
    assert!(content.len() <= MAX_FIELD_LEN + 4);
    assert!(content.ends_with('…'));
    assert_eq!(value["prompt"], "legacy prompt");
    for dropped in ["tool_response", "transcript_path", "coucou_agent"] { assert!(value.get(dropped).is_none()); }
}

#[test]
fn external_names_use_upstream_validation_and_invalid_names_fall_back() {
    for name in ["a", "tool-123", "-", "abcdefghijklmnopqrstuvwx"] {
        assert!(valid_agent_name(name));
        let parsed = parse_args(&["--agent".into(), name.into(), "Stop".into()]).unwrap();
        assert_eq!(parsed.agent, Agent::External);
    }
    for name in ["", "Upper", "with_space", "with space", "é", "abcdefghijklmnopqrstuvwxy"] {
        assert!(!valid_agent_name(name));
        let parsed = parse_args(&["--agent".into(), name.into(), "Stop".into()]).unwrap();
        assert_eq!(parsed.agent, Agent::Claude);
        let (line, _, agent) = prepare_event(br#"{"coucou_agent":"my-tool"}"#, &parsed, None).unwrap();
        assert_eq!(agent, Agent::Claude, "an explicit invalid argv tag overrides stdin");
        assert!(serde_json::from_str::<Value>(&line).unwrap().get("coucou_agent").is_none());
    }
    assert_eq!(agent_from_tag(Some("claude")), Agent::Claude);
}

#[test]
fn generic_command_uses_stdin_event_and_preserves_upstream_activity() {
    let parsed = parse_args(&["--agent".into(), "my-tool".into()]).unwrap();
    let (line, event, agent) = prepare_event(br#"{
        "hook_event_name":"UserPromptSubmit", "prompt":"display this activity",
        "tool_input":{"command":"echo demo"}, "tool_response":"drop this output",
        "transcript_path":"drop this path", "coucou_agent":"another-tool"
    }"#, &parsed, Some(r"C:\project")).unwrap();
    let value: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(agent, Agent::External);
    assert_eq!(event, "UserPromptSubmit");
    assert_eq!(value["coucou_agent"], "my-tool");
    assert_eq!(value["prompt"], "display this activity");
    assert_eq!(value["tool_input"]["command"], "echo demo");
    assert_eq!(value["cwd"], r"C:\project");
    assert!(value.get("tool_response").is_none());
    assert!(value.get("transcript_path").is_none());
}

#[test]
fn stdin_tag_is_preserved_when_argv_does_not_override_it() {
    let (line, event, agent) = prepare_event(br#"{
        "hook_event_name":"Stop", "coucou_agent":"my-tool", "message":"done"
    }"#, &args(Agent::Claude, ""), None).unwrap();
    assert_eq!(agent, Agent::External);
    assert_eq!(event, "Stop");
    assert_eq!(serde_json::from_str::<Value>(&line).unwrap()["coucou_agent"], "my-tool");
    assert!(output_json(agent, &event, None).is_none());

    let explicit = parse_args(&["--agent".into(), "claude".into(), "Stop".into()]).unwrap();
    let (line, _, agent) = prepare_event(br#"{"coucou_agent":"my-tool"}"#, &explicit, None).unwrap();
    assert_eq!(agent, Agent::Claude);
    assert!(serde_json::from_str::<Value>(&line).unwrap().get("coucou_agent").is_none());
}

#[test]
fn source_codex_tag_still_applies_native_privacy_when_connected() {
    let (line, event, agent) = prepare_event(br#"{
        "hook_event_name":"Stop", "coucou_agent":"codex", "session_id":"s",
        "prompt":"secret", "tool_input":{"command":"secret"}, "last_assistant_message":"secret"
    }"#, &args(Agent::Claude, "Stop"), None).unwrap();
    assert_eq!(agent, Agent::Codex);
    assert!(!line.contains("secret"));
    assert_eq!(output_json(agent, &event, None).as_deref(), Some("{}"));
}

#[test]
fn external_permissions_never_wait_for_or_emit_decisions() {
    let value = prepared(Agent::External, "PermissionRequest", json!({"tool_name":"Bash","tool_input":{"command":"echo demo"}}));
    assert_eq!(value["coucou_agent"], "my-tool");
    assert!(!waits_for_approval(Agent::External, "PermissionRequest"));
    for decision in [None, Some("allow"), Some("deny"), Some("always")] {
        assert!(output_json(Agent::External, "PermissionRequest", decision).is_none());
    }
    assert!(waits_for_approval(Agent::Claude, "PermissionRequest"));
    assert!(waits_for_approval(Agent::Codex, "PermissionRequest"));
}
