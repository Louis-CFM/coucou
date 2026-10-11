import React, { useState, useEffect, useRef } from 'react';
import {
  X,
  Network,
  Share2,
  Download,
  Copy,
  Plus,
  Play,
  Pause,
  Sparkles,
  CheckCircle2,
  User,
  Lightbulb,
  Layers,
  GitBranch,
  RefreshCw,
  ExternalLink,
  Check,
  Radio,
  FileCode,
} from 'lucide-react';
import { MindMapNode, MindMapNodeType, MindMapSession } from '../../types';

interface LiveMindMapModalProps {
  isOpen: boolean;
  onClose: () => void;
}

const INITIAL_SESSIONS: Record<string, MindMapSession> = {
  planejamento: {
    id: 'session-plan-1',
    title: 'Planejamento Estratégico & Lançamento Copilot Q1',
    mode: 'planejamento',
    createdAt: 'Há 12 minutos',
    isLiveRecording: true,
    summary: 'Mapeamento das frentes técnicas, pricing e go-to-market acordados na conversa.',
    nodes: [
      {
        id: 'root',
        label: '🚀 Lançamento Coucou Copilot 2027',
        type: 'central',
        color: '#6366f1',
      },
      // Ramo 1: Arquitetura & Soberania
      {
        id: 't-1',
        label: 'Soberania de Dados & LGPD',
        type: 'theme',
        parentId: 'root',
        color: '#8b5cf6',
      },
      {
        id: 'sub-1',
        label: 'Armazenamento 100% Local (SQLite)',
        type: 'subtopic',
        parentId: 't-1',
        notes: 'Sem tráfego de transcrições em servidores externos',
      },
      {
        id: 'dec-1',
        label: 'Decisão: Banco local criptografado em repouso',
        type: 'decision',
        parentId: 'sub-1',
        timestamp: '10:04',
      },
      {
        id: 'own-1',
        label: 'Criar migração e schema de cifragem AES-256',
        type: 'task_owner',
        parentId: 'dec-1',
        owner: 'Lucas Rocha (Tech Lead)',
        timestamp: '10:05',
      },
      // Ramo 2: Modelo Comercial
      {
        id: 't-2',
        label: 'Modelo Comercial & Preço',
        type: 'theme',
        parentId: 'root',
        color: '#ec4899',
      },
      {
        id: 'sub-2',
        label: 'Proposta de Implantação Faseada',
        type: 'subtopic',
        parentId: 't-2',
        notes: 'Fase 1 (MVP em 20 dias) + Fase 2 (Módulos avançados em 40 dias)',
      },
      {
        id: 'dec-2',
        label: 'Decisão: Fechar em R$ 24.000 anual com pagamento semestral',
        type: 'decision',
        parentId: 'sub-2',
        timestamp: '10:14',
      },
      {
        id: 'own-2',
        label: 'Emitir proposta formal revisada e minuta até amanhã',
        type: 'task_owner',
        parentId: 'dec-2',
        owner: 'Mariana Silva (Comercial)',
        timestamp: '10:15',
      },
      // Ramo 3: Experiência do Usuário (Jarvis & Voz)
      {
        id: 't-3',
        label: 'Controle por Voz do PC (Jarvis)',
        type: 'theme',
        parentId: 'root',
        color: '#10b981',
      },
      {
        id: 'sub-3',
        label: 'Human-in-the-Loop para Ações Sensíveis',
        type: 'subtopic',
        parentId: 't-3',
        notes: 'Confirmação obrigatória antes de disparar e-mail ou excluir arquivos',
      },
      {
        id: 'dec-3',
        label: 'Decisão: Modal de confirmação com atalho Alt+J e log de auditoria',
        type: 'decision',
        parentId: 'sub-3',
        timestamp: '10:22',
      },
      {
        id: 'own-3',
        label: 'Validar testes de ponta a ponta com atalho no Windows 11',
        type: 'task_owner',
        parentId: 'dec-3',
        owner: 'André Costa (QA)',
        timestamp: '10:23',
      },
    ],
  },
  brainstorming: {
    id: 'session-brain-1',
    title: 'Brainstorming: Novas Linhas de Receita & IA Proativa',
    mode: 'brainstorming',
    createdAt: 'Ontem às 16:30',
    isLiveRecording: false,
    summary: 'Levantamento de hipóteses de monetização B2B e diferenciais frente aos concorrentes.',
    nodes: [
      { id: 'root', label: '💡 Monetização & IA Proativa', type: 'central', color: '#f59e0b' },
      { id: 't-1', label: 'Planos Corporativos', type: 'theme', parentId: 'root' },
      { id: 'sub-1', label: 'Cobrança por assento com RAG ilimitado', type: 'subtopic', parentId: 't-1' },
      { id: 'dec-1', label: 'Decisão: Criar tier Enterprise com SLA de 99.9%', type: 'decision', parentId: 'sub-1' },
      { id: 'own-1', label: 'Montar precificação por volume', type: 'task_owner', parentId: 'dec-1', owner: 'Mariana Silva' },
      { id: 't-2', label: 'Marketplace de Agentes Especializados', type: 'theme', parentId: 'root' },
      { id: 'sub-2', label: 'Agentes prontos de Direito, Medicina e Vendas', type: 'subtopic', parentId: 't-2' },
      { id: 'dec-2', label: 'Decisão: Repasse de 70/30 para criadores de prompts', type: 'decision', parentId: 'sub-2' },
      { id: 'own-2', label: 'Estruturar programa de criadores pioneiros', type: 'task_owner', parentId: 'dec-2', owner: 'Felipe Sales' },
    ],
  },
  aula: {
    id: 'session-class-1',
    title: 'Aula: Arquiteturas Modernas de Inteligência Artificial e Agentes',
    mode: 'aula',
    createdAt: 'Há 45 minutos',
    isLiveRecording: false,
    summary: 'Estruturação didática dos conceitos fundamentais de LLMs, agentes reativos e grafos de conhecimento.',
    nodes: [
      { id: 'root', label: '🎓 Arquitetura de Agentes de IA', type: 'central', color: '#06b6d4' },
      { id: 't-1', label: 'Modelos Fundacionais (LLMs)', type: 'theme', parentId: 'root' },
      { id: 'sub-1', label: 'Context Window & Attention Mechanism', type: 'subtopic', parentId: 't-1' },
      { id: 'dec-1', label: 'Conceito Chave: KV Caching e RAG Semântico', type: 'decision', parentId: 'sub-1' },
      { id: 't-2', label: 'Tool Calling & Protocolo MCP', type: 'theme', parentId: 'root' },
      { id: 'sub-2', label: 'Comunicação padronizada com sistemas externos', type: 'subtopic', parentId: 't-2' },
      { id: 'own-1', label: 'Exercício prático: criar servidor MCP de clima', type: 'task_owner', parentId: 'sub-2', owner: 'Todos os Alunos' },
    ],
  },
};

