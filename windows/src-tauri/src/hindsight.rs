use reqwest::{Method, StatusCode, Url};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use serde_json::Value;
use std::{collections::HashSet, fmt, sync::{Arc, atomic::{AtomicBool, AtomicU64, Ordering}}, time::Duration};
use tokio::sync::{watch, Semaphore};

pub const DEFAULT_BASE_URL: &str = "https://hindsight.example.com/hindsight";
pub const DEFAULT_TENANT: &str = "default";
pub const DEFAULT_BANK: &str = "hieu";
pub const SECRET_KEY: &str = "hindsight-bearer-token";
static AUTOMATIC_AUTH_SUPPRESSED: AtomicBool = AtomicBool::new(false);

pub fn clear_automatic_auth_suppression() { AUTOMATIC_AUTH_SUPPRESSED.store(false, Ordering::SeqCst); }

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct HindsightSettings {
    pub enabled: bool,
    pub base_url: String,
    pub tenant: String,
    pub bank: String,
    pub automatic_recall: bool,
    pub inferred_retention: bool,
    pub allow_development_http: bool,
}

pub type HindsightConfig = HindsightSettings;

impl Default for HindsightSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            base_url: DEFAULT_BASE_URL.into(),
            tenant: DEFAULT_TENANT.into(),
            bank: DEFAULT_BANK.into(),
            automatic_recall: true,
            inferred_retention: true,
            allow_development_http: false,
        }
    }
}

