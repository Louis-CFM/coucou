//! What the relay prints back to the agent — the only place that knows each
//! agent's stdout contract. Same replies as the Mac relay (HookServer.swift).
//!
//! The one rule that matters: **nothing that allows anything is ever printed
//! without a decision a human clicked.** With no decision the reply is silence,
//! an empty `{}`, or Copilot's explicit "ask", and every agent then asks in its
//! own terminal exactly as if Coucou were not installed.

use serde_json::{json, Map, Value};

/// The agents whose permission requests the island can answer: Claude Code
/// (no `--agent`), Codex, Copilot CLI, Muse Code and Claude Desktop. Any decision
/// for another agent is ignored here too, whatever the app sent.
pub fn takes_decisions(agent: &str) -> bool {
    matches!(agent, "" | "codex" | "copilot" | "muse" | "claude-desktop")
}

/// Agents that read a JSON object on stdout after every hook and get `{}` —
/// "no opinion" — when there is nothing to say.
fn wants_json(agent: &str) -> bool {
    matches!(agent, "gemini" | "antigravity" | "copilot" | "muse")
}

/// The line to print for `event` from `agent`, given the island's `decision`
/// (`None`: nobody clicked) and, for Claude Code's AskUserQuestion, the
/// question as it was asked.
pub fn stdout(agent: &str, event: &str, decision: Option<&str>, question: Option<&Value>) -> Option<String> {
    stdout_with_plan(agent, event, decision, question, None)
}