const SIMULATED_STREAM_PHRASES = [
  {
    speech: '“Também precisamos garantir integração com o Trello para que as tarefas caiam direto no board do time de produto.”',
    node: {
      id: `live-${Date.now()}-1`,
      label: 'Integração Automática com Trello via Webhook',
      type: 'subtopic' as MindMapNodeType,
      parentId: 't-3',
      notes: 'Disparar cards automáticos após o término da reunião',
      isNew: true,
    },
  },
  {
    speech: '“Ficou decidido que o Pedro fica como responsável por homologar o webhook do Trello até quarta-feira.”',
    node: {
      id: `live-${Date.now()}-2`,
      label: 'Decisão: Homologar webhook do Trello até quarta',
      type: 'decision' as MindMapNodeType,
      parentId: `live-${Date.now()}-1`,
      timestamp: 'Agora',
      isNew: true,
    },
    ownerNode: {
      id: `live-${Date.now()}-3`,
      label: 'Subir rota de webhook e testar payloads',
      type: 'task_owner' as MindMapNodeType,
      parentId: `live-${Date.now()}-2`,
      owner: 'Pedro Santos (DevOps)',
      timestamp: 'Agora',
      isNew: true,
    },
  },
  {
    speech: '“Outro ponto importante levantado foi criar um alerta sonoro discreto quando o mapa mental capturar uma nova decisão.”',
    node: {
      id: `live-${Date.now()}-4`,
      label: 'Feedback Háptico/Sonoro de Captura de Decisão',
      type: 'insight' as MindMapNodeType,
      parentId: 't-1',
      notes: 'Sinal sonoro de 0.2s para avisar que a decisão foi ramificada',
      isNew: true,
    },
  },
];