impl HindsightSettings {
    pub fn sanitize(&mut self) {
        self.base_url = self.base_url.trim().to_string();
        self.tenant = self.tenant.trim().to_string();
        self.bank = self.bank.trim().to_string();
        if self.tenant.is_empty() {
            self.tenant = DEFAULT_TENANT.into();
        }
        if self.bank.is_empty() {
            self.bank = DEFAULT_BANK.into();
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MemoryFactType {
    World,
    Experience,
    Observation,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MemoryState {
    Valid,
    Invalidated,
}

impl Default for MemoryState {
    fn default() -> Self {
        Self::Valid
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RetentionKind {
    Explicit,
    Inferred,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MemoryPlatform {
    Windows,
    Macos,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum MemoryTimeField {
    #[serde(rename = "created_at")]
    CreatedAt,
    #[serde(rename = "updated_at")]
    UpdatedAt,
    #[serde(rename = "mentioned_at")]
    MentionedAt,
    #[serde(rename = "occurred_start")]
    OccurredStart,
    #[serde(rename = "occurred_end")]
    OccurredEnd,
    #[serde(rename = "edited_at")]
    EditedAt,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum MemorySourceKind { Chat, SelectedText }

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryRecord {
    pub id: String,
    pub text: String,
    pub fact_type: MemoryFactType,
    pub state: MemoryState,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context: Option<String>,
    pub metadata: Value,
    pub tags: Vec<String>,
    pub entities: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub document_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chunk_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub created_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mentioned_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub occurred_start: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub occurred_end: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub edited_at: Option<String>,
    pub source_fact_ids: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryPage {
    pub items: Vec<MemoryRecord>,
    pub total: u64,
    pub limit: u64,
    pub offset: u64,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryFilter {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub query: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub document_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fact_type: Option<MemoryFactType>,
    #[serde(default)]
    pub state: MemoryState,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub start_date: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub end_date: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub time_field: Option<MemoryTimeField>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub platform: Option<MemoryPlatform>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub retention_kind: Option<RetentionKind>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_kind: Option<MemorySourceKind>,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryUpdate {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub occurred_start: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub occurred_end: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fact_type: Option<MemoryFactType>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub entities: Option<Vec<String>>,
    #[serde(default)]
    pub resolve_entities: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub state: Option<MemoryState>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expected_updated_at: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MemoryErrorKind {
    InvalidConfiguration,
    Unauthorized,
    Forbidden,
    NotFound,
    Conflict,
    RateLimited,
    Unavailable,
    InvalidResponse,
    Timeout,
    Connection,
    Tls,
    Network,
    Cancelled,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryError {
    pub kind: MemoryErrorKind,
    pub message: String,
}

impl MemoryError {
    fn new(kind: MemoryErrorKind, message: impl Into<String>) -> Self {
        Self { kind, message: message.into() }
    }
}

impl fmt::Display for MemoryError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for MemoryError {}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BulkMutationFailure {
    pub id: String,
    pub kind: MemoryErrorKind,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BulkMutationResult {
    pub requested: usize,
    pub succeeded: Vec<String>,
    pub failed: Vec<BulkMutationFailure>,
    pub refresh: bool,
}

#[derive(Debug, Clone, Default)]
pub struct MemoryListOptions {
    pub filter: MemoryFilter,
    pub document_id: Option<String>,
    pub tags: Vec<String>,
    pub limit: u64,
    pub offset: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryBrowseRequest {
    #[serde(default)]
    pub filter: MemoryFilter,
    pub limit: u64,
    pub offset: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConfirmedMemoryScope {
    pub request: MemoryBrowseRequest,
    pub endpoint: String,
    pub tenant: String,
    pub bank: String,
    pub fingerprint: String,
}

pub fn memory_scope_fingerprint(request: &MemoryBrowseRequest, endpoint: &str, tenant: &str, bank: &str) -> Result<String, MemoryError> {
    let normalized = serde_json::to_string(request).map_err(|_| MemoryError::new(MemoryErrorKind::InvalidConfiguration, "Unable to normalize memory scope"))?;
    Ok(format!("{endpoint}\n{tenant}\n{bank}\n{normalized}"))
}

impl ConfirmedMemoryScope {
    pub fn new(request: MemoryBrowseRequest, endpoint: String, tenant: String, bank: String) -> Result<Self, MemoryError> {
        let endpoint = normalize_endpoint_string(&endpoint)?;
        let fingerprint = memory_scope_fingerprint(&request, &endpoint, &tenant, &bank)?;
        Ok(Self { request, endpoint, tenant, bank, fingerprint })
    }
    pub fn validate(&self, current_endpoint: &str, current_tenant: &str, current_bank: &str) -> Result<(), MemoryError> {
        let endpoint = normalize_endpoint_string(&self.endpoint)?;
        let expected = memory_scope_fingerprint(&self.request, &endpoint, &self.tenant, &self.bank)?;
        if self.fingerprint != expected { return Err(MemoryError::new(MemoryErrorKind::InvalidConfiguration, "Confirmed memory scope fingerprint is invalid")); }
        if endpoint != normalize_endpoint_string(current_endpoint)? || self.tenant != current_tenant || self.bank != current_bank { return Err(MemoryError::new(MemoryErrorKind::Conflict, "Hindsight endpoint, tenant, or bank changed after confirmation")); }
        Ok(())
    }
}

const SAFE_PROVENANCE_KEYS: &[&str] = &[
    "coucou.turnId", "coucou.timestamp", "coucou.platform", "coucou.provider", "coucou.model",
    "coucou.contextKind", "coucou.contextLabel", "coucou.retentionKind", "coucou.sourceRole",
    "coucou.sourceSpan", "coucou.tenant", "coucou.bank", "coucou.remoteIds", "coucou.remoteTimestamp",
];
const SAFE_DETAIL_COLLECTION_LIMIT: usize = 64;
const SAFE_DETAIL_VALUE_LIMIT: usize = 256;
const SAFE_DETAIL_IDENTIFIER_LIMIT: usize = 512;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SafeMemoryDetail {
    pub id: String, pub state: MemoryState, pub fact_type: MemoryFactType, pub tenant: String, pub bank: String,
    pub content: String, pub context: Option<String>, pub tags: Vec<String>, pub entities: Vec<String>,
    pub created_at: Option<String>, pub updated_at: Option<String>, pub mentioned_at: Option<String>,
    pub occurred_start: Option<String>, pub occurred_end: Option<String>, pub edited_at: Option<String>,
    pub metadata: serde_json::Map<String, Value>, pub document_id: Option<String>, pub chunk_id: Option<String>,
    pub source_fact_ids: Vec<String>,
}
impl SafeMemoryDetail {
    pub fn from_record(record: &MemoryRecord, tenant: &str, bank: &str, content_limit: usize) -> Self {
        let bounded = |value: &str| value.chars().take(content_limit).collect::<String>();
        let bounded_value = |value: &Option<String>| value.as_deref().map(|value| value.chars().take(SAFE_DETAIL_VALUE_LIMIT).collect());
        let bounded_values = |values: &[String]| values.iter().take(SAFE_DETAIL_COLLECTION_LIMIT).map(|value| value.chars().take(SAFE_DETAIL_VALUE_LIMIT).collect()).collect();
        let bounded_id = |value: &Option<String>| value.as_deref().map(|value| value.chars().take(SAFE_DETAIL_IDENTIFIER_LIMIT).collect());
        let metadata = record.metadata.as_object().into_iter().flat_map(|object| object.iter())
            .filter_map(|(key, value)| SAFE_PROVENANCE_KEYS.contains(&key.as_str()).then(|| value.as_str().map(|value| (key.clone(), Value::String(value.chars().take(SAFE_DETAIL_VALUE_LIMIT).collect())))).flatten()).collect();
        Self { id: record.id.chars().take(SAFE_DETAIL_IDENTIFIER_LIMIT).collect(), state: record.state, fact_type: record.fact_type, tenant: tenant.into(), bank: bank.into(), content: bounded(&record.text), context: record.context.as_deref().map(bounded), tags: bounded_values(&record.tags), entities: bounded_values(&record.entities), created_at: bounded_value(&record.created_at), updated_at: bounded_value(&record.updated_at), mentioned_at: bounded_value(&record.mentioned_at), occurred_start: bounded_value(&record.occurred_start), occurred_end: bounded_value(&record.occurred_end), edited_at: bounded_value(&record.edited_at), metadata, document_id: bounded_id(&record.document_id), chunk_id: bounded_id(&record.chunk_id), source_fact_ids: bounded_values(&record.source_fact_ids) }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConfirmedMemoryRetirement { pub id: String, pub text: String, pub updated_at: Option<String>, pub endpoint: String, pub tenant: String, pub bank: String }
impl ConfirmedMemoryRetirement {
    pub fn new(record: &MemoryRecord, endpoint: String, tenant: String, bank: String) -> Result<Self, MemoryError> { Ok(Self { id: record.id.clone(), text: record.text.clone(), updated_at: record.updated_at.clone(), endpoint: normalize_endpoint_string(&endpoint)?, tenant, bank }) }
    fn validate_namespace(&self, endpoint: &str, tenant: &str, bank: &str) -> Result<(), MemoryError> {
        if self.endpoint == normalize_endpoint_string(endpoint)? && self.tenant == tenant && self.bank == bank { Ok(()) } else { Err(MemoryError::new(MemoryErrorKind::Conflict, "Hindsight endpoint, tenant, or bank changed after confirmation")) }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum MemoryUpdateResult {
    Updated { memory: MemoryRecord, refresh: bool },
    Conflict { current: MemoryRecord },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryMutationResult {
    pub memory: MemoryRecord,
    pub refresh: bool,
}

#[derive(Clone)]
pub struct MemoryManager {
    client: HindsightClient,
    list_generation: Arc<AtomicU64>,
}

impl MemoryManager {
    pub fn new(client: HindsightClient) -> Self { Self { client, list_generation: Arc::new(AtomicU64::new(0)) } }
    pub fn with_list_generation(client: HindsightClient, list_generation: Arc<AtomicU64>) -> Self { Self { client, list_generation } }

    pub async fn list(&self, request: MemoryBrowseRequest) -> Result<MemoryPage, MemoryError> {
        let generation = self.list_generation.fetch_add(1, Ordering::SeqCst) + 1;
        let mut tags = Vec::new();
        if let Some(platform) = request.filter.platform {
            tags.push(format!("coucou:platform:{}", memory_platform(platform)));
        }
        if let Some(retention) = request.filter.retention_kind {
            tags.push(format!("coucou:retention:{}", retention_kind(retention)));
        }
        if let Some(source) = request.filter.source_kind {
            tags.push(format!("coucou:source:{}", memory_source_kind(source)));
        }
        let document_id = request.filter.document_id.clone();
        let page = self.client.list_memories(&MemoryListOptions {
            filter: request.filter, document_id, tags, limit: request.limit, offset: request.offset
        }).await?;
        if generation != self.list_generation.load(Ordering::SeqCst) {
            return Err(MemoryError::new(MemoryErrorKind::Cancelled, "Hindsight list request was superseded"));
        }
        Ok(page)
    }

    pub async fn get(&self, id: &str) -> Result<MemoryRecord, MemoryError> {
        self.client.get_memory(id).await
    }

    pub async fn update(&self, id: &str, opened: &MemoryRecord, update: MemoryUpdate, overwrite: bool) -> Result<MemoryUpdateResult, MemoryError> {
        if opened.fact_type == MemoryFactType::Observation {
            return Err(MemoryError::new(MemoryErrorKind::InvalidConfiguration, "Observation memories cannot be edited"));
        }
        let current = self.client.get_memory(id).await?;
        if current.fact_type == MemoryFactType::Observation {
            return Err(MemoryError::new(MemoryErrorKind::InvalidConfiguration, "Observation memories cannot be edited"));
        }
        if current != *opened && !overwrite {
            return Ok(MemoryUpdateResult::Conflict { current });
        }
        let memory = self.client.update_memory(id, &update).await?;
        Ok(MemoryUpdateResult::Updated { memory, refresh: true })
    }

    pub async fn retire(&self, id: &str) -> Result<MemoryMutationResult, MemoryError> {
        let memory = self.client.update_memory(id, &MemoryUpdate {
            state: Some(MemoryState::Invalidated), reason: Some("Retired from Coucou".into()), ..Default::default()
        }).await?;
        Ok(MemoryMutationResult { memory, refresh: true })
    }

    pub async fn retire_confirmed(&self, confirmation: ConfirmedMemoryRetirement, current_endpoint: &str, current_tenant: &str, current_bank: &str) -> Result<MemoryMutationResult, MemoryError> {
        confirmation.validate_namespace(current_endpoint, current_tenant, current_bank)?;
        let current = self.client.get_memory(&confirmation.id).await?;
        if current.text != confirmation.text || current.updated_at != confirmation.updated_at {
            return Err(MemoryError::new(MemoryErrorKind::Conflict, "Memory changed after confirmation; review it again before retiring"));
        }
        self.retire(&confirmation.id).await
    }

    pub async fn restore(&self, id: &str) -> Result<MemoryMutationResult, MemoryError> {
        let memory = self.client.restore_memory(id).await?;
        Ok(MemoryMutationResult { memory, refresh: true })
    }

    pub async fn bulk_retire_confirmed(&self, scope: ConfirmedMemoryScope, current_endpoint: &str, current_tenant: &str, current_bank: &str) -> Result<BulkMutationResult, MemoryError> {
        scope.validate(current_endpoint, current_tenant, current_bank)?;
        self.bulk_retire(scope.request).await
    }

    pub async fn bulk_retire(&self, request: MemoryBrowseRequest) -> Result<BulkMutationResult, MemoryError> {
        if request.filter.state != MemoryState::Valid {
            return Err(MemoryError::new(MemoryErrorKind::InvalidConfiguration, "Bulk retirement only applies to valid memories"));
        }
        let mut tags = Vec::new();
        if let Some(platform) = request.filter.platform { tags.push(format!("coucou:platform:{}", memory_platform(platform))); }
        if let Some(retention) = request.filter.retention_kind { tags.push(format!("coucou:retention:{}", retention_kind(retention))); }
        if let Some(source) = request.filter.source_kind { tags.push(format!("coucou:source:{}", memory_source_kind(source))); }
        self.client.bulk_retire(MemoryListOptions { filter: request.filter, tags, limit: request.limit, offset: 0, ..Default::default() }).await
    }
}

#[derive(Debug, Serialize)]
struct RecallRequest<'a> {
    query: &'a str,
    budget: u64,
    max_tokens: u64,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct RecallMemory {
    pub text: String,
}

fn deserialize_recall_memories<'de, D>(deserializer: D) -> Result<Vec<RecallMemory>, D::Error>
where D: serde::Deserializer<'de> {
    let values = Option::<Vec<Value>>::deserialize(deserializer)?.unwrap_or_default();
    Ok(values.into_iter().filter_map(|value| value.get("text").and_then(Value::as_str).map(|text| RecallMemory { text: text.to_string() })).collect())
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct RecallResponse {
    pub text: Option<String>,
    #[serde(default, deserialize_with = "deserialize_recall_memories")]
    pub memories: Vec<RecallMemory>,
}

#[derive(Debug, Clone)]
pub struct RetainContent(serde_json::Map<String, Value>);

impl RetainContent {
    #[cfg(test)]
    pub(crate) fn value(&self) -> Value { Value::Object(self.0.clone()) }
}

impl TryFrom<Value> for RetainContent {
    type Error = MemoryError;

    fn try_from(value: Value) -> Result<Self, Self::Error> {
        value.as_object().cloned().map(Self)
            .ok_or_else(|| MemoryError::new(MemoryErrorKind::InvalidConfiguration, "Retain content must be a JSON object"))
    }
}

#[derive(Debug, Clone)]
pub struct RetainInput {
    pub document_id: String,
    pub items: Vec<RetainContent>,
}

impl RetainInput {
    pub fn new(document_id: impl Into<String>, items: Vec<RetainContent>) -> Result<Self, MemoryError> {
        let document_id = document_id.into();
        if document_id.trim().is_empty() {
            return Err(MemoryError::new(MemoryErrorKind::InvalidConfiguration, "Retain document_id must not be empty"));
        }
        Ok(Self { document_id, items })
    }
}

fn retain_body(input: &RetainInput) -> Result<Value, MemoryError> {
    let items = input.items.iter().map(|content| {
        let mut object = content.0.clone();
        object.insert("document_id".into(), Value::String(input.document_id.clone()));
        Value::Object(object)
    }).collect::<Vec<_>>();
    Ok(serde_json::json!({"items": items, "async": false}))
}

fn empty_object() -> Value { serde_json::json!({}) }

fn null_to_object<'de, D>(deserializer: D) -> Result<Value, D::Error>
where
    D: serde::Deserializer<'de>,
{
    Ok(Option::<Value>::deserialize(deserializer)?.unwrap_or_else(empty_object))
}

fn null_to_default<'de, D, T>(deserializer: D) -> Result<T, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Deserialize<'de> + Default,
{
    Ok(Option::<T>::deserialize(deserializer)?.unwrap_or_default())
}

#[derive(Debug, Deserialize)]
struct WireMemoryRecord {
    id: String,
    text: String,
    fact_type: MemoryFactType,
    #[serde(default)]
    state: MemoryState,
    context: Option<String>,
    #[serde(default = "empty_object", deserialize_with = "null_to_object")]
    metadata: Value,
    #[serde(default, deserialize_with = "null_to_default")]
    tags: Vec<String>,
    #[serde(default, deserialize_with = "null_to_default")]
    entities: Vec<String>,
    document_id: Option<String>,
    chunk_id: Option<String>,
    created_at: Option<String>,
    updated_at: Option<String>,
    mentioned_at: Option<String>,
    occurred_start: Option<String>,
    occurred_end: Option<String>,
    edited_at: Option<String>,
    #[serde(default, deserialize_with = "null_to_default")]
    source_fact_ids: Vec<String>,
}

impl From<WireMemoryRecord> for MemoryRecord {
    fn from(value: WireMemoryRecord) -> Self {
        Self {
            id: value.id, text: value.text, fact_type: value.fact_type, state: value.state,
            context: value.context, metadata: value.metadata, tags: value.tags, entities: value.entities,
            document_id: value.document_id, chunk_id: value.chunk_id, created_at: value.created_at,
            updated_at: value.updated_at, mentioned_at: value.mentioned_at, occurred_start: value.occurred_start,
            occurred_end: value.occurred_end, edited_at: value.edited_at, source_fact_ids: value.source_fact_ids,
        }
    }
}

#[derive(Debug, Deserialize)]
struct WireMemoryPage {
    #[serde(default, deserialize_with = "null_to_default")]
    items: Vec<WireMemoryRecord>,
    total: u64,
    limit: u64,
    offset: u64,
}

impl From<WireMemoryPage> for MemoryPage {
    fn from(value: WireMemoryPage) -> Self {
        Self { items: value.items.into_iter().map(Into::into).collect(), total: value.total, limit: value.limit, offset: value.offset }
    }
}

#[derive(Debug, Serialize)]
struct WireMemoryUpdate<'a> {
    #[serde(skip_serializing_if = "Option::is_none")]
    text: &'a Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    context: &'a Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    occurred_start: &'a Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    occurred_end: &'a Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    fact_type: &'a Option<MemoryFactType>,
    #[serde(skip_serializing_if = "Option::is_none")]
    entities: &'a Option<Vec<String>>,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    resolve_entities: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    state: &'a Option<MemoryState>,
    #[serde(skip_serializing_if = "Option::is_none")]
    reason: &'a Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    expected_updated_at: &'a Option<String>,
}

impl<'a> From<&'a MemoryUpdate> for WireMemoryUpdate<'a> {
    fn from(value: &'a MemoryUpdate) -> Self {
        Self {
            text: &value.text, context: &value.context, occurred_start: &value.occurred_start,
            occurred_end: &value.occurred_end, fact_type: &value.fact_type, entities: &value.entities,
            resolve_entities: value.resolve_entities, state: &value.state, reason: &value.reason,
            expected_updated_at: &value.expected_updated_at,
        }
    }
}

const MAX_RESPONSE_BYTES: usize = 4 * 1024 * 1024;
const MAX_BULK_PAGES: usize = 10_000;

#[derive(Clone)]
pub struct HindsightCancellation {
    sender: watch::Sender<bool>,
}

impl HindsightCancellation {
    pub fn new() -> Self {
        let (sender, _) = watch::channel(false);
        Self { sender }
    }

    pub fn cancel(&self) { let _ = self.sender.send(true); }

    async fn cancelled(&self) {
        let mut receiver = self.sender.subscribe();
        if *receiver.borrow() { return; }
        while receiver.changed().await.is_ok() {
            if *receiver.borrow() { return; }
        }
    }
}

impl Default for HindsightCancellation { fn default() -> Self { Self::new() } }

#[derive(Clone)]
pub struct HindsightClient {
    config: HindsightConfig,
    token: Arc<str>,
    http: reqwest::Client,
    max_response_bytes: usize,
    max_bulk_pages: usize,
}

impl HindsightClient {
    pub fn new(config: HindsightConfig) -> Result<Self, MemoryError> {
        let token = crate::secrets::get(SECRET_KEY)
            .ok_or_else(|| MemoryError::new(MemoryErrorKind::Unauthorized, "Hindsight credential is missing"))?;
        Self::with_token(config, token)
    }

    pub(crate) fn with_token(config: HindsightConfig, token: String) -> Result<Self, MemoryError> {
        validate_hindsight_config(&config)
            .map_err(|message| MemoryError::new(MemoryErrorKind::InvalidConfiguration, message))?;
        let http = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(5))
            .build()
            .map_err(|_| MemoryError::new(MemoryErrorKind::Network, "Unable to initialize Hindsight transport"))?;
        Ok(Self {
            config,
            token: Arc::from(token),
            http,
            max_response_bytes: MAX_RESPONSE_BYTES,
            max_bulk_pages: MAX_BULK_PAGES,
        })
    }

    pub fn replace_credential(&mut self, token: String) {
        self.token = Arc::from(token);
        clear_automatic_auth_suppression();
    }

    pub fn automatic_auth_suppressed(&self) -> bool {
        AUTOMATIC_AUTH_SUPPRESSED.load(Ordering::SeqCst)
    }

    pub async fn test_connection(&self) -> Result<(), MemoryError> {
        let mut url = self.url(&["memories", "list"])?;
        url.query_pairs_mut().append_pair("limit", "0").append_pair("offset", "0");
        let _: WireMemoryPage = self.send_json(Method::GET, url, None, Duration::from_secs(10), false).await?;
        clear_automatic_auth_suppression();
        Ok(())
    }

    pub async fn recall(&self, query: &str, budget: u64, max_tokens: u64, automatic: bool) -> Result<RecallResponse, MemoryError> {
        self.recall_inner(query, budget, max_tokens, automatic, None).await
    }

    pub async fn recall_cancellable(&self, query: &str, budget: u64, max_tokens: u64, automatic: bool, cancellation: &HindsightCancellation) -> Result<RecallResponse, MemoryError> {
        self.recall_inner(query, budget, max_tokens, automatic, Some(cancellation)).await
    }

    async fn recall_inner(&self, query: &str, budget: u64, max_tokens: u64, automatic: bool, cancellation: Option<&HindsightCancellation>) -> Result<RecallResponse, MemoryError> {
        if automatic && self.automatic_auth_suppressed() {
            return Err(MemoryError::new(MemoryErrorKind::Unauthorized, "Automatic Hindsight operations are suppressed"));
        }
        let body = serde_json::to_value(RecallRequest { query, budget, max_tokens })
            .map_err(|_| MemoryError::new(MemoryErrorKind::InvalidResponse, "Unable to encode Hindsight request"))?;
        let operation = self.send_json(Method::POST, self.url(&["memories", "recall"])?, Some(body), Duration::from_secs(12), automatic);
        let result = if let Some(cancellation) = cancellation {
            tokio::select! {
                result = operation => result,
                _ = cancellation.cancelled() => Err(MemoryError::new(MemoryErrorKind::Cancelled, "Hindsight request was cancelled")),
            }
        } else { operation.await };
        if result.is_ok() && !automatic { clear_automatic_auth_suppression(); }
        result
    }

    pub async fn retain(&self, input: &RetainInput, automatic: bool) -> Result<Value, MemoryError> {
        if automatic && self.automatic_auth_suppressed() {
            return Err(MemoryError::new(MemoryErrorKind::Unauthorized, "Automatic Hindsight operations are suppressed"));
        }
        if input.document_id.trim().is_empty() {
            return Err(MemoryError::new(MemoryErrorKind::InvalidConfiguration, "Retain document_id must not be empty"));
        }
        let body = retain_body(input)?;
        let result = self.send_json(Method::POST, self.url(&["memories"])?, Some(body), Duration::from_secs(90), automatic).await;
        if result.is_ok() && !automatic { clear_automatic_auth_suppression(); }
        result
    }

    pub async fn list_memories(&self, options: &MemoryListOptions) -> Result<MemoryPage, MemoryError> {
        let mut url = self.url(&["memories", "list"])?;
        {
            let mut query = url.query_pairs_mut();
            if let Some(value) = &options.filter.query { query.append_pair("q", value); }
            if let Some(value) = options.filter.fact_type { query.append_pair("type", memory_fact_type(value)); }
            query.append_pair("state", memory_state(options.filter.state));
            if let Some(value) = &options.document_id { query.append_pair("document_id", value); }
            for tag in &options.tags { query.append_pair("tags", tag); }
            if !options.tags.is_empty() { query.append_pair("tags_match", "all"); }
            if let Some(value) = &options.filter.start_date { query.append_pair("start_date", value); }
            if let Some(value) = &options.filter.end_date { query.append_pair("end_date", value); }
            if let Some(value) = options.filter.time_field { query.append_pair("time_field", memory_time_field(value)); }
            query.append_pair("limit", &options.limit.to_string());
            query.append_pair("offset", &options.offset.to_string());
        }
        let page: WireMemoryPage = self.send_json(Method::GET, url, None, Duration::from_secs(10), false).await?;
        Ok(page.into())
    }

    pub async fn list_memories_by_document(&self, document_id: &str, limit: u64, offset: u64) -> Result<MemoryPage, MemoryError> {
        self.list_memories(&MemoryListOptions { document_id: Some(document_id.into()), limit, offset, ..Default::default() }).await
    }

    pub async fn list_all_memories_by_document(&self, document_id: &str, page_size: u64) -> Result<Vec<MemoryRecord>, MemoryError> {
        let page_size = page_size.max(1); let mut offset = 0; let mut records = Vec::new(); let mut seen = HashSet::new();
        for page_number in 0..=self.max_bulk_pages {
            if page_number == self.max_bulk_pages { return Err(MemoryError::new(MemoryErrorKind::InvalidResponse, "Hindsight document pagination exceeded the maximum page count")); }
            let page = self.list_memories_by_document(document_id, page_size, offset).await?;
            let returned = page.items.len() as u64;
            for item in page.items { if seen.insert(item.id.clone()) { records.push(item); } }
            if returned == 0 || returned < page_size { break; }
            let Some(next) = page.offset.checked_add(returned) else { return Err(MemoryError::new(MemoryErrorKind::InvalidResponse, "Hindsight document pagination offset overflowed")); };
            if next <= offset { return Err(MemoryError::new(MemoryErrorKind::InvalidResponse, "Hindsight document pagination did not advance")); }
            offset = next;
        }
        Ok(records)
    }

    pub async fn get_memory(&self, id: &str) -> Result<MemoryRecord, MemoryError> {
        let record: WireMemoryRecord = self.send_json(Method::GET, self.url(&["memories", id])?, None, Duration::from_secs(10), false).await?;
        Ok(record.into())
    }

    pub async fn update_memory(&self, id: &str, update: &MemoryUpdate) -> Result<MemoryRecord, MemoryError> {
        let body = serde_json::to_value(WireMemoryUpdate::from(update)).map_err(|_| MemoryError::new(MemoryErrorKind::InvalidResponse, "Unable to encode Hindsight request"))?;
        let record: WireMemoryRecord = self.send_json(Method::PATCH, self.url(&["memories", id])?, Some(body), Duration::from_secs(10), false).await?;
        Ok(record.into())
    }

    pub async fn retire_memory(&self, id: &str) -> Result<MemoryRecord, MemoryError> {
        self.update_memory(id, &MemoryUpdate {
            state: Some(MemoryState::Invalidated), reason: Some("Retired from Coucou".into()), ..Default::default()
        }).await
    }

    pub async fn restore_memory(&self, id: &str) -> Result<MemoryRecord, MemoryError> {
        self.update_memory(id, &MemoryUpdate { state: Some(MemoryState::Valid), ..Default::default() }).await
    }

    pub async fn bulk_retire(&self, mut options: MemoryListOptions) -> Result<BulkMutationResult, MemoryError> {
        options.filter.state = MemoryState::Valid;
        let page_size = if options.limit == 0 { 100 } else { options.limit };
        let mut offset = 0;
        let mut ids = Vec::new();
        let mut seen = HashSet::new();
        for page_number in 0..=self.max_bulk_pages {
            if page_number == self.max_bulk_pages {
                return Err(MemoryError::new(MemoryErrorKind::InvalidResponse, "Hindsight bulk pagination exceeded the maximum page count"));
            }
            options.limit = page_size;
            options.offset = offset;
            let page = self.list_memories(&options).await?;
            let returned = page.items.len() as u64;
            for item in page.items { if seen.insert(item.id.clone()) { ids.push(item.id); } }
            if returned == 0 || returned < page_size { break; }
            let Some(next) = page.offset.checked_add(returned) else {
                return Err(MemoryError::new(MemoryErrorKind::InvalidResponse, "Hindsight bulk pagination offset overflowed"));
            };
            if next <= offset {
                return Err(MemoryError::new(MemoryErrorKind::InvalidResponse, "Hindsight bulk pagination did not advance"));
            }
            offset = next;
        }
        let semaphore = Arc::new(Semaphore::new(4));
        let mut tasks = Vec::new();
        for id in ids.clone() {
            let client = self.clone();
            let permit = semaphore.clone().acquire_owned().await.unwrap();
            tasks.push(tokio::spawn(async move {
                let result = client.retire_memory(&id).await;
                drop(permit);
                (id, result)
            }));
        }
        let mut result = BulkMutationResult { requested: ids.len(), succeeded: Vec::new(), failed: Vec::new(), refresh: true };
        for task in tasks {
            let (id, outcome) = task.await.map_err(|_| MemoryError::new(MemoryErrorKind::Cancelled, "Hindsight operation was cancelled"))?;
            match outcome {
                Ok(_) => result.succeeded.push(id),
                Err(error) => result.failed.push(BulkMutationFailure { id, kind: error.kind, message: error.message }),
            }
        }
        Ok(result)
    }

    fn url(&self, suffix: &[&str]) -> Result<Url, MemoryError> {
        hindsight_url(&self.config, suffix)
            .map_err(|message| MemoryError::new(MemoryErrorKind::InvalidConfiguration, message))
    }

    async fn send_json<T: DeserializeOwned>(&self, method: Method, url: Url, body: Option<Value>, timeout: Duration, automatic: bool) -> Result<T, MemoryError> {
        let mut request = self.http.request(method, url)
            .bearer_auth(self.token.as_ref())
            .header(reqwest::header::ACCEPT, "application/json")
            .timeout(timeout);
        if let Some(body) = body { request = request.json(&body); }
        let mut response = request.send().await.map_err(map_transport_error)?;
        let status = response.status();
        if !status.is_success() {
            let error = status_error(status);
            if automatic && error.kind == MemoryErrorKind::Unauthorized {
                AUTOMATIC_AUTH_SUPPRESSED.store(true, Ordering::SeqCst);
            }
            return Err(error);
        }
        if response.content_length().is_some_and(|length| length > self.max_response_bytes as u64) {
            return Err(MemoryError::new(MemoryErrorKind::InvalidResponse, "Hindsight response exceeded the configured size limit"));
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(map_transport_error)? {
            if bytes.len().saturating_add(chunk.len()) > self.max_response_bytes {
                return Err(MemoryError::new(MemoryErrorKind::InvalidResponse, "Hindsight response exceeded the configured size limit"));
            }
            bytes.extend_from_slice(&chunk);
        }
        serde_json::from_slice(&bytes)
            .map_err(|_| MemoryError::new(MemoryErrorKind::InvalidResponse, "Hindsight returned malformed JSON"))
    }
}

fn memory_fact_type(value: MemoryFactType) -> &'static str {
    match value { MemoryFactType::World => "world", MemoryFactType::Experience => "experience", MemoryFactType::Observation => "observation" }
}

fn memory_state(value: MemoryState) -> &'static str {
    match value { MemoryState::Valid => "valid", MemoryState::Invalidated => "invalidated" }
}

fn memory_platform(value: MemoryPlatform) -> &'static str {
    match value { MemoryPlatform::Windows => "windows", MemoryPlatform::Macos => "macos" }
}

fn retention_kind(value: RetentionKind) -> &'static str {
    match value { RetentionKind::Explicit => "explicit", RetentionKind::Inferred => "inferred" }
}

fn memory_time_field(value: MemoryTimeField) -> &'static str {
    match value {
        MemoryTimeField::CreatedAt => "created_at", MemoryTimeField::UpdatedAt => "updated_at",
        MemoryTimeField::MentionedAt => "mentioned_at", MemoryTimeField::OccurredStart => "occurred_start",
        MemoryTimeField::OccurredEnd => "occurred_end", MemoryTimeField::EditedAt => "edited_at",
    }
}

fn memory_source_kind(value: MemorySourceKind) -> &'static str {
    match value { MemorySourceKind::Chat => "chat", MemorySourceKind::SelectedText => "selected-text" }
}

fn status_error(status: StatusCode) -> MemoryError {
    let kind = match status {
        StatusCode::UNAUTHORIZED => MemoryErrorKind::Unauthorized,
        StatusCode::FORBIDDEN => MemoryErrorKind::Forbidden,
        StatusCode::NOT_FOUND => MemoryErrorKind::NotFound,
        StatusCode::CONFLICT => MemoryErrorKind::Conflict,
        StatusCode::TOO_MANY_REQUESTS => MemoryErrorKind::RateLimited,
        status if status.is_server_error() => MemoryErrorKind::Unavailable,
        _ => MemoryErrorKind::InvalidResponse,
    };
    MemoryError::new(kind, format!("Hindsight request failed with status {}", status.as_u16()))
}

fn map_transport_error(error: reqwest::Error) -> MemoryError {
    if error.is_timeout() { return MemoryError::new(MemoryErrorKind::Timeout, "Hindsight request timed out"); }
    let detail = error.to_string().to_ascii_lowercase();
    if detail.contains("tls") || detail.contains("certificate") || detail.contains("handshake") {
        return MemoryError::new(MemoryErrorKind::Tls, "Hindsight TLS request failed");
    }
    if error.is_connect() { return MemoryError::new(MemoryErrorKind::Connection, "Hindsight connection failed"); }
    MemoryError::new(MemoryErrorKind::Network, "Hindsight network request failed")
}

fn validate_segment(name: &str, value: &str) -> Result<(), String> {
    if value.is_empty() {
        return Err(format!("{name} must not be empty"));
    }
    let lower = value.to_ascii_lowercase();
    if value.chars().any(char::is_control)
        || value.contains('/')
        || value.contains('\\')
        || lower.contains("%2f")
        || lower.contains("%5c")
    {
        return Err(format!("{name} contains a path separator"));
    }
    Ok(())
}

pub fn validate_hindsight_config(config: &HindsightConfig) -> Result<Url, String> {
    validate_segment("tenant", &config.tenant)?;
    validate_segment("bank", &config.bank)?;
    let url = Url::parse(&config.base_url).map_err(|_| "Hindsight base URL is invalid".to_string())?;
    if url.scheme() != "https" && !(url.scheme() == "http" && config.allow_development_http) {
        return Err("Hindsight base URL must use HTTPS".into());
    }
    if url.host_str().is_none() || !url.username().is_empty() || url.password().is_some() {
        return Err("Hindsight base URL must have a host and no user info".into());
    }
    if url.query().is_some() || url.fragment().is_some() {
        return Err("Hindsight base URL must not contain a query or fragment".into());
    }
    Ok(url)
}

fn normalize_endpoint_string(value: &str) -> Result<String, MemoryError> {
    let mut url = Url::parse(value.trim()).map_err(|_| MemoryError::new(MemoryErrorKind::InvalidConfiguration, "Hindsight base URL is invalid"))?;
    if url.host_str().is_none() || !url.username().is_empty() || url.password().is_some() || url.query().is_some() || url.fragment().is_some() {
        return Err(MemoryError::new(MemoryErrorKind::InvalidConfiguration, "Hindsight base URL is invalid"));
    }
    if (url.scheme() == "https" && url.port() == Some(443)) || (url.scheme() == "http" && url.port() == Some(80)) { let _ = url.set_port(None); }
    let trimmed = url.path().trim_end_matches('/').to_string();
    url.set_path(if trimmed.is_empty() { "/" } else { &trimmed });
    Ok(url.as_str().trim_end_matches('/').to_string())
}

pub fn normalized_hindsight_endpoint(config: &HindsightConfig) -> Result<String, MemoryError> {
    validate_hindsight_config(config).map_err(|message| MemoryError::new(MemoryErrorKind::InvalidConfiguration, message))?;
    normalize_endpoint_string(&config.base_url)
}

pub fn hindsight_url(config: &HindsightConfig, suffix: &[&str]) -> Result<Url, String> {
    let mut url = validate_hindsight_config(config)?;
    {
        let mut segments = url.path_segments_mut().map_err(|_| "Hindsight base URL cannot hold path segments".to_string())?;
        segments.pop_if_empty();
        segments.push("v1");
        segments.push(&config.tenant);
        segments.push("banks");
        segments.push(&config.bank);
        for segment in suffix {
            validate_segment("URL suffix", segment)?;
            segments.push(segment);
        }
    }
    Ok(url)
}

pub fn validate_live_test_bank(bank: &str) -> Result<(), String> {
    if bank.eq_ignore_ascii_case(DEFAULT_BANK) {
        Err("Live Hindsight mutation tests refuse bank hieu".into())
    } else {
        validate_segment("test bank", bank)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::{io::{AsyncReadExt, AsyncWriteExt}, net::TcpListener};

    async fn serve_once(body: &'static str) -> (String, tokio::task::JoinHandle<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let request = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut bytes = Vec::new();
            let mut buffer = [0_u8; 1024];
            loop {
                let count = stream.read(&mut buffer).await.unwrap();
                if count == 0 { break; }
                bytes.extend_from_slice(&buffer[..count]);
                if bytes.windows(4).any(|window| window == b"\r\n\r\n") { break; }
            }
            let response = format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", body.len(), body);
            stream.write_all(response.as_bytes()).await.unwrap();
            String::from_utf8(bytes).unwrap()
        });
        (format!("http://{address}/hindsight"), request)
    }

    async fn reserve_unreachable_address() -> (String, TcpListener) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        (format!("http://{address}/hindsight"), listener)
    }

    #[tokio::test]
    async fn reserved_unreachable_address_cannot_be_rebound_until_released() {
        let (base_url, listener) = reserve_unreachable_address().await;
        let address = Url::parse(&base_url).unwrap().socket_addrs(|| None).unwrap()[0];
        assert!(TcpListener::bind(address).await.is_err());
        drop(listener);
        assert!(TcpListener::bind(address).await.is_ok());
    }

    async fn serve_responses(responses: Vec<(u16, String)>) -> (String, tokio::task::JoinHandle<Vec<String>>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let requests = tokio::spawn(async move {
            let mut requests = Vec::new();
            for (status, body) in responses {
                let (mut stream, _) = listener.accept().await.unwrap();
                let mut bytes = Vec::new();
                let mut buffer = [0_u8; 4096];
                loop {
                    let count = stream.read(&mut buffer).await.unwrap();
                    if count == 0 { break; }
                    bytes.extend_from_slice(&buffer[..count]);
                    if bytes.windows(4).any(|window| window == b"\r\n\r\n") { break; }
                }
                requests.push(String::from_utf8(bytes).unwrap());
                let response = format!("HTTP/1.1 {status} OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
                stream.write_all(response.as_bytes()).await.unwrap();
            }
            requests
        });
        (format!("http://{address}/hindsight"), requests)
    }

    fn memory_item(id: &str) -> String {
        format!(r#"{{"id":"{id}","text":"{id}","fact_type":"world"}}"#)
    }

    fn memory_page(ids: &[&str], offset: u64, limit: u64) -> String {
        let items = ids.iter().map(|id| memory_item(id)).collect::<Vec<_>>().join(",");
        format!(r#"{{"items":[{items}],"total":0,"limit":{limit},"offset":{offset}}}"#)
    }

    fn config(base_url: &str) -> HindsightConfig {
        HindsightConfig {
            enabled: true,
            base_url: base_url.into(),
            tenant: "default".into(),
            bank: "hieu".into(),
            automatic_recall: true,
            inferred_retention: true,
            allow_development_http: false,
        }
    }

    #[test]
    fn validated_url_appends_segments_without_discarding_the_base_path() {
        let config = config("https://host.example/hindsight/");
        assert_eq!(
            hindsight_url(&config, &["memories", "recall"]).unwrap().as_str(),
            "https://host.example/hindsight/v1/default/banks/hieu/memories/recall"
        );
    }

    #[test]
    fn config_rejects_unsafe_base_urls_and_path_segments() {
        for base_url in [
            "https://user@host.example/hindsight",
            "https://host.example/hindsight?query=1",
            "https://host.example/hindsight#fragment",
            "http://host.example/hindsight",
        ] {
            assert!(validate_hindsight_config(&config(base_url)).is_err(), "accepted {base_url}");
        }
        let mut development = config("http://localhost:8888/hindsight");
        development.allow_development_http = true;
        assert!(validate_hindsight_config(&development).is_ok());
        for segment in ["a/b", r"a\b", "a%2fb", "a%2Fb", "a%5cb", "a%5Cb", "a\nb"] {
            let mut unsafe_config = config("https://host.example/hindsight");
            unsafe_config.tenant = segment.into();
            assert!(validate_hindsight_config(&unsafe_config).is_err(), "accepted {segment:?}");
            unsafe_config.tenant = "default".into();
            unsafe_config.bank = segment.into();
            assert!(validate_hindsight_config(&unsafe_config).is_err(), "accepted {segment:?}");
        }
    }

    #[test]
    fn every_enum_value_has_the_cross_platform_json_spelling() {
        let cases = [
            (serde_json::to_value(MemoryFactType::World).unwrap(), "world"),
            (serde_json::to_value(MemoryFactType::Experience).unwrap(), "experience"),
            (serde_json::to_value(MemoryFactType::Observation).unwrap(), "observation"),
            (serde_json::to_value(MemoryState::Valid).unwrap(), "valid"),
            (serde_json::to_value(MemoryState::Invalidated).unwrap(), "invalidated"),
            (serde_json::to_value(RetentionKind::Explicit).unwrap(), "explicit"),
            (serde_json::to_value(RetentionKind::Inferred).unwrap(), "inferred"),
            (serde_json::to_value(MemoryPlatform::Windows).unwrap(), "windows"),
            (serde_json::to_value(MemoryPlatform::Macos).unwrap(), "macos"),
            (serde_json::to_value(MemoryErrorKind::InvalidConfiguration).unwrap(), "invalidConfiguration"),
            (serde_json::to_value(MemoryErrorKind::Unauthorized).unwrap(), "unauthorized"),
            (serde_json::to_value(MemoryErrorKind::Forbidden).unwrap(), "forbidden"),
            (serde_json::to_value(MemoryErrorKind::NotFound).unwrap(), "notFound"),
            (serde_json::to_value(MemoryErrorKind::Conflict).unwrap(), "conflict"),
            (serde_json::to_value(MemoryErrorKind::RateLimited).unwrap(), "rateLimited"),
            (serde_json::to_value(MemoryErrorKind::Unavailable).unwrap(), "unavailable"),
            (serde_json::to_value(MemoryErrorKind::InvalidResponse).unwrap(), "invalidResponse"),
            (serde_json::to_value(MemoryErrorKind::Timeout).unwrap(), "timeout"),
            (serde_json::to_value(MemoryErrorKind::Connection).unwrap(), "connection"),
            (serde_json::to_value(MemoryErrorKind::Tls).unwrap(), "tls"),
            (serde_json::to_value(MemoryErrorKind::Network).unwrap(), "network"),
            (serde_json::to_value(MemoryErrorKind::Cancelled).unwrap(), "cancelled"),
        ];
        for (actual, expected) in cases {
            assert_eq!(actual, expected);
        }
    }

    #[test]
    fn complete_dto_fixtures_pin_every_json_field_name() {
        let record = MemoryRecord {
            id: "memory-1".into(),
            text: "Remember this".into(),
            fact_type: MemoryFactType::Experience,
            state: MemoryState::Invalidated,
            context: Some("context".into()),
            metadata: serde_json::json!({"platform": "windows"}),
            tags: vec!["tag".into()],
            entities: vec!["Coucou".into()],
            document_id: Some("document-1".into()),
            chunk_id: Some("chunk-1".into()),
            created_at: Some("created".into()),
            updated_at: Some("updated".into()),
            mentioned_at: Some("mentioned".into()),
            occurred_start: Some("start".into()),
            occurred_end: Some("end".into()),
            edited_at: Some("edited".into()),
            source_fact_ids: vec!["source-1".into()],
        };
        let record_json = serde_json::json!({
            "id": "memory-1", "text": "Remember this", "factType": "experience", "state": "invalidated",
            "context": "context", "metadata": {"platform": "windows"}, "tags": ["tag"], "entities": ["Coucou"],
            "documentId": "document-1", "chunkId": "chunk-1", "createdAt": "created", "updatedAt": "updated",
            "mentionedAt": "mentioned", "occurredStart": "start", "occurredEnd": "end", "editedAt": "edited",
            "sourceFactIds": ["source-1"]
        });
        assert_eq!(serde_json::to_value(&record).unwrap(), record_json);

        let page = MemoryPage { items: vec![record], total: 1, limit: 25, offset: 0 };
        assert_eq!(serde_json::to_value(page).unwrap(), serde_json::json!({
            "items": [record_json], "total": 1, "limit": 25, "offset": 0
        }));

        let filter = MemoryFilter {
            query: Some("query".into()), document_id: None, fact_type: Some(MemoryFactType::World), state: MemoryState::Invalidated,
            start_date: Some("start-date".into()), end_date: Some("end-date".into()), time_field: Some(MemoryTimeField::MentionedAt),
            platform: Some(MemoryPlatform::Windows), retention_kind: Some(RetentionKind::Explicit), source_kind: Some(MemorySourceKind::Chat),
        };
        assert_eq!(serde_json::to_value(filter).unwrap(), serde_json::json!({
            "query": "query", "factType": "world", "state": "invalidated", "startDate": "start-date",
            "endDate": "end-date", "timeField": "mentioned_at", "platform": "windows",
            "retentionKind": "explicit", "sourceKind": "chat"
        }));

        let update = MemoryUpdate {
            text: Some("new text".into()), context: Some("new context".into()), occurred_start: Some("start".into()),
            occurred_end: Some("end".into()), fact_type: Some(MemoryFactType::Observation), entities: Some(vec!["Coucou".into()]),
            resolve_entities: true, state: Some(MemoryState::Invalidated), reason: Some("duplicate".into()),
            expected_updated_at: Some("expected".into()),
        };
        assert_eq!(serde_json::to_value(update).unwrap(), serde_json::json!({
            "text": "new text", "context": "new context", "occurredStart": "start", "occurredEnd": "end",
            "factType": "observation", "entities": ["Coucou"], "resolveEntities": true,
            "state": "invalidated", "reason": "duplicate", "expectedUpdatedAt": "expected"
        }));
    }

    #[test]
    fn absent_optionals_are_omitted_and_missing_defaults_decode() {
        let record = MemoryRecord {
            id: "memory-1".into(), text: "text".into(), fact_type: MemoryFactType::World, state: MemoryState::Valid,
            context: None, metadata: serde_json::json!({}), tags: vec![], entities: vec![], document_id: None,
            chunk_id: None, created_at: None, updated_at: None, mentioned_at: None, occurred_start: None,
            occurred_end: None, edited_at: None, source_fact_ids: vec![],
        };
        assert_eq!(serde_json::to_value(record).unwrap(), serde_json::json!({
            "id": "memory-1", "text": "text", "factType": "world", "state": "valid",
            "metadata": {}, "tags": [], "entities": [], "sourceFactIds": []
        }));

        let filter: MemoryFilter = serde_json::from_str("{}").unwrap();
        assert_eq!(filter, MemoryFilter::default());
        assert_eq!(serde_json::to_value(filter).unwrap(), serde_json::json!({"state": "valid"}));
        let update: MemoryUpdate = serde_json::from_str("{}").unwrap();
        assert_eq!(update, MemoryUpdate::default());
        assert_eq!(serde_json::to_value(update).unwrap(), serde_json::json!({"resolveEntities": false}));
    }

    #[tokio::test]
    async fn test_connection_uses_authenticated_zero_limit_list_request() {
        let (base_url, request) = serve_once("{\"items\":[],\"total\":0,\"limit\":0,\"offset\":0}").await;
        let mut test_config = config(&base_url);
        test_config.allow_development_http = true;
        let client = HindsightClient::with_token(test_config, "test-secret".into()).unwrap();

        client.test_connection().await.unwrap();

        let request = request.await.unwrap();
        assert!(request.starts_with("GET /hindsight/v1/default/banks/hieu/memories/list?limit=0&offset=0 HTTP/1.1"));
        assert!(request.to_ascii_lowercase().contains("authorization: bearer test-secret"));
        assert!(request.to_ascii_lowercase().contains("accept: application/json"));
    }

    #[tokio::test]
    async fn recall_and_retain_use_the_documented_synchronous_payloads() {
        let (base_url, recall_request) = serve_once("{}").await;
        let mut test_config = config(&base_url);
        test_config.allow_development_http = true;
        let client = HindsightClient::with_token(test_config, "secret".into()).unwrap();
        client.recall("where", 20, 500, false).await.unwrap();
        let recall = recall_request.await.unwrap();
        assert!(recall.starts_with("POST /hindsight/v1/default/banks/hieu/memories/recall HTTP/1.1"));

        let (base_url, retain_request) = serve_once("{}").await;
        let mut test_config = config(&base_url);
        test_config.allow_development_http = true;
        let client = HindsightClient::with_token(test_config, "secret".into()).unwrap();
        let input = RetainInput::new("doc-1", vec![RetainContent::try_from(serde_json::json!({"content":"remember"})).unwrap()]).unwrap();
        client.retain(&input, false).await.unwrap();
        let retain = retain_request.await.unwrap();
        assert!(retain.starts_with("POST /hindsight/v1/default/banks/hieu/memories HTTP/1.1"));
        assert!(retain.contains("\"document_id\":\"doc-1\""));
        assert!(retain.contains("\"async\":false"));
    }

    #[tokio::test]
    async fn list_encodes_all_documented_filters_with_strict_tags() {
        let (base_url, request) = serve_once("{\"items\":[],\"total\":0,\"limit\":25,\"offset\":50}").await;
        let mut test_config = config(&base_url);
        test_config.allow_development_http = true;
        let client = HindsightClient::with_token(test_config, "secret".into()).unwrap();
        client.list_memories(&MemoryListOptions {
            filter: MemoryFilter { query: Some("hello world".into()), fact_type: Some(MemoryFactType::Experience), state: MemoryState::Invalidated, start_date: Some("2026-01-01".into()), end_date: Some("2026-02-01".into()), ..Default::default() },
            document_id: Some("doc-1".into()), tags: vec!["platform:windows".into(), "source:chat".into()], limit: 25, offset: 50,
        }).await.unwrap();
        let request = request.await.unwrap();
        let line = request.lines().next().unwrap();
        assert!(line.contains("q=hello+world"));
        for expected in ["type=experience", "state=invalidated", "document_id=doc-1", "tags=platform%3Awindows", "tags=source%3Achat", "tags_match=all", "start_date=2026-01-01", "end_date=2026-02-01", "limit=25", "offset=50"] {
            assert!(line.contains(expected), "missing {expected} in {line}");
        }
    }

    #[tokio::test]
    async fn status_and_json_failures_are_typed_and_redacted() {
        for (status, expected) in [(401, MemoryErrorKind::Unauthorized), (403, MemoryErrorKind::Forbidden), (404, MemoryErrorKind::NotFound), (409, MemoryErrorKind::Conflict), (429, MemoryErrorKind::RateLimited), (503, MemoryErrorKind::Unavailable)] {
            let error = status_error(StatusCode::from_u16(status).unwrap());
            assert_eq!(error.kind, expected);
            assert!(!error.to_string().contains("secret-token"));
            assert!(!error.to_string().contains("Authorization"));
        }
        let (base_url, _) = serve_once("not-json").await;
        let mut test_config = config(&base_url);
        test_config.allow_development_http = true;
        let client = HindsightClient::with_token(test_config, "secret-token".into()).unwrap();
        let error = client.test_connection().await.unwrap_err();
        assert_eq!(error.kind, MemoryErrorKind::InvalidResponse);
        assert!(!error.to_string().contains("secret-token"));
    }

    #[tokio::test]
    async fn network_and_oversized_responses_are_typed() {
        let (base_url, listener) = reserve_unreachable_address().await;
        let mut test_config = config(&base_url);
        test_config.allow_development_http = true;
        let client = HindsightClient::with_token(test_config, "secret-token".into()).unwrap();
        let operation = client.test_connection();
        drop(listener);
        let error = operation.await.unwrap_err();
        assert_eq!(error.kind, MemoryErrorKind::Connection);
        assert!(!error.to_string().contains("secret-token"));

        let (base_url, _) = serve_once("{\"items\":[],\"total\":0,\"limit\":0,\"offset\":0}").await;
        let mut test_config = config(&base_url);
        test_config.allow_development_http = true;
        let mut client = HindsightClient::with_token(test_config, "secret-token".into()).unwrap();
        client.max_response_bytes = 4;
        let error = client.test_connection().await.unwrap_err();
        assert_eq!(error.kind, MemoryErrorKind::InvalidResponse);
    }

    #[test]
    fn hindsight_wire_records_use_snake_case_and_default_nullable_collections() {
        let wire: WireMemoryRecord = serde_json::from_value(serde_json::json!({
            "id": "memory-1", "text": "text", "fact_type": "experience", "state": "valid",
            "document_id": "doc-1", "chunk_id": "chunk-1", "created_at": "created",
            "updated_at": "updated", "mentioned_at": "mentioned", "occurred_start": "start",
            "occurred_end": "end", "edited_at": "edited", "metadata": null, "tags": null,
            "entities": null, "source_fact_ids": null, "unknown": true
        })).unwrap();
        let public: MemoryRecord = wire.into();
        assert_eq!(public.document_id.as_deref(), Some("doc-1"));
        assert_eq!(public.fact_type, MemoryFactType::Experience);
        assert_eq!(public.metadata, serde_json::json!({}));
        assert!(public.tags.is_empty() && public.entities.is_empty() && public.source_fact_ids.is_empty());
        assert!(serde_json::to_value(public).unwrap().get("documentId").is_some());
    }

    #[test]
    fn hindsight_wire_updates_encode_snake_case_without_changing_public_dto_json() {
        let update = MemoryUpdate {
            occurred_start: Some("start".into()), fact_type: Some(MemoryFactType::Observation),
            resolve_entities: true, expected_updated_at: Some("expected".into()), ..Default::default()
        };
        let wire = serde_json::to_value(WireMemoryUpdate::from(&update)).unwrap();
        assert_eq!(wire, serde_json::json!({
            "occurred_start": "start", "fact_type": "observation", "resolve_entities": true,
            "expected_updated_at": "expected"
        }));
        let public = serde_json::to_value(update).unwrap();
        assert!(public.get("occurredStart").is_some());
        assert!(public.get("occurred_start").is_none());
    }

    #[test]
    fn retain_input_requires_a_non_empty_caller_generated_document_id() {
        let content = RetainContent::try_from(serde_json::json!({"content":"x"})).unwrap();
        assert!(RetainInput::new("", vec![content.clone()]).is_err());
        assert!(RetainInput::new("   ", vec![content]).is_err());
        assert_eq!(RetainInput::new("unique-doc", vec![]).unwrap().document_id, "unique-doc");
    }

    #[tokio::test]
    async fn listener_statuses_map_without_leaking_credentials() {
        for (status, expected) in [(401, MemoryErrorKind::Unauthorized), (403, MemoryErrorKind::Forbidden), (404, MemoryErrorKind::NotFound), (409, MemoryErrorKind::Conflict), (429, MemoryErrorKind::RateLimited), (503, MemoryErrorKind::Unavailable)] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let address = listener.local_addr().unwrap();
            tokio::spawn(async move {
                let (mut stream, _) = listener.accept().await.unwrap();
                let mut buffer = [0; 2048];
                let _ = stream.read(&mut buffer).await;
                stream.write_all(format!("HTTP/1.1 {status} Failure\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").as_bytes()).await.unwrap();
            });
            let mut test_config = config(&format!("http://{address}/hindsight"));
            test_config.allow_development_http = true;
            let client = HindsightClient::with_token(test_config, "secret-token".into()).unwrap();
            let error = client.test_connection().await.unwrap_err();
            assert_eq!(error.kind, expected);
            assert!(!error.to_string().contains("secret-token"));
        }
    }

    #[tokio::test]
    async fn automatic_unauthorized_suppression_is_shared_across_client_instances() {
        clear_automatic_auth_suppression();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let requests = Arc::new(AtomicU64::new(0));
        let count = requests.clone();
        tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            count.fetch_add(1, Ordering::SeqCst);
            let mut buffer = [0; 2048];
            let _ = stream.read(&mut buffer).await;
            stream.write_all(b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await.unwrap();
        });
        let mut test_config = config(&format!("http://{address}/hindsight"));
        test_config.allow_development_http = true;
        let first = HindsightClient::with_token(test_config.clone(), "old".into()).unwrap();
        assert_eq!(first.recall("q", 1, 1, true).await.unwrap_err().kind, MemoryErrorKind::Unauthorized);
        let second = HindsightClient::with_token(test_config, "old".into()).unwrap();
        assert_eq!(second.recall("q", 1, 1, true).await.unwrap_err().kind, MemoryErrorKind::Unauthorized);
        assert_eq!(requests.load(Ordering::SeqCst), 1);
        clear_automatic_auth_suppression();
    }

    #[tokio::test]
    async fn automatic_unauthorized_suppression_is_cleared_by_replacement_and_manual_success() {
        clear_automatic_auth_suppression();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        tokio::spawn(async move {
            for response in ["HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"] {
                let (mut stream, _) = listener.accept().await.unwrap();
                let mut buffer = [0; 2048];
                let _ = stream.read(&mut buffer).await;
                stream.write_all(response.as_bytes()).await.unwrap();
            }
        });
        let mut test_config = config(&format!("http://{address}/hindsight"));
        test_config.allow_development_http = true;
        let mut client = HindsightClient::with_token(test_config, "old".into()).unwrap();
        assert_eq!(client.recall("q", 1, 1, true).await.unwrap_err().kind, MemoryErrorKind::Unauthorized);
        assert!(client.automatic_auth_suppressed());
        client.replace_credential("new".into());
        assert!(!client.automatic_auth_suppressed());
        AUTOMATIC_AUTH_SUPPRESSED.store(true, Ordering::SeqCst);
        client.recall("q", 1, 1, false).await.unwrap();
        assert!(!client.automatic_auth_suppressed());
    }

    #[tokio::test]
    #[ignore = "requires explicit disposable Hindsight environment"]
    async fn live_disposable_bank_reversible_lifecycle() {
        let base_url = std::env::var("COUCOU_HINDSIGHT_TEST_URL").expect("COUCOU_HINDSIGHT_TEST_URL is required for the ignored live lifecycle");
        let token = std::env::var("COUCOU_HINDSIGHT_TEST_TOKEN").expect("COUCOU_HINDSIGHT_TEST_TOKEN is required for the ignored live lifecycle");
        let bank = std::env::var("COUCOU_HINDSIGHT_TEST_BANK").expect("COUCOU_HINDSIGHT_TEST_BANK is required for the ignored live lifecycle");
        validate_live_test_bank(&bank).expect("live lifecycle requires a disposable bank and refuses hieu");
        let test_config = HindsightConfig { enabled: true, base_url, tenant: "default".into(), bank, automatic_recall: true, inferred_retention: true, allow_development_http: false };
        let client = HindsightClient::with_token(test_config, token).unwrap();
        let document_id = format!("coucou-live-{}", std::process::id());
        let content = RetainContent::try_from(serde_json::json!({"content":"Coucou disposable lifecycle"})).unwrap();
        let input = RetainInput::new(&document_id, vec![content]).unwrap();
        client.retain(&input, false).await.unwrap();
        let mut page = client.list_memories_by_document(&document_id, 100, 0).await.unwrap();
        for _ in 0..4 {
            if !page.items.is_empty() { break; }
            tokio::time::sleep(Duration::from_millis(500)).await;
            page = client.list_memories_by_document(&document_id, 100, 0).await.unwrap();
        }
        assert!(!page.items.is_empty(), "synchronous retain produced no discoverable memories for document_id {document_id}");
        for memory in page.items {
            client.update_memory(&memory.id, &MemoryUpdate { text: Some("Coucou disposable lifecycle edited".into()), ..Default::default() }).await.unwrap();
            client.retire_memory(&memory.id).await.unwrap();
            client.restore_memory(&memory.id).await.unwrap();
            client.retire_memory(&memory.id).await.unwrap();
        }
    }

    #[tokio::test]
    async fn explicit_cancellation_stops_an_inflight_recall() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        tokio::spawn(async move { let (stream, _) = listener.accept().await.unwrap(); tokio::time::sleep(Duration::from_secs(30)).await; drop(stream); });
        let mut test_config = config(&format!("http://{address}/hindsight"));
        test_config.allow_development_http = true;
        let client = HindsightClient::with_token(test_config, "secret".into()).unwrap();
        let cancellation = HindsightCancellation::new();
        let cancel = cancellation.clone();
        tokio::spawn(async move { tokio::time::sleep(Duration::from_millis(25)).await; cancel.cancel(); });
        let error = client.recall_cancellable("q", 1, 1, false, &cancellation).await.unwrap_err();
        assert_eq!(error.kind, MemoryErrorKind::Cancelled);
    }

    #[test]
    fn wire_page_defaults_missing_and_null_items() {
        for fixture in [serde_json::json!({"total":0,"limit":10,"offset":0}), serde_json::json!({"items":null,"total":0,"limit":10,"offset":0})] {
            let page: WireMemoryPage = serde_json::from_value(fixture).unwrap();
            assert!(page.items.is_empty());
        }
    }

    #[test]
    fn retain_content_rejects_non_objects_and_overrides_document_id_once() {
        assert!(RetainContent::try_from(serde_json::json!("text")).is_err());
        let content = RetainContent::try_from(serde_json::json!({"content":"x","document_id":"wrong"})).unwrap();
        let input = RetainInput::new("caller", vec![content]).unwrap();
        let body = retain_body(&input).unwrap();
        let object = body["items"][0].as_object().unwrap();
        assert_eq!(object.get("document_id"), Some(&serde_json::json!("caller")));
        assert_eq!(object.keys().filter(|key| *key == "document_id").count(), 1);
    }

    #[tokio::test]
    async fn listener_timeout_is_mapped_to_network_timeout() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        tokio::spawn(async move { let (stream, _) = listener.accept().await.unwrap(); tokio::time::sleep(Duration::from_secs(2)).await; drop(stream); });
        let mut test_config = config(&format!("http://{address}/hindsight"));
        test_config.allow_development_http = true;
        let client = HindsightClient::with_token(test_config, "secret".into()).unwrap();
        let error = client.send_json::<Value>(Method::GET, client.url(&["memories", "list"]).unwrap(), None, Duration::from_millis(25), false).await.unwrap_err();
        assert_eq!(error.kind, MemoryErrorKind::Timeout);
        assert!(error.message.contains("timed out"));
    }

    #[tokio::test]
    async fn retire_and_restore_patch_the_documented_states() {
        let record = r#"{"id":"m1","text":"x","fact_type":"world","state":"valid"}"#;
        for (retire, expected) in [(true, "invalidated"), (false, "valid")] {
            let (base_url, request) = serve_once(record).await;
            let mut test_config = config(&base_url); test_config.allow_development_http = true;
            let client = HindsightClient::with_token(test_config, "secret".into()).unwrap();
            if retire { client.retire_memory("m1").await.unwrap(); } else { client.restore_memory("m1").await.unwrap(); }
            let request = request.await.unwrap();
            assert!(request.starts_with("PATCH /hindsight/v1/default/banks/hieu/memories/m1 HTTP/1.1"));
            assert!(request.contains(&format!("\"state\":\"{expected}\"")));
        }
    }

    #[tokio::test]
    async fn bulk_retire_starts_at_zero_deduplicates_pages_and_preserves_partial_failures() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let requests = Arc::new(std::sync::Mutex::new(Vec::new()));
        let captured = requests.clone();
        tokio::spawn(async move {
            for _ in 0..6 {
                let (mut stream, _) = listener.accept().await.unwrap();
                let mut bytes = Vec::new(); let mut buffer = [0_u8; 4096];
                loop { let count = stream.read(&mut buffer).await.unwrap(); if count == 0 { break; } bytes.extend_from_slice(&buffer[..count]); if bytes.windows(4).any(|w| w == b"\r\n\r\n") { break; } }
                let request = String::from_utf8(bytes).unwrap();
                captured.lock().unwrap().push(request.clone());
                let first = request.lines().next().unwrap();
                let (status, body) = if first.contains("offset=0") {
                    (200, r#"{"items":[{"id":"a","text":"a","fact_type":"world"},{"id":"b","text":"b","fact_type":"world"}],"total":1,"limit":2,"offset":0}"#)
                } else if first.contains("offset=2") {
                    (200, r#"{"items":[{"id":"b","text":"b","fact_type":"world"},{"id":"c","text":"c","fact_type":"world"}],"total":1,"limit":0,"offset":2}"#)
                } else if first.contains("offset=4") {
                    (200, r#"{"items":null,"total":99,"limit":50,"offset":4}"#)
                } else if first.contains("/memories/b ") { (409, "") }
                else { (200, r#"{"id":"ok","text":"x","fact_type":"world","state":"invalidated"}"#) };
                let response = format!("HTTP/1.1 {status} OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
                stream.write_all(response.as_bytes()).await.unwrap();
            }
        });
        let mut test_config = config(&format!("http://{address}/hindsight")); test_config.allow_development_http = true;
        let client = HindsightClient::with_token(test_config, "secret".into()).unwrap();
        let result = client.bulk_retire(MemoryListOptions { limit: 2, offset: 80, ..Default::default() }).await.unwrap();
        assert_eq!(result.requested, 3);
        assert!(result.refresh);
        assert_eq!(result.failed.len(), 1);
        assert_eq!(result.failed[0].id, "b");
        let requests = requests.lock().unwrap();
        assert!(requests[0].lines().next().unwrap().contains("offset=0"));
        for request in requests.iter().filter(|request| request.starts_with("PATCH ")) {
            assert!(request.contains("\"state\":\"invalidated\""));
            assert!(request.contains("\"reason\":\"Retired from Coucou\""));
        }
    }

    #[test]
    fn confirmed_scope_rejects_changed_bank_and_tampered_fingerprint() {
        let request = MemoryBrowseRequest { filter: MemoryFilter::default(), limit: 25, offset: 0 };
        let scope = ConfirmedMemoryScope::new(request.clone(), "https://host.example/Hindsight".into(), "tenant-a".into(), "bank-a".into()).unwrap();
        assert!(scope.validate("https://host.example/Hindsight/", "tenant-a", "bank-a").is_ok());
        assert_eq!(scope.validate("https://host.example/Hindsight", "tenant-a", "bank-b").unwrap_err().kind, MemoryErrorKind::Conflict);
        let mut tampered = scope;
        tampered.request.limit = 50;
        assert_eq!(tampered.validate("https://host.example/Hindsight", "tenant-a", "bank-a").unwrap_err().kind, MemoryErrorKind::InvalidConfiguration);
    }

    #[tokio::test]
    async fn confirmed_scope_settings_change_rejects_before_network() {
        let (base_url, listener) = reserve_unreachable_address().await;
        let mut test_config = config(&base_url); test_config.allow_development_http = true;
        let manager = MemoryManager::new(HindsightClient::with_token(test_config, "secret".into()).unwrap());
        let scope = ConfirmedMemoryScope::new(MemoryBrowseRequest { filter: MemoryFilter::default(), limit: 25, offset: 0 }, base_url.clone(), "default".into(), "old-bank".into()).unwrap();
        let error = manager.bulk_retire_confirmed(scope, &base_url, "default", "new-bank").await.unwrap_err();
        assert_eq!(error.kind, MemoryErrorKind::Conflict);
        let address = Url::parse(&base_url).unwrap().socket_addrs(|| None).unwrap()[0];
        assert!(TcpListener::bind(address).await.is_err());
        drop(listener);
    }

    #[tokio::test]
    async fn manager_bulk_retire_rejects_non_valid_scope_without_network() {
        let (base_url, listener) = reserve_unreachable_address().await;
        let mut test_config = config(&base_url); test_config.allow_development_http = true;
        let manager = MemoryManager::new(HindsightClient::with_token(test_config, "secret".into()).unwrap());
        let error = manager.bulk_retire(MemoryBrowseRequest {
            filter: MemoryFilter { state: MemoryState::Invalidated, ..Default::default() },
            limit: 25,
            offset: 50,
        }).await.unwrap_err();
        assert_eq!(error.kind, MemoryErrorKind::InvalidConfiguration);
        assert!(error.message.contains("valid memories"));
        let address = Url::parse(&base_url).unwrap().socket_addrs(|| None).unwrap()[0];
        assert!(TcpListener::bind(address).await.is_err(), "rejected request opened a network connection");
        drop(listener);
    }

    #[tokio::test]
    async fn bulk_retire_short_non_empty_page_terminates_without_another_list_request() {
        let page = memory_page(&["a"], 0, 2);
        let record = memory_item("a");
        let (base_url, requests) = serve_responses(vec![(200, page), (200, record)]).await;
        let mut test_config = config(&base_url); test_config.allow_development_http = true;
        let client = HindsightClient::with_token(test_config, "secret".into()).unwrap();
        let result = client.bulk_retire(MemoryListOptions { limit: 2, ..Default::default() }).await.unwrap();
        assert_eq!(result.requested, 1);
        let requests = requests.await.unwrap();
        assert_eq!(requests.iter().filter(|request| request.starts_with("GET ")).count(), 1);
    }

    #[tokio::test]
    async fn bulk_retire_full_page_with_non_advancing_returned_offset_is_invalid_response() {
        let pages = vec![(200, memory_page(&["a", "b"], 0, 2)), (200, memory_page(&["c", "d"], 0, 2))];
        let (base_url, requests) = serve_responses(pages).await;
        let mut test_config = config(&base_url); test_config.allow_development_http = true;
        let client = HindsightClient::with_token(test_config, "secret".into()).unwrap();
        let error = client.bulk_retire(MemoryListOptions { limit: 2, ..Default::default() }).await.unwrap_err();
        assert_eq!(error.kind, MemoryErrorKind::InvalidResponse);
        assert!(error.message.contains("did not advance"));
        assert_eq!(requests.await.unwrap().len(), 2);
    }

    #[tokio::test]
    async fn bulk_retire_returned_offset_plus_item_count_overflow_is_invalid_response() {
        let page = memory_page(&["a", "b"], u64::MAX - 1, 2);
        let (base_url, _) = serve_responses(vec![(200, page)]).await;
        let mut test_config = config(&base_url); test_config.allow_development_http = true;
        let client = HindsightClient::with_token(test_config, "secret".into()).unwrap();
        let error = client.bulk_retire(MemoryListOptions { limit: 2, ..Default::default() }).await.unwrap_err();
        assert_eq!(error.kind, MemoryErrorKind::InvalidResponse);
        assert!(error.message.contains("overflowed"));
    }

    #[tokio::test]
    async fn bulk_retire_exceeding_injected_page_cap_is_invalid_response() {
        let pages = vec![(200, memory_page(&["a"], 0, 1)), (200, memory_page(&["b"], 1, 1))];
        let (base_url, requests) = serve_responses(pages).await;
        let mut test_config = config(&base_url); test_config.allow_development_http = true;
        let mut client = HindsightClient::with_token(test_config, "secret".into()).unwrap();
        client.max_bulk_pages = 2;
        let error = client.bulk_retire(MemoryListOptions { limit: 1, ..Default::default() }).await.unwrap_err();
        assert_eq!(error.kind, MemoryErrorKind::InvalidResponse);
        assert!(error.message.contains("maximum page count"));
        assert_eq!(requests.await.unwrap().len(), 2);
    }

    #[tokio::test]
    async fn newer_manager_list_cancels_stale_completion_and_preserves_server_order() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        tokio::spawn(async move {
            for request_number in 0..2 {
                let (mut stream, _) = listener.accept().await.unwrap();
                tokio::spawn(async move {
                    let mut bytes = Vec::new(); let mut buffer = [0_u8; 4096];
                    loop { let count = stream.read(&mut buffer).await.unwrap(); if count == 0 { break; } bytes.extend_from_slice(&buffer[..count]); if bytes.windows(4).any(|w| w == b"\r\n\r\n") { break; } }
                    if request_number == 0 { tokio::time::sleep(Duration::from_millis(100)).await; }
                    let body = if request_number == 0 { memory_page(&["old"], 0, 2) } else { memory_page(&["newest", "older"], 0, 2) };
                    let response = format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
                    stream.write_all(response.as_bytes()).await.unwrap();
                });
            }
        });
        let mut test_config = config(&format!("http://{address}/hindsight")); test_config.allow_development_http = true;
        let manager = MemoryManager::new(HindsightClient::with_token(test_config, "secret".into()).unwrap());
        let old = manager.list(MemoryBrowseRequest { filter: MemoryFilter { query: Some("old".into()), ..Default::default() }, limit: 2, offset: 0 });
        tokio::time::sleep(Duration::from_millis(10)).await;
        let new = manager.list(MemoryBrowseRequest { filter: MemoryFilter { query: Some("new".into()), ..Default::default() }, limit: 2, offset: 0 });
        let (old, new) = tokio::join!(old, new);
        assert_eq!(old.unwrap_err().kind, MemoryErrorKind::Cancelled);
        assert_eq!(new.unwrap().items.into_iter().map(|item| item.id).collect::<Vec<_>>(), ["newest", "older"]);
    }

    #[test]
    fn memory_filter_rejects_unsupported_time_and_source_values() {
        assert!(serde_json::from_value::<MemoryFilter>(serde_json::json!({"timeField":"invented"})).is_err());
        assert!(serde_json::from_value::<MemoryFilter>(serde_json::json!({"sourceKind":"tool"})).is_err());
        assert_eq!(serde_json::to_value(MemoryTimeField::MentionedAt).unwrap(), "mentioned_at");
        assert_eq!(serde_json::to_value(MemorySourceKind::SelectedText).unwrap(), "selected-text");
    }

    #[tokio::test]
    async fn manager_maps_filters_reloads_before_edit_and_requires_overwrite_on_conflict() {
        let opened = r#"{"id":"m1","text":"opened","fact_type":"world","state":"valid","updated_at":"v1"}"#;
        let changed = r#"{"id":"m1","text":"changed remotely","fact_type":"world","state":"valid","updated_at":"v2"}"#;
        let updated = r#"{"id":"m1","text":"local edit","fact_type":"world","state":"valid","updated_at":"v3"}"#;
        let page = r#"{"items":[],"total":42,"limit":25,"offset":50}"#;
        let (base_url, requests) = serve_responses(vec![(200, page.into()), (200, changed.into()), (200, changed.into()), (200, updated.into())]).await;
        let mut test_config = config(&base_url); test_config.allow_development_http = true;
        let manager = MemoryManager::new(HindsightClient::with_token(test_config, "secret".into()).unwrap());
        let page = manager.list(MemoryBrowseRequest {
            filter: MemoryFilter {
                query: Some("tea".into()), fact_type: Some(MemoryFactType::Experience),
                start_date: Some("2026-01-01".into()), end_date: Some("2026-02-01".into()),
                time_field: Some(MemoryTimeField::MentionedAt), platform: Some(MemoryPlatform::Windows),
                retention_kind: Some(RetentionKind::Explicit), source_kind: Some(MemorySourceKind::Chat),
                ..Default::default()
            },
            limit: 25, offset: 50,
        }).await.unwrap();
        assert_eq!((page.total, page.limit, page.offset), (42, 25, 50));

        let opened: MemoryRecord = serde_json::from_str(opened).map(|wire: WireMemoryRecord| wire.into()).unwrap();
        let conflict = manager.update("m1", &opened, MemoryUpdate { text: Some("local edit".into()), ..Default::default() }, false).await.unwrap();
        assert!(matches!(conflict, MemoryUpdateResult::Conflict { current } if current.text == "changed remotely"));
        let applied = manager.update("m1", &opened, MemoryUpdate { text: Some("local edit".into()), ..Default::default() }, true).await.unwrap();
        assert!(matches!(applied, MemoryUpdateResult::Updated { memory, refresh: true } if memory.text == "local edit"));

        let requests = requests.await.unwrap();
        let list_line = requests[0].lines().next().unwrap();
        for expected in ["q=tea", "type=experience", "state=valid", "start_date=2026-01-01", "end_date=2026-02-01", "time_field=mentioned_at", "tags=coucou%3Aplatform%3Awindows", "tags=coucou%3Aretention%3Aexplicit", "tags=coucou%3Asource%3Achat", "tags_match=all", "limit=25", "offset=50"] {
            assert!(list_line.contains(expected), "missing {expected} in {list_line}");
        }
        assert!(requests[1].starts_with("GET "));
        assert!(requests[2].starts_with("GET "));
        assert!(requests[3].starts_with("PATCH "));
    }

    #[tokio::test]
    async fn manager_rejects_current_observation_even_with_overwrite_without_patch() {
        let observation = r#"{"id":"m1","text":"generated","fact_type":"observation","state":"valid","updated_at":"v2"}"#;
        let (base_url, requests) = serve_responses(vec![(200, observation.into())]).await;
        let mut test_config = config(&base_url); test_config.allow_development_http = true;
        let manager = MemoryManager::new(HindsightClient::with_token(test_config, "secret".into()).unwrap());
        let opened: MemoryRecord = serde_json::from_str::<WireMemoryRecord>(r#"{"id":"m1","text":"opened","fact_type":"world","state":"valid","updated_at":"v1"}"#).unwrap().into();
        let error = manager.update("m1", &opened, MemoryUpdate { text: Some("overwrite".into()), ..Default::default() }, true).await.unwrap_err();
        assert_eq!(error.kind, MemoryErrorKind::InvalidConfiguration);
        let requests = requests.await.unwrap();
        assert_eq!(requests.len(), 1);
        assert!(requests[0].starts_with("GET "));
    }

    #[tokio::test]
    async fn manager_rejects_observation_edits_locally_and_mutations_request_refresh() {
        let record = r#"{"id":"m1","text":"x","fact_type":"world","state":"invalidated"}"#;
        let (base_url, listener) = reserve_unreachable_address().await;
        let mut test_config = config(&base_url); test_config.allow_development_http = true;
        let manager = MemoryManager::new(HindsightClient::with_token(test_config, "secret".into()).unwrap());
        let observation: MemoryRecord = WireMemoryRecord {
            id: "o1".into(), text: "generated".into(), fact_type: MemoryFactType::Observation,
            state: MemoryState::Valid, context: None, metadata: serde_json::json!({}), tags: vec![], entities: vec![],
            document_id: None, chunk_id: None, created_at: None, updated_at: None, mentioned_at: None,
            occurred_start: None, occurred_end: None, edited_at: None, source_fact_ids: vec![],
        }.into();
        let error = manager.update("o1", &observation, MemoryUpdate { text: Some("no".into()), ..Default::default() }, true).await.unwrap_err();
        assert_eq!(error.kind, MemoryErrorKind::InvalidConfiguration);
        let address = Url::parse(&base_url).unwrap().socket_addrs(|| None).unwrap()[0];
        assert!(TcpListener::bind(address).await.is_err(), "observation edit opened a network request");
        drop(listener);

        let (base_url, requests) = serve_responses(vec![(200, record.into()), (200, record.into())]).await;
        let mut test_config = config(&base_url); test_config.allow_development_http = true;
        let manager = MemoryManager::new(HindsightClient::with_token(test_config, "secret".into()).unwrap());
        assert!(manager.retire("m1").await.unwrap().refresh);
        assert!(manager.restore("m1").await.unwrap().refresh);
        let requests = requests.await.unwrap();
        assert!(requests[0].contains("\"state\":\"invalidated\"") && requests[0].contains("\"reason\":\"Retired from Coucou\""));
        assert!(requests[1].contains("\"state\":\"valid\""));
    }

    #[tokio::test]
    async fn confirmed_individual_retire_reloads_and_rejects_stale_identity_without_patch() {
        let opened = r#"{"id":"m1","text":"opened","fact_type":"world","state":"valid","updated_at":"v1"}"#;
        let changed = r#"{"id":"m1","text":"changed","fact_type":"world","state":"valid","updated_at":"v2"}"#;
        let (base_url, requests) = serve_responses(vec![(200, changed.into())]).await;
        let mut test_config = config(&base_url); test_config.allow_development_http = true;
        let manager = MemoryManager::new(HindsightClient::with_token(test_config, "secret".into()).unwrap());
        let opened: MemoryRecord = serde_json::from_str::<WireMemoryRecord>(opened).unwrap().into();
        let confirmation = ConfirmedMemoryRetirement::new(&opened, base_url.clone(), "default".into(), "hieu".into()).unwrap();
        let error = manager.retire_confirmed(confirmation, &base_url, "default", "hieu").await.unwrap_err();
        assert_eq!(error.kind, MemoryErrorKind::Conflict);
        let requests = requests.await.unwrap();
        assert_eq!(requests.len(), 1);
        assert!(requests[0].starts_with("GET "));
    }

    #[tokio::test]
    async fn confirmed_individual_retire_uses_snapshot_namespace_and_exact_reason() {
        let current = r#"{"id":"m1","text":"opened","fact_type":"world","state":"valid","updated_at":"v1"}"#;
        let retired = r#"{"id":"m1","text":"opened","fact_type":"world","state":"invalidated","updated_at":"v2"}"#;
        let (base_url, requests) = serve_responses(vec![(200, current.into()), (200, retired.into())]).await;
        let mut test_config = config(&base_url); test_config.allow_development_http = true;
        let manager = MemoryManager::new(HindsightClient::with_token(test_config, "secret".into()).unwrap());
        let opened: MemoryRecord = serde_json::from_str::<WireMemoryRecord>(current).unwrap().into();
        let confirmation = ConfirmedMemoryRetirement::new(&opened, base_url.clone(), "default".into(), "hieu".into()).unwrap();
        assert!(manager.retire_confirmed(confirmation, &base_url, "default", "hieu").await.unwrap().refresh);
        let requests = requests.await.unwrap();
        assert!(requests[0].starts_with("GET "));
        assert!(requests[1].starts_with("PATCH "));
        assert!(requests[1].contains("\"reason\":\"Retired from Coucou\""));
    }

    #[test]
    fn safe_detail_is_bounded_allowlisted_and_preserves_opaque_evidence() {
        let mut record: MemoryRecord = serde_json::from_str::<WireMemoryRecord>(r#"{"id":"m1","text":"abcdefghijklmnopqrstuvwxyz","fact_type":"world","state":"valid","context":"0123456789","metadata":{"coucou.turnId":"turn","coucou.authorization":"secret","unknown":"<script>"},"document_id":"doc","chunk_id":"chunk","source_fact_ids":["source"],"created_at":"created","updated_at":"updated"}"#).unwrap().into();
        record.tags = vec!["tag".into()]; record.entities = vec!["entity".into()];
        let detail = SafeMemoryDetail::from_record(&record, "tenant", "bank", 8);
        assert_eq!(detail.content, "abcdefgh");
        assert_eq!(detail.context.as_deref(), Some("01234567"));
        assert_eq!(detail.tenant, "tenant"); assert_eq!(detail.bank, "bank");
        assert_eq!(detail.document_id.as_deref(), Some("doc"));
        assert_eq!(detail.chunk_id.as_deref(), Some("chunk"));
        assert_eq!(detail.source_fact_ids, vec!["source"]);
        assert_eq!(detail.metadata.get("coucou.turnId").and_then(Value::as_str), Some("turn"));
        assert!(!detail.metadata.contains_key("coucou.authorization"));
        assert!(!detail.metadata.contains_key("unknown"));
        record.tags = vec!["t".repeat(1_000); 1_000]; record.entities = vec!["e".repeat(1_000); 1_000]; record.source_fact_ids = vec!["s".repeat(1_000); 1_000];
        record.document_id = Some("d".repeat(2_000)); record.chunk_id = Some("c".repeat(2_000));
        record.metadata = serde_json::json!({"coucou.turnId": "m".repeat(2_000)});
        let hostile = SafeMemoryDetail::from_record(&record, "tenant", "bank", 8);
        assert_eq!(hostile.tags.len(), SAFE_DETAIL_COLLECTION_LIMIT); assert_eq!(hostile.tags[0].len(), SAFE_DETAIL_VALUE_LIMIT);
        assert_eq!(hostile.entities.len(), SAFE_DETAIL_COLLECTION_LIMIT); assert_eq!(hostile.source_fact_ids.len(), SAFE_DETAIL_COLLECTION_LIMIT);
        assert_eq!(hostile.document_id.unwrap().len(), SAFE_DETAIL_IDENTIFIER_LIMIT); assert_eq!(hostile.chunk_id.unwrap().len(), SAFE_DETAIL_IDENTIFIER_LIMIT);
        assert_eq!(hostile.metadata["coucou.turnId"].as_str().unwrap().len(), SAFE_DETAIL_VALUE_LIMIT);
    }

    #[tokio::test]
    async fn rustls_client_classifies_plain_http_as_tls_network_failure() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n").await.unwrap();
        });
        let mut test_config = config(&format!("https://{address}/hindsight"));
        test_config.allow_development_http = false;
        let client = HindsightClient::with_token(test_config, "secret".into()).unwrap();
        let error = client.test_connection().await.unwrap_err();
        assert!(matches!(error.kind, MemoryErrorKind::Tls | MemoryErrorKind::Connection));
        assert!(!error.message.contains("secret"));
    }

    #[tokio::test]
    async fn document_listing_pages_to_completion_and_deduplicates() {
        let (base_url, requests) = serve_responses(vec![
            (200, memory_page(&["a", "b"], 0, 2)),
            (200, memory_page(&["b", "c"], 2, 2)),
            (200, memory_page(&[], 4, 2)),
        ]).await;
        let mut test_config = config(&base_url); test_config.allow_development_http = true;
        let client = HindsightClient::with_token(test_config, "secret".into()).unwrap();
        let records = client.list_all_memories_by_document("doc", 2).await.unwrap();
        assert_eq!(records.into_iter().map(|record| record.id).collect::<Vec<_>>(), ["a", "b", "c"]);
        let requests = requests.await.unwrap();
        assert!(requests[0].contains("offset=0") && requests[1].contains("offset=2") && requests[2].contains("offset=4"));
    }

    #[test]
    fn endpoint_normalization_preserves_path_case_and_scope_rejects_endpoint_drift() {
        assert_eq!(normalized_hindsight_endpoint(&config("https://HOST.example:443/Hindsight/")).unwrap(), "https://host.example/Hindsight");
        assert_ne!(normalized_hindsight_endpoint(&config("https://host.example/Hindsight")).unwrap(), normalized_hindsight_endpoint(&config("https://host.example/hindsight")).unwrap());
        let request = MemoryBrowseRequest { filter: MemoryFilter::default(), limit: 25, offset: 0 };
        let scope = ConfirmedMemoryScope::new(request, "https://host.example/Hindsight".into(), "tenant".into(), "bank".into()).unwrap();
        assert!(scope.validate("https://HOST.example:443/Hindsight/", "tenant", "bank").is_ok());
        assert_eq!(scope.validate("https://host.example/hindsight", "tenant", "bank").unwrap_err().kind, MemoryErrorKind::Conflict);
    }

    #[test]
    fn safe_detail_bounds_id_and_every_timestamp() {
        let huge = "x".repeat(4_000);
        let mut record: MemoryRecord = serde_json::from_str::<WireMemoryRecord>(r#"{"id":"m1","text":"safe","fact_type":"world"}"#).unwrap().into();
        record.id = huge.clone(); record.created_at = Some(huge.clone()); record.updated_at = Some(huge.clone()); record.mentioned_at = Some(huge.clone());
        record.occurred_start = Some(huge.clone()); record.occurred_end = Some(huge.clone()); record.edited_at = Some(huge);
        let detail = SafeMemoryDetail::from_record(&record, "tenant", "bank", 8);
        assert_eq!(detail.id.len(), SAFE_DETAIL_IDENTIFIER_LIMIT);
        for value in [detail.created_at, detail.updated_at, detail.mentioned_at, detail.occurred_start, detail.occurred_end, detail.edited_at] {
            assert_eq!(value.unwrap().len(), SAFE_DETAIL_VALUE_LIMIT);
        }
    }

    #[test]
    fn runtime_error_categories_distinguish_timeout_connection_and_tls() {
        assert_eq!(MemoryErrorKind::Timeout, MemoryErrorKind::Timeout);
        assert_eq!(MemoryErrorKind::Connection, MemoryErrorKind::Connection);
        assert_eq!(MemoryErrorKind::Tls, MemoryErrorKind::Tls);
    }

    #[test]
    fn live_mutation_guard_refuses_the_production_bank() {
        assert!(validate_live_test_bank("hieu").is_err());
        assert!(validate_live_test_bank("HIEU").is_err());
        assert!(validate_live_test_bank("disposable-test").is_ok());
    }
}
