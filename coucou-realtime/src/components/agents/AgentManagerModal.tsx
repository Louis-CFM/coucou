import React, { useState } from 'react';
import {
  X,
  Bot,
  Plus,
  Trash2,
  Bookmark,
  Check,
  Volume2,
  Briefcase,
  Users,
  Cpu,
  Shield,
  Scale,
  GraduationCap,
  Sparkles,
  Brain,
  Code,
  Stethoscope,
  Globe,
  Mail,
  Terminal,
  Eye,
  Radio,
} from 'lucide-react';
import { Agent, AgentMemory } from '../../types';

interface AgentManagerModalProps {
  isOpen: boolean;
  onClose: () => void;
  agents: Agent[];
  activeAgent: Agent | null;
  memories: AgentMemory[];
  onSelectAgent: (id: string) => void;
  onSaveAgent: (agent: Agent) => void;
  onDeleteAgent: (id: string) => void;
  onAddMemory: (content: string, category: 'preference' | 'project' | 'fact') => void;
  onDeleteMemory: (memoryId: string) => void;
}

const AVAILABLE_ICONS = [
  { id: 'Briefcase', label: 'Vendas', icon: <Briefcase size={14} /> },
  { id: 'Users', label: 'Reuniões', icon: <Users size={14} /> },
  { id: 'Cpu', label: 'Operações', icon: <Cpu size={14} /> },
  { id: 'Scale', label: 'Jurídico', icon: <Scale size={14} /> },
  { id: 'Brain', label: 'Estratégia', icon: <Brain size={14} /> },
  { id: 'Code', label: 'Engenharia', icon: <Code size={14} /> },
  { id: 'Shield', label: 'Auditoria', icon: <Shield size={14} /> },
  { id: 'Sparkles', label: 'Geral', icon: <Sparkles size={14} /> },
];

const AVAILABLE_TOOLS = [
  { id: 'webhook', name: 'Webhooks REST (CRM / Slack / HubSpot)', icon: <Globe size={13} /> },
  { id: 'smtp', name: 'Disparo de E-mails SMTP (Atas & Resumos)', icon: <Mail size={13} /> },
  { id: 'mcp', name: 'Servidor MCP (Model Context Protocol)', icon: <Terminal size={13} /> },
  { id: 'ocr', name: 'Leitura de Tela Ativa (OCR Win32)', icon: <Eye size={13} /> },
];