/// `stdout`, with Claude Code's ExitPlanMode input when that is what is asked:
/// the island's plan card answers it (plan_json).
pub fn stdout_with_plan(
    agent: &str,
    event: &str,
    decision: Option<&str>,
    question: Option<&Value>,
    plan: Option<&Value>,
) -> Option<String> {
    // The fix loop (Coucou's Settings, island/loop.ts): Claude Code told its tests
    // failed, sent back when it stops, a commit or push held back. Only those exact
    // shapes, only for Claude Code; it never allows anything.
    if agent.is_empty() && matches!(event, "Stop" | "PreToolUse" | "PostToolUse" | "PostToolUseFailure") {
        return decision.and_then(|d| loop_json(event, d));
    }
    if event != "PermissionRequest" {
        // Antigravity reads "{}" on PreToolUse as a denial. "ask" keeps its own prompt
        // (and the user's Always Allow): Coucou never allows a tool by itself.
        if agent.eq_ignore_ascii_case("antigravity") && event == "PreToolUse" {
            return Some(r#"{"decision":"ask"}"#.to_string());
        }
        return wants_json(agent).then(|| "{}".to_string());
    }
    let decision = decision.filter(|_| takes_decisions(agent));
    match agent {
        // Copilot CLI and Muse Code read a bare permissionDecision. Copilot is
        // fail-closed: it must always get valid JSON, so silence is an "ask".
        "copilot" | "muse" => {
            let word = match decision.map(str::trim) {
                Some("allow" | "always") => Some("allow"),
                Some("deny") => Some("deny"),
                _ => None,
            };
            match word {
                Some(word) => Some(json!({ "permissionDecision": word }).to_string()),
                None if agent == "copilot" => Some(json!({ "permissionDecision": "ask" }).to_string()),
                None => None,
            }
        }
        // Claude Code, Claude Desktop and Codex share the documented hookSpecificOutput.
        // Claude Code and Claude Desktop can ask questions.
        "" | "claude-desktop" => decision.and_then(|d| match plan {
            Some(p) => plan_json(d, p),
            None => decision_json(d, question),
        }),
        _ => decision.and_then(|d| decision_json(d, None)),
    }
}

/// The fix loop's word, rebuilt from its text alone: a block at Stop, a deny before
/// a tool, a note after one. Anything else prints nothing.
fn loop_json(event: &str, decision: &str) -> Option<String> {
    let v = serde_json::from_str::<Value>(decision).ok()?;
    let text = |v: Option<&Value>| v.and_then(Value::as_str).filter(|s| !s.trim().is_empty()).map(str::to_string);
    let out = v.get("hookSpecificOutput");
    match event {
        "Stop" => {
            if v.get("decision").and_then(Value::as_str) != Some("block") {
                return None;
            }
            let reason = text(v.get("reason"))?;
            Some(json!({ "decision": "block", "reason": reason }).to_string())
        }
        "PreToolUse" => {
            let out = out?;
            if out.get("permissionDecision").and_then(Value::as_str) != Some("deny") {
                return None;
            }
            let reason = text(out.get("permissionDecisionReason"))?;
            Some(json!({ "hookSpecificOutput": { "hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason } }).to_string())
        }
        _ => {
            let context = text(out?.get("additionalContext"))?;
            Some(json!({ "hookSpecificOutput": { "hookEventName": event, "additionalContext": context } }).to_string())
        }
    }
}

/// The documented PermissionRequest output. Anything we do not recognise prints
/// nothing at all rather than guessing — silence is the safe answer.
/// See https://code.claude.com/docs/en/hooks
///
/// `question` is the AskUserQuestion input, when that is what is being asked:
/// the island may then answer it, which Claude Code takes as the same input
/// with an `answers` map added. Nothing else of the input can be changed from
/// the island, and no other tool's input can be changed at all.
pub fn decision_json(decision: &str, question: Option<&Value>) -> Option<String> {
    if decision.trim_start().starts_with('{') {
        let reply = serde_json::from_str::<Value>(decision).ok()?;
        let answers = reply.get("answers")?.as_object()?;
        let question = question?;
        if !answers_fit(question, answers) {
            return None;
        }
        let mut input = question.as_object()?.clone();
        input.insert("answers".into(), Value::Object(answers.clone()));
        return Some(
            json!({
                "hookSpecificOutput": {
                    "hookEventName": "PermissionRequest",
                    "decision": { "behavior": "allow", "updatedInput": input },
                }
            })
            .to_string(),
        );
    }
    let behavior = match decision.trim() {
        // "always" still answers a plain allow; remembering it is the island's
        // business, not the agent's.
        "allow" | "always" => r#"{"behavior":"allow"}"#.to_string(),
        "deny" => r#"{"behavior":"deny","message":"Denied from Coucou"}"#.to_string(),
        _ => return None,
    };
    Some(format!(
        r#"{{"hookSpecificOutput":{{"hookEventName":"PermissionRequest","decision":{behavior}}}}}"#
    ))
}

/// Claude Code's plan (ExitPlanMode), answered from the plan card. An allow must
/// carry the plan back as `updatedInput`, or Claude Code ignores it; Auto mode
/// and Manual also set the session's permission mode, as the terminal's plan
/// dialog does. Change plan rejects it and stops Claude, so the change can be
/// typed in the terminal. Only these words; anything else prints nothing.
pub fn plan_json(decision: &str, plan: &Value) -> Option<String> {
    let allow = |mode: Option<&str>| {
        let mut d = json!({ "behavior": "allow", "updatedInput": plan });
        if let Some(mode) = mode {
            d["updatedPermissions"] = json!([{ "type": "setMode", "mode": mode, "destination": "session" }]);
        }
        json!({ "hookSpecificOutput": { "hookEventName": "PermissionRequest", "decision": d } }).to_string()
    };
    match decision.trim() {
        "plan_auto" => Some(allow(Some("auto"))),
        "plan_default" => Some(allow(Some("default"))),
        "allow" | "always" => Some(allow(None)),
        "plan_change" => Some(
            json!({ "hookSpecificOutput": { "hookEventName": "PermissionRequest", "decision": {
                "behavior": "deny",
                "interrupt": true,
                "message": "The user wants to change the plan and will type the changes in the terminal.",
            } } })
            .to_string(),
        ),
        "deny" => decision_json("deny", None),
        _ => None,
    }
}

/// True when `answers` answers exactly the questions Claude Code asked: one entry
/// per question, keyed by its text; a single-select answer is one of its option
/// labels (a string), a multi-select answer a non-empty list of distinct labels
/// (Claude Code 2.1.136+ takes the list, as the Mac sends it). Same rule as
/// `QuestionPayload.accepts` on macOS.
fn answers_fit(question: &Value, answers: &Map<String, Value>) -> bool {
    let Some(items) = question.get("questions").and_then(|q| q.as_array()) else { return false };
    if items.is_empty() || items.len() != answers.len() {
        return false;
    }
    items.iter().all(|item| {
        let Some(text) = item.get("question").and_then(|q| q.as_str()) else { return false };
        let labels: Vec<&str> = item
            .get("options")
            .and_then(|o| o.as_array())
            .map(|opts| opts.iter().filter_map(|o| o.get("label").and_then(|l| l.as_str())).collect())
            .unwrap_or_default();
        let multi = item.get("multiSelect").and_then(|m| m.as_bool()).unwrap_or(false);
        match answers.get(text) {
            Some(Value::String(pick)) if !multi => labels.contains(&pick.as_str()),
            Some(Value::Array(picks)) if multi => {
                let picks: Vec<&str> = picks.iter().filter_map(|p| p.as_str()).collect();
                let mut seen = picks.clone();
                seen.sort_unstable();
                seen.dedup();
                !picks.is_empty() && seen.len() == picks.len() && picks.iter().all(|p| labels.contains(p))
            }
            _ => false,
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_fix_loop_only_ever_denies_or_adds_a_note() {
        let deny = r#"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"tests fail"}}"#;
        let out: Value = serde_json::from_str(&stdout("", "PreToolUse", Some(deny), None).unwrap()).unwrap();
        assert_eq!(out["hookSpecificOutput"]["permissionDecision"], "deny");
        let allow = deny.replace("\"deny\"", "\"allow\"");
        assert!(stdout("", "PreToolUse", Some(&allow), None).is_none());
        let note = r#"{"hookSpecificOutput":{"hookEventName":"x","additionalContext":"they failed","decision":{"behavior":"allow"}}}"#;
        let out: Value = serde_json::from_str(&stdout("", "PostToolUse", Some(note), None).unwrap()).unwrap();
        assert_eq!(out, json!({ "hookSpecificOutput": { "hookEventName": "PostToolUse", "additionalContext": "they failed" } }));
        assert!(stdout("", "PostToolUseFailure", Some("{}"), None).is_none());
        assert!(stdout("", "PreToolUse", None, None).is_none());
    }

    #[test]
    fn a_stop_is_only_ever_blocked_with_a_reason() {
        let block = r#"{"decision":"block","reason":"Coucou: the tests fail"}"#;
        let out: Value = serde_json::from_str(&stdout("", "Stop", Some(block), None).unwrap()).unwrap();
        assert_eq!(out["decision"], "block");
        assert!(stdout("", "Stop", None, None).is_none());
        assert!(stdout("", "Stop", Some("allow"), None).is_none());
        assert!(stdout("", "Stop", Some(r#"{"decision":"approve"}"#), None).is_none());
        // Another agent's Stop keeps its usual answer.
        assert_eq!(stdout("gemini", "Stop", Some(block), None).as_deref(), Some("{}"));
    }

    #[test]
    fn a_plan_is_sent_back_with_its_allow_and_the_mode_picked() {
        let plan = json!({ "plan": "# Fix the bug\n1. read" });
        let auto: Value = serde_json::from_str(&stdout_with_plan("", "PermissionRequest", Some("plan_auto"), None, Some(&plan)).unwrap()).unwrap();
        let d = &auto["hookSpecificOutput"]["decision"];
        assert_eq!(d["behavior"], "allow");
        assert_eq!(d["updatedInput"], plan);
        assert_eq!(d["updatedPermissions"][0]["mode"], "auto");
        let manual: Value = serde_json::from_str(&plan_json("plan_default", &plan).unwrap()).unwrap();
        assert_eq!(manual["hookSpecificOutput"]["decision"]["updatedPermissions"][0]["mode"], "default");
        let plain: Value = serde_json::from_str(&plan_json("allow", &plan).unwrap()).unwrap();
        assert_eq!(plain["hookSpecificOutput"]["decision"]["updatedInput"], plan);
        assert!(plain["hookSpecificOutput"]["decision"].get("updatedPermissions").is_none());
        let change: Value = serde_json::from_str(&plan_json("plan_change", &plan).unwrap()).unwrap();
        assert_eq!(change["hookSpecificOutput"]["decision"]["behavior"], "deny");
        assert_eq!(change["hookSpecificOutput"]["decision"]["interrupt"], true);
        assert!(plan_json("maybe", &plan).is_none());
        // Never for another agent, and a plan word means nothing without a plan.
        assert!(stdout_with_plan("gemini", "PermissionRequest", Some("plan_auto"), None, Some(&plan)).is_none());
        assert!(decision_json("plan_auto", None).is_none());
    }

    const AGENTS: &[&str] = &[
        "", "gemini", "antigravity", "cursor", "codex", "copilot", "muse", "opencode", "amp",
        "hermes", "claude-desktop", "my-tool",
    ];
    const EVENTS: &[&str] = &[
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "PermissionRequest", "Notification", "Stop", "StopFailure", "SessionEnd", "Interrupt",
        "SubagentStart", "SubagentStop", "",
    ];

    /// Whatever a reply says, does it let anything through?
    fn allows(out: &str) -> bool {
        let v: Value = serde_json::from_str(out).expect("every reply is JSON");
        let text = v.to_string();
        // Any decision counts as one, except "ask" (Antigravity's PreToolUse): that hands the
        // choice back to the agent's own prompt.
        let decided = v.get("decision").map_or(false, |d| d.as_str() != Some("ask"));
        text.contains("allow") || decided || v.get("permission").is_some() || v.get("continue").is_some()
    }

    #[test]
    fn nothing_is_ever_allowed_without_a_decision() {
        for agent in AGENTS {
            for event in EVENTS {
                if let Some(out) = stdout(agent, event, None, None) {
                    assert!(!allows(&out), "{agent:?} {event} printed {out} with nobody clicking");
                }
                // A decline, a timeout or garbage from the app is no decision either.
                for not_a_decision in ["", "ask", "maybe", "{\"permissionDecision\":\"allow\"}"] {
                    if let Some(out) = stdout(agent, event, Some(not_a_decision), None) {
                        assert!(!allows(&out), "{agent:?} {event} {not_a_decision:?} printed {out}");
                    }
                }
            }
        }
    }

    #[test]
    fn a_decision_only_counts_on_a_permission_request_from_an_agent_that_takes_one() {
        for agent in AGENTS {
            for event in EVENTS.iter().filter(|e| **e != "PermissionRequest") {
                if let Some(out) = stdout(agent, event, Some("allow"), None) {
                    assert!(!allows(&out), "{agent:?} {event}: {out}");
                }
            }
            let out = stdout(agent, "PermissionRequest", Some("allow"), None);
            assert_eq!(out.as_deref().is_some_and(allows), takes_decisions(agent), "{agent:?}: {out:?}");
        }
    }

    #[test]
    fn each_agent_gets_its_own_reply_shape() {
        let allow = r#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#;
        let deny = r#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from Coucou"}}}"#;
        for agent in ["", "codex", "claude-desktop"] {
            assert_eq!(stdout(agent, "PermissionRequest", Some("allow"), None).unwrap(), allow);
            assert_eq!(stdout(agent, "PermissionRequest", Some("always"), None).unwrap(), allow);
            assert_eq!(stdout(agent, "PermissionRequest", Some("deny"), None).unwrap(), deny);
            assert_eq!(stdout(agent, "PermissionRequest", None, None), None);
            assert_eq!(stdout(agent, "PreToolUse", None, None), None);
        }
        for agent in ["copilot", "muse"] {
            assert_eq!(stdout(agent, "PermissionRequest", Some("allow"), None).unwrap(), r#"{"permissionDecision":"allow"}"#);
            assert_eq!(stdout(agent, "PermissionRequest", Some("deny"), None).unwrap(), r#"{"permissionDecision":"deny"}"#);
            assert_eq!(stdout(agent, "PreToolUse", None, None).unwrap(), "{}");
        }
        // Copilot is fail-closed: no decision is an explicit "ask", never silence.
        assert_eq!(stdout("copilot", "PermissionRequest", None, None).unwrap(), r#"{"permissionDecision":"ask"}"#);
        assert_eq!(stdout("muse", "PermissionRequest", None, None), None);
        // Antigravity needs a decision on PreToolUse: "ask" leaves it to Antigravity's own prompt;
        // other lifecycle events receive "{}".
        assert_eq!(stdout("antigravity", "PreToolUse", None, None).unwrap(), r#"{"decision":"ask"}"#);
        for event in ["PostToolUse", "UserPromptSubmit", "Stop"] {
            assert_eq!(stdout("antigravity", event, None, None).unwrap(), "{}");
        }
        // Gemini CLI reads "{}" as "no opinion".
        for event in ["PreToolUse", "PostToolUse", "UserPromptSubmit", "Stop"] {
            assert_eq!(stdout("gemini", event, None, None).unwrap(), "{}");
        }
        // Cursor: silence, which Cursor reads as "carry on as usual".
        for event in ["PreToolUse", "UserPromptSubmit", "Stop"] {
            assert_eq!(stdout("cursor", event, None, None), None);
        }
        // Hermes approvals are not supported: its decisions are never relayed.
        assert_eq!(stdout("hermes", "PermissionRequest", Some("allow"), None), None);
    }

    #[test]
    fn decision_json_matches_the_documented_shape() {
        assert_eq!(
            decision_json("allow", None).unwrap(),
            r#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
        );
        assert!(decision_json("always", None).unwrap().contains(r#""behavior":"allow""#));
    }

    #[test]
    fn anything_unrecognised_prints_nothing() {
        assert!(decision_json("", None).is_none());
        assert!(decision_json("maybe", None).is_none());
        // The shape the app used to send must not be mistaken for a decision.
        assert!(decision_json(r#"{"permissionDecision":"allow"}"#, None).is_none());
    }

    #[test]
    fn an_answered_question_goes_back_as_the_same_input_plus_answers() {
        let question = json!({
            "questions": [{ "question": "Which one?", "options": [{ "label": "A" }, { "label": "B" }] }]
        });
        let out = stdout("", "PermissionRequest", Some(r#"{"answers":{"Which one?":"B"}}"#), Some(&question)).unwrap();
        let v: Value = serde_json::from_str(&out).unwrap();
        let decision = &v["hookSpecificOutput"]["decision"];
        assert_eq!(decision["behavior"], "allow");
        assert_eq!(decision["updatedInput"]["questions"], question["questions"]);
        // Claude Desktop can also ask questions.
        let out_desktop = stdout("claude-desktop", "PermissionRequest", Some(r#"{"answers":{"Which one?":"B"}}"#), Some(&question)).unwrap();
        assert_eq!(out_desktop, out);
        // Only Claude Code and Claude Desktop ask questions: an answer for anyone else is nothing.
        assert!(stdout("codex", "PermissionRequest", Some(r#"{"answers":{"Which one?":"B"}}"#), Some(&question)).is_none());
    }

    #[test]
    fn answers_are_only_accepted_for_a_question() {
        assert!(decision_json(r#"{"answers":{"q":"a"}}"#, None).is_none());
        let question = json!({ "questions": [] });
        assert!(decision_json(r#"{"answers":{}}"#, Some(&question)).is_none());
        assert!(decision_json(r#"{"answers":{"q":1}}"#, Some(&question)).is_none());
        assert!(decision_json(r#"{"command":"rm -rf /"}"#, Some(&question)).is_none());
    }

    #[test]
    fn answers_must_match_the_questions_asked() {
        let q = json!({ "questions": [
            { "question": "Which one?", "options": [{ "label": "A" }, { "label": "B" }] },
            { "question": "Extras?", "multiSelect": true,
              "options": [{ "label": "Tests" }, { "label": "Docs" }, { "label": "Lint" }] }
        ]});
        let ok = |a: &str| decision_json(a, Some(&q)).is_some();
        assert!(ok(r#"{"answers":{"Which one?":"A","Extras?":["Tests","Docs"]}}"#));
        assert!(!ok(r#"{"answers":{"Which one?":"C","Extras?":["Tests"]}}"#));
        assert!(!ok(r#"{"answers":{"Which one?":"A","Extras?":["Tests"],"Other?":"x"}}"#));
        assert!(!ok(r#"{"answers":{"Which one?":"A"}}"#));
        assert!(!ok(r#"{"answers":{"Which one?":["A"],"Extras?":["Tests"]}}"#));
        assert!(!ok(r#"{"answers":{"Which one?":"A","Extras?":"Tests"}}"#));
        assert!(!ok(r#"{"answers":{"Which one?":"A","Extras?":[]}}"#));
        assert!(!ok(r#"{"answers":{"Which one?":"A","Extras?":["Tests","Tests"]}}"#));
    }
}
