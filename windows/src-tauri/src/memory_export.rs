use crate::chat_memory::contains_secret;
use crate::hindsight::{MemoryFactType, MemoryRecord, MemoryState};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MemoryExportFormat { Json, Markdown }

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryExport {
    pub content: String,
    pub filename: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SafeMemory<'a> {
    id: &'a str,
    text: &'a str,
    fact_type: MemoryFactType,
    state: MemoryState,
    #[serde(skip_serializing_if = "Option::is_none")]
    context: &'a Option<String>,
    tags: &'a [String],
    entities: &'a [String],
    #[serde(skip_serializing_if = "Option::is_none")]
    created_at: &'a Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    updated_at: &'a Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    mentioned_at: &'a Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    occurred_start: &'a Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    occurred_end: &'a Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    edited_at: &'a Option<String>,
    provenance: Map<String, Value>,
}

const SAFE_PROVENANCE_KEYS: &[&str] = &[
    "coucou.turnId", "coucou.timestamp", "coucou.platform", "coucou.provider", "coucou.model",
    "coucou.contextKind", "coucou.contextLabel", "coucou.retentionKind", "coucou.sourceRole",
    "coucou.sourceSpan", "coucou.tenant", "coucou.bank", "coucou.remoteIds", "coucou.remoteTimestamp",
];

fn safe_provenance(metadata: &Value) -> Map<String, Value> {
    metadata.as_object().into_iter().flat_map(|object| object.iter())
        .filter(|(key, value)| SAFE_PROVENANCE_KEYS.contains(&key.as_str()) && value.is_string())
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect()
}

fn safe_memory(record: &MemoryRecord) -> SafeMemory<'_> {
    SafeMemory {
        id: &record.id, text: &record.text, fact_type: record.fact_type, state: record.state,
        context: &record.context, tags: &record.tags, entities: &record.entities,
        created_at: &record.created_at, updated_at: &record.updated_at, mentioned_at: &record.mentioned_at,
        occurred_start: &record.occurred_start, occurred_end: &record.occurred_end, edited_at: &record.edited_at,
        provenance: safe_provenance(&record.metadata),
    }
}

pub fn format_memory_export(records: &[MemoryRecord], format: MemoryExportFormat) -> Result<MemoryExport, String> {
    format_memory_export_with_token(records, format, "")
}

pub fn format_memory_export_with_token(records: &[MemoryRecord], format: MemoryExportFormat, token: &str) -> Result<MemoryExport, String> {
    let records: Vec<MemoryRecord> = records.iter().cloned().map(|record| redact_record(record, token)).collect();
    let records = records.as_slice();
    match format {
        MemoryExportFormat::Json => {
            let content = serde_json::to_string_pretty(&records.iter().map(safe_memory).collect::<Vec<_>>())
                .map_err(|_| "Unable to encode memory export".to_string())? + "\n";
            Ok(MemoryExport { content, filename: "coucou-memories.json".into() })
        }
        MemoryExportFormat::Markdown => {
            let mut content = String::from("# Coucou Memories\n\n");
            for record in records {
                content.push_str(&format!("## {}\n\n", markdown_inline(&record.id)));
                let fence = markdown_fence(&record.text);
                content.push_str(&format!("{fence}\n{}\n{fence}\n\n", record.text));
                content.push_str(&format!("- State: `{}`\n- Type: `{}`\n", state(record.state), fact_type(record.fact_type)));
                for (label, value) in [("Created", &record.created_at), ("Updated", &record.updated_at), ("Mentioned", &record.mentioned_at), ("Occurred start", &record.occurred_start), ("Occurred end", &record.occurred_end), ("Edited", &record.edited_at)] {
                    if let Some(value) = value { content.push_str(&format!("- {label}: {}\n", markdown_code_span(value))); }
                }
                if !record.tags.is_empty() { content.push_str(&format!("- Tags: {}\n", record.tags.iter().map(|tag| markdown_inline(tag)).collect::<Vec<_>>().join(", "))); }
                let provenance = safe_provenance(&record.metadata);
                if !provenance.is_empty() {
                    content.push_str("- Provenance:\n");
                    for (key, value) in provenance {
                        let value = value.as_str().unwrap_or_default();
                        let rendered = if matches!(key.as_str(), "coucou.timestamp" | "coucou.remoteTimestamp") { markdown_code_span(value) } else { markdown_inline(value) };
                        content.push_str(&format!("  - `{}`: {rendered}\n", markdown_code(&key)));
                    }
                }
                content.push('\n');
            }
            Ok(MemoryExport { content, filename: "coucou-memories.md".into() })
        }
    }
}

