use crate::db::repository::{Agent, AgentMemory, Database, Session, SessionEntry, ToolConfig};
use crate::tools::runner::{ToolExecutionRequest, ToolExecutionResponse, ToolRunner};
use tauri::{command, State};

#[command]
pub fn get_agents(db: State<'_, Database>) -> Result<Vec<Agent>, String> {
    db.get_agents().map_err(|e| e.to_string())
}

#[command]
pub fn set_active_agent(agent_id: String, db: State<'_, Database>) -> Result<(), String> {
    db.set_active_agent(&agent_id).map_err(|e| e.to_string())
}

#[command]
pub fn upsert_agent(agent: Agent, db: State<'_, Database>) -> Result<(), String> {
    db.upsert_agent(&agent).map_err(|e| e.to_string())
}

#[command]
pub fn delete_agent(agent_id: String, db: State<'_, Database>) -> Result<(), String> {
    db.delete_agent(&agent_id).map_err(|e| e.to_string())
}

#[command]
pub fn get_memories(agent_id: String, db: State<'_, Database>) -> Result<Vec<AgentMemory>, String> {
    db.get_memories(&agent_id).map_err(|e| e.to_string())
}

#[command]
pub fn add_memory(memory: AgentMemory, db: State<'_, Database>) -> Result<(), String> {
    db.add_memory(&memory).map_err(|e| e.to_string())
}

#[command]
pub fn delete_memory(memory_id: String, db: State<'_, Database>) -> Result<(), String> {
    db.delete_memory(&memory_id).map_err(|e| e.to_string())
}

#[command]
pub fn get_sessions(db: State<'_, Database>) -> Result<Vec<Session>, String> {
    db.get_sessions().map_err(|e| e.to_string())
}

#[command]
pub fn create_session(session: Session, db: State<'_, Database>) -> Result<(), String> {
    db.create_session(&session).map_err(|e| e.to_string())
}

#[command]
pub fn get_session_entries(
    session_id: String,
    db: State<'_, Database>,
) -> Result<Vec<SessionEntry>, String> {
    db.get_session_entries(&session_id).map_err(|e| e.to_string())
}

#[command]
pub fn add_session_entry(
    entry: SessionEntry,
    db: State<'_, Database>,
) -> Result<(), String> {
    db.add_session_entry(&entry).map_err(|e| e.to_string())
}

#[command]
pub fn get_tools(db: State<'_, Database>) -> Result<Vec<ToolConfig>, String> {
    db.get_tools().map_err(|e| e.to_string())
}

#[command]
pub fn update_tool(tool: ToolConfig, db: State<'_, Database>) -> Result<(), String> {
    db.update_tool(&tool).map_err(|e| e.to_string())
}

#[command]
pub async fn execute_tool(
    request: ToolExecutionRequest,
) -> Result<ToolExecutionResponse, String> {
    ToolRunner::run(request).await
}
