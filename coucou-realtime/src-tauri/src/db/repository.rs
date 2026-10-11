use rusqlite::{params, Connection, Result};
use serde::{Deserialize, Serialize};
use std::sync::Mutex;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Agent {
    pub id: String,
    pub name: String,
    pub icon: String,
    pub tone: String,
    pub system_prompt: String,
    pub voice: String,
    pub language: String,
    pub is_active: bool,
    pub created_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentMemory {
    pub id: String,
    pub agent_id: String,
    pub category: String, // 'preference', 'project', 'fact'
    pub content: String,
    pub importance: i32,
    pub created_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Session {
    pub id: String,
    pub agent_id: String,
    pub title: String,
    pub mode: String, // 'realtime', 'ultra', 'eco'
    pub started_at: Option<String>,
    pub ended_at: Option<String>,
    pub summary: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionEntry {
    pub id: String,
    pub session_id: String,
    pub speaker: String, // 'user_mic', 'remote_audio', 'agent', 'system'
    pub text: String,
    pub translation: Option<String>,
    pub timestamp_ms: i64,
    pub context_data: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolConfig {
    pub id: String,
    pub tool_type: String, // 'webhook', 'smtp', 'mcp', 'script'
    pub name: String,
    pub config_json: String,
    pub requires_confirmation: bool,
    pub is_enabled: bool,
}

pub struct Database {
    pub conn: Mutex<Connection>,
}

impl Database {
    pub fn new(path: &str) -> Result<Self> {
        let conn = Connection::open(path)?;
        let db = Self {
            conn: Mutex::new(conn),
        };
        db.init_schema()?;
        db.seed_defaults()?;
        Ok(db)
    }

    pub fn new_in_memory() -> Result<Self> {
        let conn = Connection::open_in_memory()?;
        let db = Self {
            conn: Mutex::new(conn),
        };
        db.init_schema()?;
        db.seed_defaults()?;
        Ok(db)
    }

    fn init_schema(&self) -> Result<()> {
        let schema = include_str!("schema.sql");
        let conn = self.conn.lock().unwrap();
        conn.execute_batch(schema)?;
        Ok(())
    }

    fn seed_defaults(&self) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        
        let count: i64 = conn.query_row("SELECT COUNT(*) FROM agents", [], |r| r.get(0))?;
        if count == 0 {
            // Seed default agents
            conn.execute(
                "INSERT INTO agents (id, name, icon, tone, system_prompt, voice, language, is_active)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    "sales-copilot",
                    "Sales Copilot",
                    "Briefcase",
                    "Persuasivo, focado em fechamento e contorno de objeções",
                    "Você é o Sales Copilot, especialista em vendas de alto impacto. Ajude o usuário a conduzir negociações, contorne objeções com elegância e extraia os critérios de decisão do cliente em tempo real.",
                    "alloy",
                    "pt-BR",
                    1
                ],
            )?;

            conn.execute(
                "INSERT INTO agents (id, name, icon, tone, system_prompt, voice, language, is_active)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    "meeting-assist",
                    "Meeting Assist",
                    "Users",
                    "Analítico, neutro e sintetizador",
                    "Você é o Meeting Assist. Acompanhe reuniões no Google Meet/Zoom, identifique os pontos-chave, tarefas acordadas (action items) e resuma os alinhamentos de cada participante.",
                    "echo",
                    "pt-BR",
                    0
                ],
            )?;

            conn.execute(
                "INSERT INTO agents (id, name, icon, tone, system_prompt, voice, language, is_active)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    "operations",
                    "Operations",
                    "Cpu",
                    "Direto, técnico e orientado a processos",
                    "Você é o Operations Copilot. Apoie na documentação técnica, disparo de webhooks, conferência de dados em tela e integração com ferramentas de automação.",
                    "shimmer",
                    "pt-BR",
                    0
                ],
            )?;

            // Seed initial memory for Sales Copilot
            conn.execute(
                "INSERT INTO agent_memories (id, agent_id, category, content, importance)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![
                    "mem-1",
                    "sales-copilot",
                    "preference",
                    "Empresa foca em contratos de valor anual com pagamento à vista ou parcelado em até 3x.",
                    3
                ],
            )?;

            // Seed initial sample tools
            conn.execute(
                "INSERT INTO tools_config (id, tool_type, name, config_json, requires_confirmation, is_enabled)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![
                    "tool-webhook-1",
                    "webhook",
                    "Notificar CRM / Slack",
                    r#"{"url":"https://webhook.site/test","method":"POST","headers":{"Content-Type":"application/json"}}"#,
                    1,
                    1
                ],
            )?;

            conn.execute(
                "INSERT INTO tools_config (id, tool_type, name, config_json, requires_confirmation, is_enabled)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![
                    "tool-smtp-1",
                    "smtp",
                    "Resumo por E-mail",
                    r#"{"host":"smtp.gmail.com","port":587,"user":"copilot@empresa.com","to":"diretoria@empresa.com"}"#,
                    1,
                    1
                ],
            )?;

            conn.execute(
                "INSERT INTO tools_config (id, tool_type, name, config_json, requires_confirmation, is_enabled)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![
                    "tool-mcp-1",
                    "mcp",
                    "Servidor MCP Local (Arquivos & Terminal)",
                    r#"{"command":"npx","args":["-y","@modelcontextprotocol/server-filesystem","./workspace"]}"#,
                    0,
                    1
                ],
            )?;
        }
        Ok(())
    }

    pub fn get_agents(&self) -> Result<Vec<Agent>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, name, icon, tone, system_prompt, voice, language, is_active, created_at FROM agents ORDER BY created_at ASC",
        )?;
        let agents = stmt
            .query_map([], |row| {
                Ok(Agent {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    icon: row.get(2)?,
                    tone: row.get(3)?,
                    system_prompt: row.get(4)?,
                    voice: row.get(5)?,
                    language: row.get(6)?,
                    is_active: row.get::<_, i32>(7)? == 1,
                    created_at: row.get(8)?,
                })
            })?
            .collect::<Result<Vec<_>>>()?;
        Ok(agents)
    }

    pub fn set_active_agent(&self, agent_id: &str) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute("UPDATE agents SET is_active = 0", [])?;
        conn.execute("UPDATE agents SET is_active = 1 WHERE id = ?1", params![agent_id])?;
        Ok(())
    }

    pub fn upsert_agent(&self, agent: &Agent) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO agents (id, name, icon, tone, system_prompt, voice, language, is_active)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
             ON CONFLICT(id) DO UPDATE SET
               name=excluded.name,
               icon=excluded.icon,
               tone=excluded.tone,
               system_prompt=excluded.system_prompt,
               voice=excluded.voice,
               language=excluded.language",
            params![
                agent.id,
                agent.name,
                agent.icon,
                agent.tone,
                agent.system_prompt,
                agent.voice,
                agent.language,
                if agent.is_active { 1 } else { 0 },
            ],
        )?;
        Ok(())
    }

    pub fn delete_agent(&self, agent_id: &str) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute("DELETE FROM agents WHERE id = ?1", params![agent_id])?;
        Ok(())
    }

    // Memories
    pub fn get_memories(&self, agent_id: &str) -> Result<Vec<AgentMemory>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, agent_id, category, content, importance, created_at FROM agent_memories WHERE agent_id = ?1 ORDER BY created_at DESC",
        )?;
        let memories = stmt
            .query_map(params![agent_id], |row| {
                Ok(AgentMemory {
                    id: row.get(0)?,
                    agent_id: row.get(1)?,
                    category: row.get(2)?,
                    content: row.get(3)?,
                    importance: row.get(4)?,
                    created_at: row.get(5)?,
                })
            })?
            .collect::<Result<Vec<_>>>()?;
        Ok(memories)
    }

    pub fn add_memory(&self, memory: &AgentMemory) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO agent_memories (id, agent_id, category, content, importance)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                memory.id,
                memory.agent_id,
                memory.category,
                memory.content,
                memory.importance,
            ],
        )?;
        Ok(())
    }

    pub fn delete_memory(&self, memory_id: &str) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute("DELETE FROM agent_memories WHERE id = ?1", params![memory_id])?;
        Ok(())
    }

    // Sessions & Entries
    pub fn create_session(&self, session: &Session) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO sessions (id, agent_id, title, mode, summary)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![session.id, session.agent_id, session.title, session.mode, session.summary],
        )?;
        Ok(())
    }

    pub fn get_sessions(&self) -> Result<Vec<Session>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, agent_id, title, mode, started_at, ended_at, summary FROM sessions ORDER BY started_at DESC",
        )?;
        let sessions = stmt
            .query_map([], |row| {
                Ok(Session {
                    id: row.get(0)?,
                    agent_id: row.get(1)?,
                    title: row.get(2)?,
                    mode: row.get(3)?,
                    started_at: row.get(4)?,
                    ended_at: row.get(5)?,
                    summary: row.get(6)?,
                })
            })?
            .collect::<Result<Vec<_>>>()?;
        Ok(sessions)
    }

    pub fn add_session_entry(&self, entry: &SessionEntry) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO session_entries (id, session_id, speaker, text, translation, timestamp_ms, context_data)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                entry.id,
                entry.session_id,
                entry.speaker,
                entry.text,
                entry.translation,
                entry.timestamp_ms,
                entry.context_data,
            ],
        )?;
        Ok(())
    }

    pub fn get_session_entries(&self, session_id: &str) -> Result<Vec<SessionEntry>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, session_id, speaker, text, translation, timestamp_ms, context_data FROM session_entries WHERE session_id = ?1 ORDER BY timestamp_ms ASC",
        )?;
        let entries = stmt
            .query_map(params![session_id], |row| {
                Ok(SessionEntry {
                    id: row.get(0)?,
                    session_id: row.get(1)?,
                    speaker: row.get(2)?,
                    text: row.get(3)?,
                    translation: row.get(4)?,
                    timestamp_ms: row.get(5)?,
                    context_data: row.get(6)?,
                })
            })?
            .collect::<Result<Vec<_>>>()?;
        Ok(entries)
    }

    // Tools
    pub fn get_tools(&self) -> Result<Vec<ToolConfig>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, tool_type, name, config_json, requires_confirmation, is_enabled FROM tools_config",
        )?;
        let tools = stmt
            .query_map([], |row| {
                Ok(ToolConfig {
                    id: row.get(0)?,
                    tool_type: row.get(1)?,
                    name: row.get(2)?,
                    config_json: row.get(3)?,
                    requires_confirmation: row.get::<_, i32>(4)? == 1,
                    is_enabled: row.get::<_, i32>(5)? == 1,
                })
            })?
            .collect::<Result<Vec<_>>>()?;
        Ok(tools)
    }

    pub fn update_tool(&self, tool: &ToolConfig) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO tools_config (id, tool_type, name, config_json, requires_confirmation, is_enabled)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT(id) DO UPDATE SET
                tool_type=excluded.tool_type,
                name=excluded.name,
                config_json=excluded.config_json,
                requires_confirmation=excluded.requires_confirmation,
                is_enabled=excluded.is_enabled",
            params![
                tool.id,
                tool.tool_type,
                tool.name,
                tool.config_json,
                if tool.requires_confirmation { 1 } else { 0 },
                if tool.is_enabled { 1 } else { 0 },
            ],
        )?;
        Ok(())
    }
}