export const AgentManagerModal: React.FC<AgentManagerModalProps> = ({
  isOpen,
  onClose,
  agents,
  activeAgent,
  memories,
  onSelectAgent,
  onSaveAgent,
  onDeleteAgent,
  onAddMemory,
  onDeleteMemory,
}) => {
  const [selectedAgentId, setSelectedAgentId] = useState<string>(
    activeAgent?.id || (agents[0]?.id as string) || ''
  );
  const [isEditing, setIsEditing] = useState(false);
  const [newMemoryText, setNewMemoryText] = useState('');
  const [newMemoryCat, setNewMemoryCat] = useState<'preference' | 'project' | 'fact'>('preference');

  const current = agents.find((a) => a.id === selectedAgentId) || activeAgent || agents[0];

  const [formState, setFormState] = useState<Agent>({
    id: current?.id || 'new-agent',
    name: current?.name || '',
    icon: current?.icon || 'Sparkles',
    tone: current?.tone || '',
    system_prompt: current?.system_prompt || '',
    voice: current?.voice || 'alloy',
    language: current?.language || 'pt-BR',
    is_active: current?.is_active || false,
    status: current?.status || 'active',
    tools: current?.tools || ['webhook', 'ocr'],
  });

  if (!isOpen) return null;

  const handleSelect = (agent: Agent) => {
    setSelectedAgentId(agent.id);
    setFormState({
      ...agent,
      status: agent.status || 'active',
      tools: agent.tools || ['webhook', 'ocr'],
    });
    setIsEditing(false);
  };

  const handleApplyActive = () => {
    if (current) {
      onSelectAgent(current.id);
    }
  };

  const handleSaveCurrent = () => {
    onSaveAgent(formState);
    setIsEditing(false);
  };

  const handleCreateNew = () => {
    const newId = `agent-${Date.now()}`;
    const newAgent: Agent = {
      id: newId,
      name: 'Novo Agente Personalizado',
      icon: 'Sparkles',
      tone: 'Profissional, proativo e acolhedor',
      system_prompt: 'Você é um assistente pessoal inteligente focado em produtividade e suporte a decisões.',
      voice: 'alloy',
      language: 'pt-BR',
      is_active: false,
      status: 'active',
      tools: ['webhook', 'ocr'],
    };
    setSelectedAgentId(newId);
    setFormState(newAgent);
    setIsEditing(true);
  };

  const handleToggleTool = (toolId: string) => {
    const currentTools = formState.tools || [];
    const exists = currentTools.includes(toolId);
    const updated = exists
      ? currentTools.filter((t) => t !== toolId)
      : [...currentTools, toolId];
    setFormState({ ...formState, tools: updated });
  };

  const handleAddMemorySubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!newMemoryText.trim()) return;
    onAddMemory(newMemoryText.trim(), newMemoryCat);
    setNewMemoryText('');
  };

  const renderIconBadge = (iconName: string) => {
    switch (iconName) {
      case 'Briefcase': return <Briefcase size={14} className="text-indigo-400" />;
      case 'Users': return <Users size={14} className="text-emerald-400" />;
      case 'Cpu': return <Cpu size={14} className="text-cyan-400" />;
      case 'Scale': return <Scale size={14} className="text-amber-400" />;
      case 'Brain': return <Brain size={14} className="text-violet-400" />;
      case 'Code': return <Code size={14} className="text-blue-400" />;
      case 'Shield': return <Shield size={14} className="text-rose-400" />;
      default: return <Sparkles size={14} className="text-indigo-400" />;
    }
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/80 backdrop-blur-sm p-4 animate-in fade-in duration-150">
      <div className="w-full max-w-5xl h-[85vh] bg-zinc-900 border border-zinc-800 rounded-2xl shadow-2xl overflow-hidden flex flex-col">
        {/* Header */}
        <div className="flex items-center justify-between px-6 py-4 border-b border-zinc-800 bg-zinc-900/80">
          <div className="flex items-center gap-2.5">
            <div className="w-8 h-8 rounded-lg bg-indigo-500/10 border border-indigo-500/20 flex items-center justify-center text-indigo-400">
              <Bot size={16} />
            </div>
            <div>
              <h2 className="text-sm font-semibold text-white">Central de Agentes & Memória Isolada (Seção 4.5)</h2>
              <p className="text-[11px] text-zinc-400">
                Personalidades especializadas com nome, tom, voz, prompt, memórias e ferramentas exclusivas
              </p>
            </div>
          </div>
          <button
            onClick={onClose}
            className="p-1 rounded-lg text-zinc-400 hover:text-white hover:bg-zinc-800 transition-colors cursor-pointer"
          >
            <X size={18} />
          </button>
        </div>

        {/* Body 2 columns */}
        <div className="flex-1 flex overflow-hidden">
          {/* Left Column: Agents List */}
          <div className="w-80 border-r border-zinc-800 p-4 flex flex-col bg-zinc-950/40">
            <div className="flex items-center justify-between mb-3">
              <span className="text-xs font-semibold text-zinc-400">Agentes Cadastrados</span>
              <button
                onClick={handleCreateNew}
                className="flex items-center gap-1 text-[11px] text-indigo-400 hover:text-indigo-300 font-semibold cursor-pointer"
              >
                <Plus size={12} />
                <span>+ Novo Agente</span>
              </button>
            </div>

            <div className="flex-1 overflow-y-auto space-y-2 pr-1">
              {agents.map((ag) => {
                const isSelected = current?.id === ag.id;
                const isActive = activeAgent?.id === ag.id;

                return (
                  <button
                    key={ag.id}
                    onClick={() => handleSelect(ag)}
                    className={`w-full text-left p-3 rounded-xl border transition-all cursor-pointer ${
                      isSelected
                        ? 'bg-zinc-800 border-indigo-500/40 shadow-sm'
                        : 'bg-zinc-900/40 border-zinc-800/80 hover:bg-zinc-900 hover:border-zinc-700/60'
                    }`}
                  >
                    <div className="flex items-center justify-between mb-1">
                      <div className="flex items-center gap-2">
                        <div className="w-6 h-6 rounded-md bg-zinc-900 border border-zinc-800 flex items-center justify-center">
                          {renderIconBadge(ag.icon)}
                        </div>
                        <span className="text-xs font-semibold text-zinc-200">{ag.name}</span>
                      </div>
                      <span
                        className={`text-[9px] px-1.5 py-0.5 rounded-full font-mono ${
                          isActive
                            ? 'bg-emerald-500/20 text-emerald-300 border border-emerald-500/30'
                            : ag.status === 'monitoring'
                            ? 'bg-cyan-500/20 text-cyan-300 border border-cyan-500/30'
                            : 'bg-zinc-800 text-zinc-400'
                        }`}
                      >
                        {isActive ? 'ATIVO' : ag.status === 'monitoring' ? 'MONITORANDO' : 'OCIOSO'}
                      </span>
                    </div>
                    <p className="text-[11px] text-zinc-500 line-clamp-1 pl-8">{ag.tone}</p>
                    <div className="flex items-center gap-2 mt-2 text-[10px] text-zinc-400 pl-8">
                      <span className="flex items-center gap-1">
                        <Volume2 size={10} className="text-indigo-400" />
                        {ag.voice}
                      </span>
                      <span>•</span>
                      <span>{ag.language}</span>
                      <span>•</span>
                      <span>{ag.tools?.length || 2} ferramentas</span>
                    </div>
                  </button>
                );
              })}
            </div>
          </div>

          {/* Right Column: Agent Full Detail & Editor */}
          <div className="flex-1 p-6 overflow-y-auto space-y-6">
            {current && (
              <>
                {/* Agent Header & Action buttons */}
                <div className="flex items-center justify-between pb-4 border-b border-zinc-800">
                  <div className="flex items-center gap-3">
                    <div className="w-10 h-10 rounded-xl bg-indigo-500/10 border border-indigo-500/20 flex items-center justify-center shadow-md">
                      {renderIconBadge(current.icon)}
                    </div>
                    <div>
                      <div className="flex items-center gap-2">
                        <h3 className="text-base font-semibold text-white">{current.name}</h3>
                        <span className="text-[10px] px-2 py-0.5 rounded-full bg-zinc-800 text-zinc-400 font-mono">
                          Status: {current.status || 'Ativo'}
                        </span>
                      </div>
                      <p className="text-xs text-zinc-400">{current.tone}</p>
                    </div>
                  </div>

                  <div className="flex items-center gap-2">
                    {activeAgent?.id !== current.id && (
                      <button
                        onClick={handleApplyActive}
                        className="flex items-center gap-1.5 px-3.5 py-1.5 rounded-xl bg-emerald-600 hover:bg-emerald-500 text-white text-xs font-semibold cursor-pointer transition-colors shadow-sm"
                      >
                        <Check size={14} />
                        <span>Definir como Agente Ativo</span>
                      </button>
                    )}
                    <button
                      onClick={() => setIsEditing(!isEditing)}
                      className="px-3.5 py-1.5 rounded-xl bg-zinc-800 hover:bg-zinc-700 text-zinc-200 text-xs font-medium cursor-pointer transition-colors"
                    >
                      {isEditing ? 'Cancelar Edição' : 'Editar Atributos 4.5'}
                    </button>
                  </div>
                </div>

                {/* Form Editor View */}
                {isEditing ? (
                  <div className="space-y-4 p-5 rounded-xl bg-zinc-950/60 border border-zinc-800">
                    <div className="grid grid-cols-2 gap-4">
                      {/* Name */}
                      <div>
                        <label className="text-xs text-zinc-300 font-medium block mb-1">1. Nome do Agente</label>
                        <input
                          type="text"
                          value={formState.name}
                          onChange={(e) => setFormState({ ...formState, name: e.target.value })}
                          className="w-full px-3 py-2 bg-zinc-900 border border-zinc-800 rounded-lg text-xs text-zinc-200"
                        />
                      </div>

                      {/* Icon Selector */}
                      <div>
                        <label className="text-xs text-zinc-300 font-medium block mb-1">Ícone Temático</label>
                        <div className="flex gap-1.5 flex-wrap">
                          {AVAILABLE_ICONS.map((ic) => (
                            <button
                              key={ic.id}
                              type="button"
                              onClick={() => setFormState({ ...formState, icon: ic.id })}
                              className={`p-1.5 rounded-lg border flex items-center gap-1 text-[11px] cursor-pointer ${
                                formState.icon === ic.id
                                  ? 'bg-indigo-600/30 border-indigo-500 text-white'
                                  : 'bg-zinc-900 border-zinc-800 text-zinc-400 hover:text-white'
                              }`}
                            >
                              {ic.icon}
                              <span>{ic.label}</span>
                            </button>
                          ))}
                        </div>
                      </div>
                    </div>

                    <div className="grid grid-cols-3 gap-4">
                      {/* Tone & Personality */}
                      <div>
                        <label className="text-xs text-zinc-300 font-medium block mb-1">2. Personalidade e Tom</label>
                        <input
                          type="text"
                          value={formState.tone}
                          onChange={(e) => setFormState({ ...formState, tone: e.target.value })}
                          className="w-full px-3 py-2 bg-zinc-900 border border-zinc-800 rounded-lg text-xs text-zinc-200"
                        />
                      </div>

                      {/* Voice & Language */}
                      <div>
                        <label className="text-xs text-zinc-300 font-medium block mb-1">3. Voz e Idioma</label>
                        <div className="flex gap-2">
                          <select
                            value={formState.voice}
                            onChange={(e) => setFormState({ ...formState, voice: e.target.value as any })}
                            className="flex-1 px-2 py-2 bg-zinc-900 border border-zinc-800 rounded-lg text-xs text-zinc-200"
                          >
                            <option value="alloy">Alloy</option>
                            <option value="echo">Echo</option>
                            <option value="shimmer">Shimmer</option>
                            <option value="ash">Ash</option>
                            <option value="sage">Sage</option>
                            <option value="coral">Coral</option>
                            <option value="Puck">Puck (Gemini)</option>
                            <option value="Kore">Kore (Gemini)</option>
                          </select>
                          <select
                            value={formState.language}
                            onChange={(e) => setFormState({ ...formState, language: e.target.value })}
                            className="w-24 px-2 py-2 bg-zinc-900 border border-zinc-800 rounded-lg text-xs text-zinc-200"
                          >
                            <option value="pt-BR">pt-BR</option>
                            <option value="en-US">en-US</option>
                            <option value="es-ES">es-ES</option>
                          </select>
                        </div>
                      </div>

                      {/* Status */}
                      <div>
                        <label className="text-xs text-zinc-300 font-medium block mb-1">4. Status de Operação</label>
                        <select
                          value={formState.status || 'active'}
                          onChange={(e) => setFormState({ ...formState, status: e.target.value as any })}
                          className="w-full px-3 py-2 bg-zinc-900 border border-zinc-800 rounded-lg text-xs text-zinc-200"
                        >
                          <option value="active">🟢 Ativo (Interação por Voz)</option>
                          <option value="monitoring">🔵 Monitorando (Ouvindo em Segundo Plano)</option>
                          <option value="idle">⚪ Ocioso</option>
                        </select>
                      </div>
                    </div>

                    {/* System Prompt */}
                    <div>
                      <label className="text-xs text-zinc-300 font-medium block mb-1">
                        5. Instrução Principal (System Prompt)
                      </label>
                      <textarea
                        rows={3}
                        value={formState.system_prompt}
                        onChange={(e) => setFormState({ ...formState, system_prompt: e.target.value })}
                        className="w-full px-3 py-2 bg-zinc-900 border border-zinc-800 rounded-lg text-xs text-zinc-200 font-mono"
                      />
                    </div>

                    {/* Tools Selection for this agent */}
                    <div>
                      <label className="text-xs text-zinc-300 font-medium block mb-2">
                        6. Ferramentas Habilitadas Apenas para Ele
                      </label>
                      <div className="grid grid-cols-2 gap-2">
                        {AVAILABLE_TOOLS.map((t) => {
                          const isChecked = formState.tools?.includes(t.id);
                          return (
                            <label
                              key={t.id}
                              className={`flex items-center gap-2 p-2.5 rounded-lg border cursor-pointer transition-colors ${
                                isChecked
                                  ? 'bg-indigo-950/30 border-indigo-500/40 text-white'
                                  : 'bg-zinc-900/60 border-zinc-800 text-zinc-400'
                              }`}
                            >
                              <input
                                type="checkbox"
                                checked={isChecked}
                                onChange={() => handleToggleTool(t.id)}
                                className="rounded text-indigo-500"
                              />
                              {t.icon}
                              <span className="text-xs">{t.name}</span>
                            </label>
                          );
                        })}
                      </div>
                    </div>

                    <div className="flex justify-end gap-2 pt-2">
                      <button
                        onClick={handleSaveCurrent}
                        className="px-5 py-2 bg-indigo-600 hover:bg-indigo-500 text-white rounded-lg text-xs font-semibold cursor-pointer shadow-md"
                      >
                        Salvar Configuração do Agente
                      </button>
                    </div>
                  </div>
                ) : (
                  /* Read View */
                  <div className="space-y-3">
                    <div className="p-3.5 rounded-xl bg-zinc-950/60 border border-zinc-800/80 text-xs text-zinc-300 font-mono leading-relaxed whitespace-pre-wrap">
                      <span className="text-zinc-500 block mb-1 font-sans text-[11px] font-semibold">
                        Instruções Principais (System Prompt):
                      </span>
                      {current.system_prompt}
                    </div>

                    {/* Tools enabled list */}
                    <div className="p-3 rounded-xl bg-zinc-950/40 border border-zinc-800 flex items-center gap-3">
                      <span className="text-xs font-semibold text-zinc-400">Ferramentas Habilitadas:</span>
                      <div className="flex gap-2">
                        {(current.tools || ['webhook', 'ocr']).map((t) => (
                          <span
                            key={t}
                            className="text-[10px] px-2 py-0.5 rounded-full bg-indigo-500/10 text-indigo-300 border border-indigo-500/20 font-mono uppercase"
                          >
                            {t}
                          </span>
                        ))}
                      </div>
                    </div>
                  </div>
                )}

                {/* Persistent Isolated Memories Section (SQLite) */}
                <div className="space-y-3 pt-2">
                  <div className="flex items-center justify-between">
                    <div className="flex items-center gap-1.5 text-xs font-semibold text-zinc-300">
                      <Bookmark size={13} className="text-indigo-400" />
                      <span>7. Memória Própria & Isolada em SQLite ({memories.length} fatos guardados)</span>
                    </div>
                    <span className="text-[10px] text-zinc-500 font-mono">
                      Isolada exclusivamente para este agente
                    </span>
                  </div>

                  {/* Add memory form */}
                  <form onSubmit={handleAddMemorySubmit} className="flex gap-2">
                    <input
                      type="text"
                      placeholder="Adicionar fato, preferência ou detalhe aprendido especificamente por este agente..."
                      value={newMemoryText}
                      onChange={(e) => setNewMemoryText(e.target.value)}
                      className="flex-1 px-3 py-2 bg-zinc-950 border border-zinc-800 rounded-xl text-xs text-zinc-200 placeholder-zinc-600 focus:outline-none focus:border-indigo-500"
                    />
                    <select
                      value={newMemoryCat}
                      onChange={(e) => setNewMemoryCat(e.target.value as any)}
                      className="px-3 py-2 bg-zinc-950 border border-zinc-800 rounded-xl text-xs text-zinc-400"
                    >
                      <option value="preference">Preferência</option>
                      <option value="fact">Fato</option>
                      <option value="project">Projeto</option>
                    </select>
                    <button
                      type="submit"
                      className="px-4 py-2 bg-zinc-800 hover:bg-zinc-700 text-white text-xs font-semibold rounded-xl cursor-pointer"
                    >
                      Gravar na Memória
                    </button>
                  </form>

                  {/* Memories List */}
                  <div className="space-y-2 max-h-44 overflow-y-auto pr-1">
                    {memories.length === 0 ? (
                      <div className="text-center py-4 text-zinc-500 text-xs">
                        Nenhuma memória salva para este agente. Fatos e preferências aprendidos durante conversas serão gravados aqui.
                      </div>
                    ) : (
                      memories.map((mem) => (
                        <div
                          key={mem.id}
                          className="group flex items-center justify-between p-2.5 rounded-xl bg-zinc-950/40 border border-zinc-800 text-xs hover:border-zinc-700"
                        >
                          <div className="flex items-center gap-2">
                            <span className="text-[10px] px-1.5 py-0.5 rounded bg-zinc-800 text-zinc-400 font-mono">
                              {mem.category}
                            </span>
                            <span className="text-zinc-300">{mem.content}</span>
                          </div>
                          <button
                            onClick={() => onDeleteMemory(mem.id)}
                            className="opacity-0 group-hover:opacity-100 text-zinc-500 hover:text-red-400 p-1 cursor-pointer transition-opacity"
                            title="Remover memória"
                          >
                            <Trash2 size={12} />
                          </button>
                        </div>
                      ))
                    )}
                  </div>
                </div>
              </>
            )}
          </div>
        </div>
      </div>
    </div>
  );
};
