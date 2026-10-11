import { Agent, AgentMemory, Session, SessionEntry, ToolConfig, OcrResult, AudioDeviceInfo } from '../types';

let invokeFn: any = null;
try {
  // @ts-ignore
  if (window.__TAURI_INTERNALS__) {
    // Dynamic import to avoid crash if outside tauri
    import('@tauri-apps/api/core').then((mod) => {
      invokeFn = mod.invoke;
    });
  }
} catch {
  // web preview mode
}

const DEFAULT_AGENTS: Agent[] = [
  {
    id: 'sales-copilot',
    name: 'Sales Copilot',
    icon: 'Briefcase',
    tone: 'Persuasivo, focado em fechamento e contorno de objeções',
    system_prompt: 'Você é o Sales Copilot, especialista em vendas de alto impacto. Ajude o usuário a conduzir negociações, contorne objeções com elegância e extraia os critérios de decisão do cliente em tempo real.',
    voice: 'alloy',
    language: 'pt-BR',
    is_active: true,
    created_at: new Date().toISOString(),
  },
  {
    id: 'meeting-assist',
    name: 'Meeting Assist',
    icon: 'Users',
    tone: 'Analítico, neutro e sintetizador',
    system_prompt: 'Você é o Meeting Assist. Acompanhe reuniões no Google Meet/Zoom, identifique os pontos-chave, tarefas acordadas (action items) e resuma os alinhamentos de cada participante.',
    voice: 'echo',
    language: 'pt-BR',
    is_active: false,
    created_at: new Date().toISOString(),
  },
  {
    id: 'operations',
    name: 'Operations',
    icon: 'Cpu',
    tone: 'Direto, técnico e orientado a processos',
    system_prompt: 'Você é o Operations Copilot. Apoie na documentação técnica, disparo de webhooks, conferência de dados em tela e integração com ferramentas de automação.',
    voice: 'shimmer',
    language: 'pt-BR',
    is_active: false,
    created_at: new Date().toISOString(),
  },
];

const DEFAULT_MEMORIES: AgentMemory[] = [
  {
    id: 'mem-1',
    agent_id: 'sales-copilot',
    category: 'preference',
    content: 'Cliente prefere reuniões curtas de 30 minutos e tem foco em ROI no 1º trimestre.',
    importance: 3,
    created_at: new Date().toISOString(),
  },
  {
    id: 'mem-2',
    agent_id: 'sales-copilot',
    category: 'fact',
    content: 'Orçamento aprovado de até R$ 20.000 para a implantação inicial.',
    importance: 2,
    created_at: new Date().toISOString(),
  },
];

const DEFAULT_TOOLS: ToolConfig[] = [
  {
    id: 'tool-webhook-1',
    tool_type: 'webhook',
    name: 'Notificar CRM / Slack',
    config_json: JSON.stringify({ url: 'https://webhook.site/test', method: 'POST' }),
    requires_confirmation: true,
    is_enabled: true,
  },
  {
    id: 'tool-smtp-1',
    tool_type: 'smtp',
    name: 'Disparar Resumo por E-mail',
    config_json: JSON.stringify({ to: 'gestor@empresa.com', subject: 'Ata da Reunião' }),
    requires_confirmation: true,
    is_enabled: true,
  },
  {
    id: 'tool-mcp-1',
    tool_type: 'mcp',
    name: 'Servidor MCP Local (Arquivos & Terminal)',
    config_json: JSON.stringify({ command: 'npx', args: ['@modelcontextprotocol/server-filesystem'] }),
    requires_confirmation: false,
    is_enabled: true,
  },
];