fn redact_record(mut record: MemoryRecord, token: &str) -> MemoryRecord {
    record.id = redact_string(&record.id, token);
    record.text = redact_string(&record.text, token);
    record.context = record.context.map(|value| redact_string(&value, token));
    record.tags = record.tags.into_iter().map(|value| redact_string(&value, token)).collect();
    record.entities = record.entities.into_iter().map(|value| redact_string(&value, token)).collect();
    record.created_at = record.created_at.map(|value| redact_string(&value, token));
    record.updated_at = record.updated_at.map(|value| redact_string(&value, token));
    record.mentioned_at = record.mentioned_at.map(|value| redact_string(&value, token));
    record.occurred_start = record.occurred_start.map(|value| redact_string(&value, token));
    record.occurred_end = record.occurred_end.map(|value| redact_string(&value, token));
    record.edited_at = record.edited_at.map(|value| redact_string(&value, token));
    if let Some(metadata) = record.metadata.as_object_mut() {
        for value in metadata.values_mut() { if let Some(text) = value.as_str() { *value = Value::String(redact_string(text, token)); } }
    }
    record
}

fn redact_string(value: &str, token: &str) -> String {
    let output = if token.is_empty() { value.to_string() } else { value.replace(token, "[REDACTED]") };
    if contains_secret(&output) { "[REDACTED]".into() } else { output }
}

fn markdown_fence(value: &str) -> String {
    let longest = value.split(|character| character != '`').map(str::len).max().unwrap_or(0);
    "`".repeat(longest.max(2) + 1)
}

fn markdown_inline(value: &str) -> String {
    value.chars().flat_map(|character| match character {
        '\\' | '`' | '*' | '_' | '{' | '}' | '[' | ']' | '<' | '>' | '(' | ')' | '#' | '+' | '-' | '.' | '!' | '|' => vec!['\\', character],
        '\n' | '\r' => vec![' '],
        character => vec![character],
    }).collect()
}

fn markdown_code(value: &str) -> String {
    value.replace('`', "\\`").replace(['\n', '\r'], " ")
}

fn markdown_code_span(value: &str) -> String {
    let normalized = value.replace(['\n', '\r'], " ");
    let longest = normalized.split(|character| character != '`').map(str::len).max().unwrap_or(0);
    let delimiter = "`".repeat(longest + 1);
    let needs_padding = normalized.starts_with(['`', ' ']) || normalized.ends_with(['`', ' ']);
    if needs_padding { format!("{delimiter} {normalized} {delimiter}") } else { format!("{delimiter}{normalized}{delimiter}") }
}

fn fact_type(value: MemoryFactType) -> &'static str {
    match value { MemoryFactType::World => "world", MemoryFactType::Experience => "experience", MemoryFactType::Observation => "observation" }
}