export const LiveMindMapModal: React.FC<LiveMindMapModalProps> = ({
  isOpen,
  onClose,
}) => {
  const [selectedMode, setSelectedMode] = useState<'planejamento' | 'brainstorming' | 'aula'>('planejamento');
  const [session, setSession] = useState<MindMapSession>(INITIAL_SESSIONS.planejamento);
  const [isLiveListening, setIsLiveListening] = useState(true);
  const [lastSpeechDetected, setLastSpeechDetected] = useState<string>(
    '“...e fechamos então a entrega em duas fases com pagamento semestral de 24 mil...”'
  );
  const [copiedMermaid, setCopiedMermaid] = useState(false);
  const [copiedLink, setCopiedLink] = useState(false);
  const [showExportMenu, setShowExportMenu] = useState(false);
  const [simStep, setSimStep] = useState(0);

  // Switch session when mode changes
  const handleModeChange = (mode: 'planejamento' | 'brainstorming' | 'aula') => {
    setSelectedMode(mode);
    setSession(INITIAL_SESSIONS[mode]);
  };

  // Simulate incoming live voice recognition branching
  const handleSimulateVoice = () => {
    const item = SIMULATED_STREAM_PHRASES[simStep % SIMULATED_STREAM_PHRASES.length];
    setLastSpeechDetected(item.speech);

    setSession((prev) => {
      const newNodes = [...prev.nodes, item.node];
      if (item.ownerNode) {
        newNodes.push(item.ownerNode);
      }
      return {
        ...prev,
        nodes: newNodes,
      };
    });

    setSimStep((prev) => prev + 1);
  };

  // Generate Mermaid diagram string
  const generateMermaid = (): string => {
    let diagram = 'graph LR\n';
    const rootNode = session.nodes.find((n) => n.type === 'central') || session.nodes[0];
    if (rootNode) {
      diagram += `  ${rootNode.id}["${rootNode.label}"]\n`;
    }

    session.nodes.forEach((node) => {
      if (node.parentId) {
        let label = node.label.replace(/"/g, "'");
        if (node.owner) {
          label += ` (👤 ${node.owner})`;
        }
        diagram += `  ${node.parentId} --> ${node.id}["${label}"]\n`;
      }
    });
    return diagram;
  };

  const handleCopyMermaid = () => {
    const code = generateMermaid();
    navigator.clipboard.writeText(code);
    setCopiedMermaid(true);
    setTimeout(() => setCopiedMermaid(false), 2000);
  };

  const handleCopyShareLink = () => {
    navigator.clipboard.writeText(`https://coucou.app/share/mindmap/${session.id}`);
    setCopiedLink(true);
    setTimeout(() => setCopiedLink(false), 2000);
  };

  const handleExportMarkdown = () => {
    const content = `# ${session.title}\n**Modo:** ${session.mode} | **Data:** ${session.createdAt}\n\n${session.summary}\n\n## Diagrama Mermaid\n\`\`\`mermaid\n${generateMermaid()}\`\`\`\n\n## Decisões & Responsáveis Mapeados\n${session.nodes
      .filter((n) => n.type === 'decision' || n.type === 'task_owner')
      .map((n) => `- **${n.label}** ${n.owner ? `(Responsável: ${n.owner})` : ''}`)
      .join('\n')}`;

    const blob = new Blob([content], { type: 'text/markdown' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `Mapa_Mental_${session.mode}_${Date.now()}.md`;
    a.click();
    URL.revokeObjectURL(url);
  };

  if (!isOpen) return null;

  // Filter root and top-level branches
  const rootNode = session.nodes.find((n) => n.type === 'central');
  const themeNodes = session.nodes.filter((n) => n.type === 'theme');
  const decisions = session.nodes.filter((n) => n.type === 'decision');
  const owners = session.nodes.filter((n) => n.type === 'task_owner');

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/80 backdrop-blur-md p-4 animate-in fade-in duration-150">
      <div className="bg-[#101014] border border-zinc-800 rounded-3xl w-full max-w-6xl h-[90vh] flex flex-col shadow-2xl overflow-hidden font-sans text-zinc-100">
        {/* Top Header */}
        <div className="flex items-center justify-between px-6 py-4 border-b border-zinc-800/80 bg-zinc-950/60 shrink-0">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 rounded-2xl bg-gradient-to-tr from-violet-600 via-indigo-600 to-cyan-500 flex items-center justify-center shadow-lg shadow-indigo-500/25">
              <Network size={20} className="text-white animate-pulse" />
            </div>
            <div>
              <div className="flex items-center gap-2.5">
                <h2 className="text-base font-bold text-white tracking-tight">
                  Mapa Mental ao Vivo
                </h2>
                <span className="flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-[11px] font-semibold bg-emerald-500/10 text-emerald-400 border border-emerald-500/30">
                  <span className="w-2 h-2 rounded-full bg-emerald-400 animate-ping" />
                  Auto-Montagem Ativa
                </span>
              </div>
              <p className="text-xs text-zinc-400">
                Diagrama gerado em tempo real por escuta contínua com temas, decisões, ramificações e responsáveis
              </p>
            </div>
          </div>

          {/* Mode Switcher Tabs */}
          <div className="flex items-center bg-zinc-900 border border-zinc-800 p-1 rounded-2xl">
            <button
              onClick={() => handleModeChange('planejamento')}
              className={`px-3 py-1.5 rounded-xl text-xs font-semibold transition-all cursor-pointer ${
                selectedMode === 'planejamento'
                  ? 'bg-indigo-600 text-white shadow-sm'
                  : 'text-zinc-400 hover:text-white'
              }`}
            >
              🎯 Planejamento
            </button>
            <button
              onClick={() => handleModeChange('brainstorming')}
              className={`px-3 py-1.5 rounded-xl text-xs font-semibold transition-all cursor-pointer ${
                selectedMode === 'brainstorming'
                  ? 'bg-amber-600 text-white shadow-sm'
                  : 'text-zinc-400 hover:text-white'
              }`}
            >
              💡 Brainstorming
            </button>
            <button
              onClick={() => handleModeChange('aula')}
              className={`px-3 py-1.5 rounded-xl text-xs font-semibold transition-all cursor-pointer ${
                selectedMode === 'aula'
                  ? 'bg-cyan-600 text-white shadow-sm'
                  : 'text-zinc-400 hover:text-white'
              }`}
            >
              🎓 Aula / Palestra
            </button>
          </div>

          {/* Header Action Buttons */}
          <div className="flex items-center gap-2">
            <button
              onClick={handleSimulateVoice}
              title="Simular fala do participante adicionando um novo ramo automaticamente"
              className="flex items-center gap-1.5 px-3 py-1.5 rounded-xl bg-violet-600/20 hover:bg-violet-600/30 text-violet-300 border border-violet-500/30 text-xs font-semibold transition-all cursor-pointer"
            >
              <Sparkles size={14} className="text-violet-400" />
              <span>Simular Fala (+Ramo)</span>
            </button>

            <button
              onClick={() => setIsLiveListening((prev) => !prev)}
              className={`flex items-center gap-1.5 px-3 py-1.5 rounded-xl text-xs font-semibold border transition-all cursor-pointer ${
                isLiveListening
                  ? 'bg-emerald-500/10 text-emerald-300 border-emerald-500/30'
                  : 'bg-zinc-800 text-zinc-400 border-zinc-700'
              }`}
            >
              {isLiveListening ? <Pause size={13} /> : <Play size={13} />}
              <span>{isLiveListening ? 'Ouvindo ao Vivo' : 'Pausado'}</span>
            </button>

            {/* Share & Export Dropdown */}
            <div className="relative">
              <button
                onClick={() => setShowExportMenu((prev) => !prev)}
                className="flex items-center gap-1.5 px-3.5 py-1.5 rounded-xl bg-zinc-900 hover:bg-zinc-800 text-zinc-200 border border-zinc-700 text-xs font-semibold transition-all cursor-pointer shadow-sm"
              >
                <Share2 size={14} className="text-indigo-400" />
                <span>Compartilhar</span>
              </button>

              {showExportMenu && (
                <div className="absolute right-0 mt-2 w-56 rounded-2xl bg-zinc-900 border border-zinc-700 p-2 shadow-2xl z-50 flex flex-col gap-1 text-xs">
                  <button
                    onClick={() => {
                      handleCopyMermaid();
                      setShowExportMenu(false);
                    }}
                    className="flex items-center gap-2 px-3 py-2 rounded-xl hover:bg-zinc-800 text-zinc-300 hover:text-white transition-all text-left cursor-pointer"
                  >
                    <FileCode size={14} className="text-indigo-400" />
                    <span>Copiar Mermaid Diagram</span>
                  </button>
                  <button
                    onClick={() => {
                      handleCopyShareLink();
                      setShowExportMenu(false);
                    }}
                    className="flex items-center gap-2 px-3 py-2 rounded-xl hover:bg-zinc-800 text-zinc-300 hover:text-white transition-all text-left cursor-pointer"
                  >
                    <ExternalLink size={14} className="text-cyan-400" />
                    <span>Copiar Link Interativo</span>
                  </button>
                  <button
                    onClick={() => {
                      handleExportMarkdown();
                      setShowExportMenu(false);
                    }}
                    className="flex items-center gap-2 px-3 py-2 rounded-xl hover:bg-zinc-800 text-zinc-300 hover:text-white transition-all text-left cursor-pointer"
                  >
                    <Download size={14} className="text-emerald-400" />
                    <span>Baixar Markdown (.md)</span>
                  </button>
                </div>
              )}
            </div>

            <button
              onClick={onClose}
              className="p-2 rounded-xl bg-zinc-900 hover:bg-zinc-800 text-zinc-400 hover:text-white border border-zinc-800 transition-all cursor-pointer"
            >
              <X size={16} />
            </button>
          </div>
        </div>

        {/* Live Audio Ingestion Bar */}
        <div className="flex items-center justify-between px-6 py-2.5 bg-zinc-900/60 border-b border-zinc-800/80 text-xs shrink-0">
          <div className="flex items-center gap-2.5">
            <Radio size={14} className="text-emerald-400 animate-pulse" />
            <span className="font-semibold text-zinc-400">Última fala capturada:</span>
            <span className="text-zinc-200 italic font-mono bg-zinc-950/80 px-2.5 py-1 rounded-lg border border-zinc-800/80 truncate max-w-2xl">
              {lastSpeechDetected}
            </span>
          </div>

          <div className="flex items-center gap-3 text-zinc-400">
            <span className="flex items-center gap-1">
              <Layers size={13} className="text-indigo-400" />
              <strong className="text-zinc-200">{session.nodes.length}</strong> nós conectados
            </span>
            <span className="flex items-center gap-1">
              <CheckCircle2 size={13} className="text-emerald-400" />
              <strong className="text-zinc-200">{decisions.length}</strong> decisões
            </span>
            <span className="flex items-center gap-1">
              <User size={13} className="text-amber-400" />
              <strong className="text-zinc-200">{owners.length}</strong> responsáveis
            </span>
          </div>
        </div>

        {/* Main Body: Canvas + Side Insights */}
        <div className="flex-1 flex overflow-hidden">
          {/* Visual Mind Map Canvas */}
          <div className="flex-1 bg-[#0b0b0e] relative overflow-y-auto p-8 flex flex-col justify-center items-center">
            {/* Background grid pattern */}
            <div
              className="absolute inset-0 opacity-15 pointer-events-none"
              style={{
                backgroundImage: `radial-gradient(#6366f1 1px, transparent 1px)`,
                backgroundSize: '24px 24px',
              }}
            />

            {/* Mind Map Tree Layout */}
            <div className="relative z-10 w-full max-w-4xl flex flex-col items-center gap-8 py-6">
              {/* Central Root Node */}
              {rootNode && (
                <div className="relative group">
                  <div className="px-6 py-3.5 rounded-2xl bg-gradient-to-r from-indigo-600 via-indigo-500 to-violet-600 text-white font-bold text-base shadow-xl shadow-indigo-600/30 border border-indigo-400/30 flex items-center gap-2.5">
                    <Network size={18} />
                    <span>{rootNode.label}</span>
                  </div>
                  <div className="w-0.5 h-8 bg-gradient-to-b from-indigo-500 to-zinc-700 mx-auto" />
                </div>
              )}

              {/* Themes Branches (Horizontal Grid) */}
              <div className="w-full grid grid-cols-1 md:grid-cols-3 gap-6">
                {themeNodes.map((theme) => {
                  const subtopics = session.nodes.filter((n) => n.parentId === theme.id);

                  return (
                    <div
                      key={theme.id}
                      className="flex flex-col gap-3 p-4 rounded-2xl bg-zinc-900/80 border border-zinc-800 shadow-lg backdrop-blur-sm transition-all hover:border-zinc-700 hover:shadow-indigo-500/5"
                    >
                      {/* Theme Header Pill */}
                      <div className="flex items-center justify-between pb-2 border-b border-zinc-800">
                        <div className="flex items-center gap-2">
                          <GitBranch size={15} className="text-indigo-400" />
                          <h4 className="font-bold text-xs text-white tracking-wide">
                            {theme.label}
                          </h4>
                        </div>
                        <span className="text-[10px] font-mono text-zinc-500">Tema</span>
                      </div>

                      {/* Subtopics & Decisions & Owners */}
                      <div className="flex flex-col gap-2.5">
                        {subtopics.map((sub) => {
                          const childDecisions = session.nodes.filter(
                            (n) => n.parentId === sub.id && n.type === 'decision'
                          );
                          const childInsights = session.nodes.filter(
                            (n) => n.parentId === sub.id && n.type === 'insight'
                          );

                          return (
                            <div
                              key={sub.id}
                              className={`p-3 rounded-xl bg-zinc-950/70 border transition-all ${
                                sub.isNew
                                  ? 'border-indigo-500/80 shadow-md shadow-indigo-500/20 animate-pulse'
                                  : 'border-zinc-800/80'
                              }`}
                            >
                              <div className="text-xs font-medium text-zinc-200">
                                {sub.label}
                              </div>
                              {sub.notes && (
                                <p className="text-[11px] text-zinc-400 mt-1 leading-relaxed">
                                  {sub.notes}
                                </p>
                              )}

                              {/* Child Insights if any */}
                              {childInsights.map((ins) => (
                                <div
                                  key={ins.id}
                                  className="mt-2 p-2 rounded-lg bg-cyan-950/30 border border-cyan-800/40 text-[11px] text-cyan-200 flex items-start gap-1.5"
                                >
                                  <Lightbulb size={13} className="text-cyan-400 shrink-0 mt-0.5" />
                                  <span>{ins.label}</span>
                                </div>
                              ))}

                              {/* Child Decisions */}
                              {childDecisions.map((dec) => {
                                const childOwners = session.nodes.filter(
                                  (n) => n.parentId === dec.id && n.type === 'task_owner'
                                );

                                return (
                                  <div
                                    key={dec.id}
                                    className="mt-2.5 pt-2 border-t border-zinc-800/80 flex flex-col gap-1.5"
                                  >
                                    <div className="flex items-start gap-1.5 text-[11px] text-emerald-300 font-semibold bg-emerald-950/30 p-2 rounded-lg border border-emerald-800/40">
                                      <CheckCircle2 size={13} className="text-emerald-400 shrink-0 mt-0.5" />
                                      <span>{dec.label}</span>
                                    </div>

                                    {/* Task Owners attached to this decision */}
                                    {childOwners.map((own) => (
                                      <div
                                        key={own.id}
                                        className="flex items-center justify-between p-2 rounded-lg bg-amber-950/20 border border-amber-800/30 text-[11px] text-amber-200"
                                      >
                                        <div className="flex items-center gap-1.5">
                                          <User size={12} className="text-amber-400 shrink-0" />
                                          <span className="font-semibold text-amber-300">
                                            {own.owner}:
                                          </span>
                                          <span className="truncate max-w-[130px]">{own.label}</span>
                                        </div>
                                        {own.timestamp && (
                                          <span className="text-[9px] font-mono text-zinc-500">
                                            {own.timestamp}
                                          </span>
                                        )}
                                      </div>
                                    ))}
                                  </div>
                                );
                              })}
                            </div>
                          );
                        })}
                      </div>
                    </div>
                  );
                })}
              </div>
            </div>
          </div>

          {/* Right Sidebar: Structured Breakdown */}
          <div className="w-80 bg-zinc-950/90 border-l border-zinc-800 p-5 flex flex-col gap-5 overflow-y-auto shrink-0">
            {/* Box 1: Decisões Acordadas */}
            <div>
              <div className="flex items-center justify-between mb-2.5">
                <div className="flex items-center gap-2">
                  <CheckCircle2 size={15} className="text-emerald-400" />
                  <h3 className="text-xs font-bold text-white uppercase tracking-wider">
                    Decisões ({decisions.length})
                  </h3>
                </div>
                <span className="text-[10px] bg-emerald-500/10 text-emerald-400 px-2 py-0.5 rounded-full font-mono">
                  Registradas
                </span>
              </div>
              <div className="flex flex-col gap-2">
                {decisions.map((dec) => (
                  <div
                    key={dec.id}
                    className="p-2.5 rounded-xl bg-zinc-900 border border-zinc-800/80 text-xs text-zinc-300 leading-relaxed"
                  >
                    <div className="text-emerald-300 font-semibold mb-1">
                      {dec.label}
                    </div>
                    {dec.timestamp && (
                      <span className="text-[10px] text-zinc-500 font-mono">
                        Definido aos {dec.timestamp} de reunião
                      </span>
                    )}
                  </div>
                ))}
              </div>
            </div>

            {/* Box 2: Responsáveis & Ações Atribuídas */}
            <div>
              <div className="flex items-center justify-between mb-2.5">
                <div className="flex items-center gap-2">
                  <User size={15} className="text-amber-400" />
                  <h3 className="text-xs font-bold text-white uppercase tracking-wider">
                    Responsáveis ({owners.length})
                  </h3>
                </div>
                <span className="text-[10px] bg-amber-500/10 text-amber-400 px-2 py-0.5 rounded-full font-mono">
                  Atribuídos
                </span>
              </div>
              <div className="flex flex-col gap-2">
                {owners.map((own) => (
                  <div
                    key={own.id}
                    className="p-2.5 rounded-xl bg-zinc-900 border border-zinc-800/80 text-xs"
                  >
                    <div className="font-bold text-amber-300 mb-0.5">
                      👤 {own.owner}
                    </div>
                    <p className="text-zinc-300 text-[11px] leading-relaxed">
                      {own.label}
                    </p>
                  </div>
                ))}
              </div>
            </div>

            {/* Quick Share Banner */}
            <div className="mt-auto p-3.5 rounded-2xl bg-gradient-to-br from-indigo-950/40 to-violet-950/40 border border-indigo-500/30 flex flex-col gap-2.5">
              <div className="flex items-center gap-2 text-indigo-300 font-semibold text-xs">
                <Share2 size={14} />
                <span>Pronto para Compartilhar</span>
              </div>
              <p className="text-[11px] text-zinc-400 leading-relaxed">
                Ao final da call, o mapa pode ser compartilhado como link público, Markdown ou inserido no Notion e Slack da equipe.
              </p>
              <button
                onClick={handleCopyShareLink}
                className="w-full py-2 px-3 rounded-xl bg-indigo-600 hover:bg-indigo-500 text-white font-semibold text-xs flex items-center justify-center gap-1.5 transition-all cursor-pointer shadow-md shadow-indigo-600/30"
              >
                {copiedLink ? <Check size={14} /> : <Copy size={14} />}
                <span>{copiedLink ? 'Link Copiado!' : 'Copiar Link do Mapa'}</span>
              </button>
            </div>
          </div>
        </div>

        {/* Footer notification */}
        <div className="px-6 py-3 bg-zinc-950 border-t border-zinc-800/80 flex items-center justify-between text-xs text-zinc-400 shrink-0">
          <div className="flex items-center gap-2">
            <Sparkles size={13} className="text-indigo-400" />
            <span>
              O mapa atualiza sozinho conforme novas ideias, objeções e tarefas surgem na fala.
            </span>
          </div>

          <div className="flex items-center gap-3">
            <button
              onClick={handleCopyMermaid}
              className="text-zinc-400 hover:text-white transition-colors cursor-pointer text-xs flex items-center gap-1"
            >
              {copiedMermaid ? <Check size={12} className="text-emerald-400" /> : <FileCode size={12} />}
              <span>{copiedMermaid ? 'Mermaid Copiado!' : 'Copiar Mermaid'}</span>
            </button>
            <span className="text-zinc-700">•</span>
            <button
              onClick={handleExportMarkdown}
              className="text-zinc-400 hover:text-white transition-colors cursor-pointer text-xs flex items-center gap-1"
            >
              <Download size={12} />
              <span>Baixar (.md)</span>
            </button>
          </div>
        </div>
      </div>
    </div>
  );
};
