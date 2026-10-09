//! Agent event adapters, independent of the Windows process launcher.
use serde_json::{json, Value};

pub fn supported(agent: &str) -> bool {
    matches!(
        agent,
        "codex" | "hermes" | "opencode" | "claude-code" | "antigravity"
    )
}

fn id(value: &Value) -> Option<&str> {
    value.as_str().filter(|s| !s.is_empty() && s.len() <= 256)
}

fn strict_id(value: &Value) -> Option<&str> {
    id(value).filter(|s| !s.trim().is_empty() && !s.chars().any(char::is_control))
}

fn conversation_id(value: &Value) -> Option<&str> {
    let value = strict_id(value)?;
    (value.len() == 36
        && value.bytes().enumerate().all(|(i, byte)| {
            if matches!(i, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        }))
    .then_some(value)
}

pub fn key(payload: &Value, agent: &str) -> Option<Value> {
    let name = payload.get("hook_event_name")?.as_str()?;
    if (agent, name) == ("antigravity", "PreInvocation") {
        return Some(json!([
            agent,
            name,
            conversation_id(payload.get("conversationId")?)?,
            payload.get("invocationNum")?.as_u64()?,
            payload.get("initialNumSteps")?.as_u64()?
        ]));
    }
    let session = payload.get("session_id")?;
    match (agent, name) {
        // Keep Stage 1 keys so an upgrade cannot replay an already handled Codex prompt.
        ("codex", "UserPromptSubmit") => Some(json!([id(session)?, id(payload.get("turn_id")?)?])),
        ("hermes", "SessionStart") => Some(json!([agent, name, strict_id(session)?])),
        // Hermes does not re-fire SessionStart when it resumes a stored prompt.
        ("hermes", "UserPromptSubmit") => Some(json!([
            agent,
            name,
            strict_id(session)?,
            strict_id(payload.get("turn_id")?)?
        ])),
        ("opencode", "UserPromptSubmit") => Some(json!([
            agent,
            name,
            strict_id(session)?,
            strict_id(payload.get("turn_id")?)?
        ])),
        ("claude-code", "SessionStart")
            if matches!(
                payload.get("source").and_then(Value::as_str),
                Some("startup" | "resume")
            ) =>
        {
            Some(json!([
                agent,
                name,
                strict_id(session)?,
                strict_id(payload.get("source")?)?,
                strict_id(payload.get("turn_id")?)?
            ]))
        }
        ("claude-code", "UserPromptSubmit") => Some(json!([
            agent,
            name,
            strict_id(session)?,
            strict_id(payload.get("turn_id")?)?
        ])),
        _ => None,
    }
}

pub fn valid_key(value: &Value) -> bool {
    let Some(parts) = value.as_array() else {
        return false;
    };
    match parts.as_slice() {
        [session, turn] => session.is_string() && turn.is_string(),
        [agent, name, session] => {
            agent == "hermes" && name == "SessionStart" && strict_id(session).is_some()
        }
        [agent, name, session, turn] => {
            (agent == "hermes" || agent == "opencode" || agent == "claude-code")
                && name == "UserPromptSubmit"
                && strict_id(session).is_some()
                && strict_id(turn).is_some()
        }
        [agent, name, session, source, turn] => {
            (agent == "antigravity"
                && name == "PreInvocation"
                && conversation_id(session).is_some()
                && source.as_u64().is_some()
                && turn.as_u64().is_some())
                || (agent == "claude-code"
                    && name == "SessionStart"
                    && matches!(source.as_str(), Some("startup" | "resume"))
                    && strict_id(session).is_some()
                    && strict_id(turn).is_some())
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_agent_requires_its_own_event_and_identifiers() {
        let codex = json!({"hook_event_name":"UserPromptSubmit", "session_id":"s", "turn_id":"t"});
        let hermes = json!({"hook_event_name":"SessionStart", "session_id":"s", "platform":"cli"});
        let hermes_turn =
            json!({"hook_event_name":"UserPromptSubmit", "session_id":"s", "turn_id":"t"});
        assert_eq!(key(&codex, "codex"), Some(json!(["s", "t"])));
        assert_eq!(
            key(&hermes, "hermes"),
            Some(json!(["hermes", "SessionStart", "s"]))
        );
        assert_eq!(
            key(&hermes_turn, "hermes"),
            Some(json!(["hermes", "UserPromptSubmit", "s", "t"]))
        );
        assert!(key(&hermes, "codex").is_none());
        for agent in [
            "", "claude", "copilot", "gemini", "amp", "cursor", "muse", "Hermes",
        ] {
            assert!(key(&codex, agent).is_none());
            assert!(key(&hermes, agent).is_none());
        }
        for (agent, payload, fields) in [
            ("codex", codex, vec!["session_id", "turn_id"]),
            ("hermes", hermes, vec!["session_id"]),
            ("hermes", hermes_turn, vec!["session_id", "turn_id"]),
            (
                "opencode",
                json!({"hook_event_name":"UserPromptSubmit", "session_id":"ses_1", "turn_id":"msg_1"}),
                vec!["session_id", "turn_id"],
            ),
            (
                "claude-code",
                json!({"hook_event_name":"UserPromptSubmit", "session_id":"claude-1", "turn_id":"transcript:128"}),
                vec!["session_id", "turn_id"],
            ),
        ] {
            for field in fields {
                for value in [Value::Null, json!(""), json!(42), json!("x".repeat(257))] {
                    let mut p = payload.clone();
                    p[field] = value;
                    assert!(key(&p, agent).is_none());
                }
                let mut p = payload.clone();
                p.as_object_mut().unwrap().remove(field);
                assert!(key(&p, agent).is_none());
            }
            for name in [
                "PreToolUse",
                "PermissionRequest",
                "PostToolUse",
                "Stop",
                "SessionEnd",
                "Interrupt",
                "SubagentStart",
                "SubagentStop",
                "startup",
                "session_start",
                "unknown",
            ] {
                let mut p = payload.clone();
                p["hook_event_name"] = json!(name);
                assert!(key(&p, agent).is_none());
            }
            assert!(valid_key(&key(&payload, agent).unwrap()));
        }
        for field in ["session_id", "turn_id"] {
            let mut p =
                json!({"hook_event_name":"UserPromptSubmit", "session_id":"s", "turn_id":"t"});
            for value in [json!("  "), json!("a\n")] {
                p[field] = value;
                assert!(key(&p, "hermes").is_none());
            }
        }
    }

    #[test]
    fn opencode_and_claude_triggers_are_namespaced_and_reject_background_events() {
        for agent in ["codex", "hermes", "opencode", "claude-code", "antigravity"] {
            assert!(supported(agent));
        }
        for agent in ["", "claude", "cursor"] {
            assert!(!supported(agent));
        }
        let open =
            json!({"hook_event_name":"UserPromptSubmit", "session_id":"ses_1", "turn_id":"msg_1"});
        let claude = json!({"hook_event_name":"UserPromptSubmit", "session_id":"ses_1", "turn_id":"transcript:128"});
        assert_eq!(
            key(&open, "opencode"),
            Some(json!(["opencode", "UserPromptSubmit", "ses_1", "msg_1"]))
        );
        assert_eq!(
            key(&claude, "claude-code"),
            Some(json!([
                "claude-code",
                "UserPromptSubmit",
                "ses_1",
                "transcript:128"
            ]))
        );
        assert_ne!(key(&open, "opencode"), key(&open, "codex"));
        for name in [
            "SessionStart",
            "PreToolUse",
            "PostToolUse",
            "Stop",
            "SessionEnd",
            "PermissionRequest",
        ] {
            let mut event = open.clone();
            event["hook_event_name"] = json!(name);
            assert!(key(&event, "opencode").is_none());
        }
        for source in ["startup", "resume"] {
            let start = json!({"hook_event_name":"SessionStart", "session_id":"ses_1", "source":source, "turn_id":"transcript:128"});
            assert_eq!(
                key(&start, "claude-code"),
                Some(json!([
                    "claude-code",
                    "SessionStart",
                    "ses_1",
                    source,
                    "transcript:128"
                ]))
            );
        }
        for source in ["compact", "clear", "fork", "background", ""] {
            let start = json!({"hook_event_name":"SessionStart", "session_id":"ses_1", "source":source, "turn_id":"transcript:128"});
            assert!(key(&start, "claude-code").is_none());
        }
        for name in ["PreToolUse", "Stop", "SessionEnd", "PermissionRequest"] {
            let mut event = claude.clone();
            event["hook_event_name"] = json!(name);
            assert!(key(&event, "claude-code").is_none());
        }
        for bad in [
            json!(["opencode", "SessionStart", "s", "m"]),
            json!([
                "claude-code",
                "SessionStart",
                "s",
                "compact",
                "transcript:1"
            ]),
            json!(["claude-code", "UserPromptSubmit", "s", ""]),
        ] {
            assert!(!valid_key(&bad));
        }
    }

    #[test]
    fn legacy_codex_and_namespaced_hermes_keys_cannot_collide() {
        assert!(valid_key(&json!(["s", "t"])));
        assert!(valid_key(&json!(["hermes", "SessionStart", "s"])));
        assert!(valid_key(&json!(["hermes", "UserPromptSubmit", "s", "t"])));
        assert!(valid_key(&json!([
            "opencode",
            "UserPromptSubmit",
            "s",
            "m"
        ])));
        assert!(valid_key(&json!([
            "claude-code",
            "SessionStart",
            "s",
            "resume",
            "transcript:10"
        ])));
        for bad in [
            json!(["s"]),
            json!(["s", 42]),
            json!(["codex", "SessionStart", "s"]),
            json!(["hermes", "Stop", "s"]),
            json!(["hermes", "UserPromptSubmit", "s"]),
            json!(["hermes", "UserPromptSubmit", "s", ""]),
            json!(["hermes", "SessionStart", ""]),
        ] {
            assert!(!valid_key(&bad));
        }
        assert_ne!(
            json!(["hermes", "SessionStart"]),
            json!(["hermes", "SessionStart", "hermes"])
        );
        for session in ["  ", "s\n"] {
            assert!(key(
                &json!({"hook_event_name":"SessionStart", "session_id":session}),
                "hermes"
            )
            .is_none());
            // Stage 1's Codex identifier validation is unchanged.
            assert!(key(
                &json!({"hook_event_name":"UserPromptSubmit", "session_id":session, "turn_id":"t"}),
                "codex"
            )
            .is_some());
        }
    }

    #[test]
    fn antigravity_uses_real_conversation_and_invocation_identifiers() {
        let id = "ec33ebf9-0cba-4100-8142-c61503f6c587";
        let mut event = json!({
            "hook_event_name":"PreInvocation", "conversationId":id,
            "invocationNum":0, "initialNumSteps":1
        });
        let first = key(&event, "antigravity").unwrap();
        assert_eq!(first, json!(["antigravity", "PreInvocation", id, 0, 1]));
        assert!(valid_key(&first));
        assert_eq!(key(&event, "antigravity"), Some(first.clone()));
        event["initialNumSteps"] = json!(12);
        assert_ne!(key(&event, "antigravity"), Some(first.clone()));
        event["conversationId"] = json!("7c619818-5c45-4e67-910e-f1dd3cffcb83");
        assert_ne!(key(&event, "antigravity"), Some(first));
        for name in [
            "PostInvocation",
            "PreToolUse",
            "PostToolUse",
            "Stop",
            "SessionStart",
        ] {
            event["hook_event_name"] = json!(name);
            assert!(key(&event, "antigravity").is_none());
        }
        event["hook_event_name"] = json!("PreInvocation");
        for bad in [
            Value::Null,
            json!(""),
            json!("session"),
            json!("00000000-0000-0000-0000-00000000000x"),
        ] {
            event["conversationId"] = bad;
            assert!(key(&event, "antigravity").is_none());
        }
        event["conversationId"] = json!(id);
        for field in ["invocationNum", "initialNumSteps"] {
            for bad in [Value::Null, json!("0"), json!(-1), json!(1.5)] {
                event[field] = bad;
                assert!(key(&event, "antigravity").is_none());
            }
            event[field] = json!(0);
        }
        assert!(!valid_key(&json!([
            "antigravity",
            "PreInvocation",
            "invalid",
            0,
            0
        ])));
    }
}