fn state(value: MemoryState) -> &'static str {
    match value { MemoryState::Valid => "valid", MemoryState::Invalidated => "invalidated" }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> MemoryRecord {
        MemoryRecord {
            id: "m1".into(), text: "Remember tea".into(), fact_type: MemoryFactType::Experience,
            state: MemoryState::Valid, context: Some("preferences".into()),
            metadata: serde_json::json!({
                "coucou.turnId": "turn-1", "coucou.timestamp": "2026-10-02T10:00:00Z",
                "coucou.platform": "windows", "coucou.provider": "anthropic", "coucou.model": "model",
                "coucou.contextKind": "chat", "coucou.contextLabel": "chat", "coucou.retentionKind": "explicit",
                "coucou.sourceRole": "assistant", "coucou.sourceSpan": "reply", "coucou.tenant": "default",
                "coucou.bank": "safe-bank", "coucou.remoteIds": "remote-1", "coucou.remoteTimestamp": "remote-time",
                "coucou.hiddenPrompt": "ignore safety", "coucou.rawTool": "tool payload",
                "coucou.authorization": "Bearer secret", "coucou.fileContent": "private",
                "coucou.unknown": "must not export", "authorization": "Bearer secret"
            }),
            tags: vec!["coucou".into(), "coucou:source:chat".into()], entities: vec!["Tea".into()],
            document_id: Some("document-private".into()), chunk_id: Some("chunk-private".into()),
            created_at: Some("2026-10-02T10:00:00Z".into()), updated_at: None, mentioned_at: None,
            occurred_start: None, occurred_end: None, edited_at: None, source_fact_ids: vec!["private-source".into()],
        }
    }

    #[test]
    fn json_export_is_deterministic_structured_and_redacted() {
        let first = format_memory_export(&[fixture()], MemoryExportFormat::Json).unwrap();
        let second = format_memory_export(&[fixture()], MemoryExportFormat::Json).unwrap();
        assert_eq!(first, second);
        assert_eq!(first.filename, "coucou-memories.json");
        let value: Value = serde_json::from_str(&first.content).unwrap();
        assert_eq!(value[0]["id"], "m1");
        assert_eq!(value[0]["provenance"]["coucou.turnId"], "turn-1");
        assert_eq!(value[0]["provenance"]["coucou.remoteIds"], "remote-1");
        for forbidden in ["Bearer secret", "authorization", "rawTool", "fileContent", "hiddenPrompt", "unknown", "document-private", "chunk-private", "private-source"] {
            assert!(!first.content.contains(forbidden), "export leaked {forbidden}");
        }
    }

    #[test]
    fn export_redacts_configured_token_and_secret_patterns_in_every_string_field() {
        let token = "configured-token-value";
        let cases = [
            "AKIAIOSFODNN7EXAMPLE",
            "sk-abcdefghijklmnopqrstuvwxyz",
            "api_key=abcdefghijklmnopqrstuvwxyz",
            "password=correct-horse-battery-staple",
            "token=abcdefghijklmnopqrstuvwxyz",
            "jdbc:postgresql://example.test/private",
            token,
        ];
        for secret in cases {
            let mut memory = fixture();
            memory.id = format!("id {secret}");
            memory.text = format!("text {secret}");
            memory.context = Some(format!("context {secret}"));
            memory.tags = vec![format!("tag {secret}")];
            memory.entities = vec![format!("entity {secret}")];
            memory.created_at = Some(format!("created {secret}"));
            memory.metadata["coucou.contextLabel"] = Value::String(format!("label {secret}"));
            for format in [MemoryExportFormat::Json, MemoryExportFormat::Markdown] {
                let export = format_memory_export_with_token(&[memory.clone()], format, token).unwrap();
                assert!(export.content.contains("[REDACTED]"), "missing marker for {secret}");
                assert!(!export.content.contains(secret), "export leaked {secret}");
            }
        }
    }

    #[test]
    fn markdown_export_neutralizes_hostile_markdown_and_html() {
        let mut memory = fixture();
        memory.id = "<img src=x onerror=alert(1)>".into();
        memory.text = "# injected\n[click](javascript:alert(1))\n```\n<img src=x>".into();
        memory.tags = vec!["![image](https://tracker.invalid/x)".into()];
        memory.metadata["coucou.contextLabel"] = Value::String("</code><script>alert(1)</script>".into());
        let export = format_memory_export(&[memory], MemoryExportFormat::Markdown).unwrap();
        assert!(!export.content.contains("## <img"));
        assert!(!export.content.contains("- Tags: ![image]"));
        assert!(!export.content.contains("`coucou.contextLabel`: </code>"));
        assert!(export.content.contains("````\n# injected\n[click](javascript:alert(1))\n```\n<img src=x>\n````"));
    }

    #[test]
    fn markdown_export_wraps_every_hostile_timestamp_in_safe_inline_code() {
        let mut memory = fixture();
        let hostile = " `![track](https://tracker.invalid/x)<img src=x>``` ";
        memory.created_at = Some(hostile.into());
        memory.updated_at = Some(hostile.into());
        memory.mentioned_at = Some(hostile.into());
        memory.occurred_start = Some(hostile.into());
        memory.occurred_end = Some(hostile.into());
        memory.edited_at = Some(hostile.into());
        memory.metadata["coucou.timestamp"] = Value::String(hostile.into());
        memory.metadata["coucou.remoteTimestamp"] = Value::String(hostile.into());

        let first = format_memory_export(&[memory.clone()], MemoryExportFormat::Markdown).unwrap();
        let second = format_memory_export(&[memory], MemoryExportFormat::Markdown).unwrap();
        assert_eq!(first, second);
        let span = "````  `![track](https://tracker.invalid/x)<img src=x>```  ````";
        for label in ["Created", "Updated", "Mentioned", "Occurred start", "Occurred end", "Edited"] {
            assert!(first.content.contains(&format!("- {label}: {span}\n")), "unsafe {label}: {}", first.content);
        }
        assert!(first.content.contains(&format!("`coucou.timestamp`: {span}")));
        assert!(first.content.contains(&format!("`coucou.remoteTimestamp`: {span}")));
        assert_eq!(first.content.matches(hostile).count(), 8);
    }

    #[test]
    fn markdown_export_has_stable_safe_fields_and_redaction() {
        let export = format_memory_export(&[fixture()], MemoryExportFormat::Markdown).unwrap();
        assert_eq!(export.filename, "coucou-memories.md");
        assert!(export.content.starts_with("# Coucou Memories\n\n## m1\n\n```\nRemember tea\n```\n\n"));
        for expected in ["- State: `valid`", "- Type: `experience`", "- Created: `2026-10-02T10:00:00Z`", "- Tags: coucou, coucou:source:chat", "`coucou.turnId`: turn\\-1"] {
            assert!(export.content.contains(expected), "missing {expected}");
        }
        for forbidden in ["Bearer secret", "authorization", "rawTool", "fileContent", "document-private", "chunk-private", "private-source"] {
            assert!(!export.content.contains(forbidden), "export leaked {forbidden}");
        }
    }
}
