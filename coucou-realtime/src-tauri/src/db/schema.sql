-- 1. Agentes
CREATE TABLE IF NOT EXISTS agents (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    icon TEXT NOT NULL,
    tone TEXT NOT NULL,
    system_prompt TEXT NOT NULL,
    voice TEXT NOT NULL DEFAULT 'alloy',
    language TEXT NOT NULL DEFAULT 'pt-BR',
    is_active INTEGER DEFAULT 0,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- 2. Memória Persistente Isolada por Agente
CREATE TABLE IF NOT EXISTS agent_memories (
    id TEXT PRIMARY KEY,
    agent_id TEXT NOT NULL,
    category TEXT NOT NULL, -- 'preference', 'project', 'fact'
    content TEXT NOT NULL,
    importance INTEGER DEFAULT 1,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY(agent_id) REFERENCES agents(id) ON DELETE CASCADE
);

-- 3. Sessões
CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    agent_id TEXT NOT NULL,
    title TEXT NOT NULL,
    mode TEXT NOT NULL, -- 'realtime', 'ultra', 'eco'
    started_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    ended_at DATETIME,
    summary TEXT,
    FOREIGN KEY(agent_id) REFERENCES agents(id)
);

-- 4. Eventos e Transcrições da Sessão
CREATE TABLE IF NOT EXISTS session_entries (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    speaker TEXT NOT NULL, -- 'user_mic', 'remote_audio', 'agent', 'system'
    text TEXT NOT NULL,
    translation TEXT,
    timestamp_ms INTEGER NOT NULL,
    context_data TEXT, -- JSON com metadados do OCR ou tela
    FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE
);

-- 5. Ferramentas e Integrações
CREATE TABLE IF NOT EXISTS tools_config (
    id TEXT PRIMARY KEY,
    tool_type TEXT NOT NULL, -- 'webhook', 'smtp', 'mcp', 'script'
    name TEXT NOT NULL,
    config_json TEXT NOT NULL, -- endpoints, headers, credenciais criptografadas
    requires_confirmation INTEGER DEFAULT 1,
    is_enabled INTEGER DEFAULT 1
);

-- 6. Associação Agente <-> Ferramenta
CREATE TABLE IF NOT EXISTS agent_tools (
    agent_id TEXT NOT NULL,
    tool_id TEXT NOT NULL,
    PRIMARY KEY(agent_id, tool_id),
    FOREIGN KEY(agent_id) REFERENCES agents(id) ON DELETE CASCADE,
    FOREIGN KEY(tool_id) REFERENCES tools_config(id) ON DELETE CASCADE
);