export const storage = {
  async getAgents(): Promise<Agent[]> {
    if (invokeFn) {
      try {
        return await invokeFn('get_agents');
      } catch (e) {
        console.warn('Tauri invoke error, falling back to local storage', e);
      }
    }
    const raw = localStorage.getItem('coucou_agents');
    if (!raw) {
      localStorage.setItem('coucou_agents', JSON.stringify(DEFAULT_AGENTS));
      return DEFAULT_AGENTS;
    }
    return JSON.parse(raw);
  },

  async setActiveAgent(agentId: string): Promise<void> {
    if (invokeFn) {
      try {
        await invokeFn('set_active_agent', { agentId });
        return;
      } catch (e) {
        console.warn('Tauri invoke error', e);
      }
    }
    const agents = await this.getAgents();
    const updated = agents.map((a) => ({ ...a, is_active: a.id === agentId }));
    localStorage.setItem('coucou_agents', JSON.stringify(updated));
  },

  async upsertAgent(agent: Agent): Promise<void> {
    if (invokeFn) {
      try {
        await invokeFn('upsert_agent', { agent });
        return;
      } catch (e) {
        console.warn('Tauri invoke error', e);
      }
    }
    const agents = await this.getAgents();
    const idx = agents.findIndex((a) => a.id === agent.id);
    if (idx >= 0) {
      agents[idx] = agent;
    } else {
      agents.push(agent);
    }
    localStorage.setItem('coucou_agents', JSON.stringify(agents));
  },

  async deleteAgent(agentId: string): Promise<void> {
    if (invokeFn) {
      try {
        await invokeFn('delete_agent', { agentId });
        return;
      } catch (e) {
        console.warn('Tauri invoke error', e);
      }
    }
    const agents = await this.getAgents();
    const filtered = agents.filter((a) => a.id !== agentId);
    localStorage.setItem('coucou_agents', JSON.stringify(filtered));
  },

  async getMemories(agentId: string): Promise<AgentMemory[]> {
    if (invokeFn) {
      try {
        return await invokeFn('get_memories', { agentId });
      } catch (e) {
        console.warn('Tauri invoke error', e);
      }
    }
    const raw = localStorage.getItem(`coucou_memories_${agentId}`);
    if (!raw) {
      const initial = DEFAULT_MEMORIES.filter((m) => m.agent_id === agentId);
      localStorage.setItem(`coucou_memories_${agentId}`, JSON.stringify(initial));
      return initial;
    }
    return JSON.parse(raw);
  },

  async addMemory(memory: AgentMemory): Promise<void> {
    if (invokeFn) {
      try {
        await invokeFn('add_memory', { memory });
        return;
      } catch (e) {
        console.warn('Tauri invoke error', e);
      }
    }
    const list = await this.getMemories(memory.agent_id);
    list.unshift(memory);
    localStorage.setItem(`coucou_memories_${memory.agent_id}`, JSON.stringify(list));
  },

  async deleteMemory(agentId: string, memoryId: string): Promise<void> {
    if (invokeFn) {
      try {
        await invokeFn('delete_memory', { memoryId });
        return;
      } catch (e) {
        console.warn('Tauri invoke error', e);
      }
    }
    const list = await this.getMemories(agentId);
    const filtered = list.filter((m) => m.id !== memoryId);
    localStorage.setItem(`coucou_memories_${agentId}`, JSON.stringify(filtered));
  },

  async getSessions(): Promise<Session[]> {
    if (invokeFn) {
      try {
        return await invokeFn('get_sessions');
      } catch (e) {
        console.warn('Tauri invoke error', e);
      }
    }
    const raw = localStorage.getItem('coucou_sessions');
    if (!raw) {
      const demo: Session[] = [
        {
          id: 'sess-1',
          agent_id: 'sales-copilot',
          title: 'Alinhamento Comercial Proposta Q4',
          mode: 'realtime',
          started_at: new Date(Date.now() - 3600000).toISOString(),
          summary: 'Discussão sobre escopo técnico e prazo de entrega. Cliente concordou com início na próxima segunda-feira.',
        },
      ];
      localStorage.setItem('coucou_sessions', JSON.stringify(demo));
      return demo;
    }
    return JSON.parse(raw);
  },

  async createSession(session: Session): Promise<void> {
    if (invokeFn) {
      try {
        await invokeFn('create_session', { session });
        return;
      } catch (e) {
        console.warn('Tauri invoke error', e);
      }
    }
    const sessions = await this.getSessions();
    sessions.unshift(session);
    localStorage.setItem('coucou_sessions', JSON.stringify(sessions));
  },

  async getTools(): Promise<ToolConfig[]> {
    if (invokeFn) {
      try {
        return await invokeFn('get_tools');
      } catch (e) {
        console.warn('Tauri invoke error', e);
      }
    }
    const raw = localStorage.getItem('coucou_tools');
    if (!raw) {
      localStorage.setItem('coucou_tools', JSON.stringify(DEFAULT_TOOLS));
      return DEFAULT_TOOLS;
    }
    return JSON.parse(raw);
  },

  async updateTool(tool: ToolConfig): Promise<void> {
    if (invokeFn) {
      try {
        await invokeFn('update_tool', { tool });
        return;
      } catch (e) {
        console.warn('Tauri invoke error', e);
      }
    }
    const tools = await this.getTools();
    const idx = tools.findIndex((t) => t.id === tool.id);
    if (idx >= 0) {
      tools[idx] = tool;
    } else {
      tools.push(tool);
    }
    localStorage.setItem('coucou_tools', JSON.stringify(tools));
  },

  async captureScreenContext(): Promise<OcrResult> {
    if (invokeFn) {
      try {
        return await invokeFn('capture_screen_context');
      } catch (e) {
        console.warn('Tauri invoke error', e);
      }
    }
    return {
      success: true,
      active_window: 'Google Meet / Navegador Windows',
      extracted_text: '[Tela Capturada]\nPauta: Alinhamento de Metas e Operações de Vendas Q4.\nParticipantes: Roberto, Mariana e Equipe de Produto.',
      confidence: 0.98,
      timestamp_ms: Date.now(),
    };
  },

  async getAudioDevices(): Promise<AudioDeviceInfo[]> {
    if (invokeFn) {
      try {
        return await invokeFn('get_audio_devices');
      } catch (e) {
        console.warn('Tauri invoke error', e);
      }
    }
    return [
      { name: 'Microfone Realtek High Definition Audio (Padrão)', is_default: true },
      { name: 'Headset Microfone USB', is_default: false },
    ];
  },

  async toggleMainWindow(): Promise<boolean> {
    if (invokeFn) {
      try {
        return await invokeFn('toggle_main_window');
      } catch (e) {
        console.warn('Tauri invoke error', e);
      }
    }
    return true;
  },

  getApiKey(): string {
    return localStorage.getItem('coucou_openai_api_key') || '';
  },

  setApiKey(key: string): void {
    localStorage.setItem('coucou_openai_api_key', key.trim());
  },
};
