import React, { useState } from 'react';
import {
  X,
  Brain,
  Network,
  Sparkles,
  Clock,
  ArrowRight,
  TrendingUp,
  FolderPlus,
  Compass,
  Check,
  Search,
  Share2,
  Calendar,
  Layers,
  Lightbulb,
} from 'lucide-react';
import {
  KnowledgeNode,
  KnowledgeEdge,
  BrainConnectionInsight,
  SuggestedProject,
} from '../../types';

interface SecondBrainModalProps {
  isOpen: boolean;
  onClose: () => void;
}

export const SecondBrainModal: React.FC<SecondBrainModalProps> = ({
  isOpen,
  onClose,
}) => {
  const [activeTab, setActiveTab] = useState<'insights' | 'projects' | 'graph'>('insights');
  const [searchQuery, setSearchQuery] = useState('');
  const [createdProjectIds, setCreatedProjectIds] = useState<string[]>([]);

  // 1. Time-Travelling Autonomous Connections
  const connections: BrainConnectionInsight[] = [
    {
      id: 'conn-1',
      currentIdea: 'Entrega Faseada do Produto (MVP em 20 dias + Módulos em 40 dias)',
      pastConnection: 'Gargalo e Dúvida sobre Prazo de Homologação na Logix Tech',
      pastDate: 'Há 3 meses (14 Julho 2026)',
      explanation:
        'A estrutura em 2 fases que você propôs hoje resolve exatamente a dor de homologação lenta que travou o fechamento da Logix Tech 3 meses atrás.',
      relevancePercent: 96,
    },
    {
      id: 'conn-2',
      currentIdea: 'Arquitetura 100% Local com Whisper + SQLite Local (Zero Nuvem)',
      pastConnection: 'Objeção de Sigilo Profissional da Dra. Camila Duarte',
      pastDate: 'Há 1 mês (08 Setembro 2026)',
      explanation:
        'Esta anotação técnica atende ponto a ponto ao requisito de conformidade jurídica que ela exigiu para fechar o contrato anual de R$ 36.000.',
      relevancePercent: 92,
    },
    {
      id: 'conn-3',
      currentIdea: 'Gatilho por voz: "Se citar concorrente, abrir comparativo"',
      pastConnection: 'Perda de Deal no Q2 por hesitação nas features comparativas',
      pastDate: 'Há 4 meses (02 Junho 2026)',
      explanation:
        'O playbook anterior registrou perda de oportunidade por falta de dados rápidos. O IFTTT de voz automatiza a resposta em menos de 1 segundo.',
      relevancePercent: 88,
    },
  ];

  // 2. Emerging Suggested Projects based on Speech & Screen Research
  const suggestedProjects: SuggestedProject[] = [
    {
      id: 'proj-1',
      title: 'Pipeline Autônomo de Onboarding via Webhook & MCP',
      description:
        'Você falou sobre “automação de fechamento”, “notificar CRM” e “contrato no Drive” 18 vezes nos últimos 20 dias.',
      triggerTopics: ['Webhooks', 'Disparo SMTP', 'Automação CRM', 'Contratos'],
      frequencyScore: 'Frequência Muito Alta (Top 1)',
      suggestedActionPlan: [
        'Conectar endpoint webhook com CRM da empresa',
        'Configurar template da minuta de contrato com preenchimento por IA',
        'Habilitar confirmação em 1 clique no encerramento de calls',
      ],
    },
    {
      id: 'proj-2',
      title: 'Edição Especial para Advocacia & Saúde (Soberania LGPD)',
      description:
        'Termos como “sigilo médico”, “LGPD”, “advogados” e “modo offline” apareceram em 9 pesquisas e 5 reuniões.',
      triggerTopics: ['Whisper Local', 'Ollama Local', 'LGPD', 'Sigilo Jurídico'],
      frequencyScore: 'Frequência Alta (Top 2)',
      suggestedActionPlan: [
        'Criar instalador com Whisper pré-carregado no setup',
        'Validar conformidade técnica com laudo de soberania de dados',
        'Adicionar playbook de contorno focado em sigilo',
      ],
    },
    {
      id: 'proj-3',
      title: 'Repositório de Inteligência Competitiva (Playbooks Rápidos)',
      description:
        'Você pesquisou sobre comparativos de concorrentes e objeções de preço 14 vezes nas últimas duas semanas.',
      triggerTopics: ['Playbook Comercial', 'Tabela de Preços', 'Concorrentes'],
      frequencyScore: 'Frequência Média-Alta (Top 3)',
      suggestedActionPlan: [
        'Subir PDFs atualizados no RAG Local',
        'Configurar regra IFTTT para cada concorrente citado',
      ],
    },
  ];

  // 3. Knowledge Graph Nodes
  const nodes: KnowledgeNode[] = [
    { id: 'n-1', label: 'Entrega Faseada (MVP 20d)', type: 'idea', source: 'conversa', date: 'Hoje', mentionsCount: 7 },
    { id: 'n-2', label: 'Gargalo de Homologação', type: 'problem', source: 'conversa', date: 'Há 3 meses', mentionsCount: 5 },
    { id: 'n-3', label: 'Roberto Almeida (Logix)', type: 'person', source: 'conversa', date: 'Há 12 dias', mentionsCount: 14 },
    { id: 'n-4', label: 'Soberania Local LGPD', type: 'insight', source: 'anotacao', date: 'Ontem', mentionsCount: 11 },
    { id: 'n-5', label: 'Dra. Camila Duarte', type: 'person', source: 'conversa', date: 'Ontem', mentionsCount: 8 },
    { id: 'n-6', label: 'Whisper Local + Ollama', type: 'idea', source: 'tela_ocr', date: 'Hoje', mentionsCount: 16 },
    { id: 'n-7', label: 'Pipeline de Webhooks CRM', type: 'project', source: 'conversa', date: 'Esta semana', mentionsCount: 18 },
  ];

  if (!isOpen) return null;

  const handleCreateProject = (id: string) => {
    setCreatedProjectIds([...createdProjectIds, id]);
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/85 backdrop-blur-md p-4 animate-in fade-in duration-150">
      <div className="w-full max-w-4xl bg-zinc-900 border border-zinc-800 rounded-3xl shadow-2xl overflow-hidden flex flex-col max-h-[88vh]">
        {/* Header */}
        <div className="flex items-center justify-between px-6 py-4 border-b border-zinc-800 bg-zinc-900/80">
          <div className="flex items-center gap-2.5">
            <div className="w-9 h-9 rounded-xl bg-violet-500/10 border border-violet-500/25 flex items-center justify-center text-violet-400 shadow-sm">
              <Brain size={18} />
            </div>
            <div>
              <div className="flex items-center gap-2">
                <h2 className="text-sm font-semibold text-white">
                  Segundo Cérebro Autônomo & Grafo de Conhecimento
                </h2>
                <span className="text-[10px] px-2 py-0.5 rounded-full bg-violet-500/20 text-violet-300 font-mono font-semibold">
                  Conexões Ocultas Ativas
                </span>
              </div>
              <p className="text-[11px] text-zinc-400">
                Toda conversa, janela de tela e anotação vira um grafo conectado que identifica insights temporais
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

        {/* Tab Selection */}
        <div className="flex border-b border-zinc-800 bg-zinc-950/40 px-6 gap-3">
          <button
            onClick={() => setActiveTab('insights')}
            className={`py-3 text-xs font-medium border-b-2 transition-all cursor-pointer flex items-center gap-1.5 ${
              activeTab === 'insights'
                ? 'border-violet-500 text-white font-semibold'
                : 'border-transparent text-zinc-400 hover:text-zinc-200'
            }`}
          >
            <Sparkles size={13} className={activeTab === 'insights' ? 'text-violet-400' : ''} />
            <span>Conexões no Tempo ({connections.length})</span>
          </button>
          <button
            onClick={() => setActiveTab('projects')}
            className={`py-3 text-xs font-medium border-b-2 transition-all cursor-pointer flex items-center gap-1.5 ${
              activeTab === 'projects'
                ? 'border-violet-500 text-white font-semibold'
                : 'border-transparent text-zinc-400 hover:text-zinc-200'
            }`}
          >
            <TrendingUp size={13} className={activeTab === 'projects' ? 'text-violet-400' : ''} />
            <span>Projetos Sugeridos por Fala & Pesquisa</span>
          </button>
          <button
            onClick={() => setActiveTab('graph')}
            className={`py-3 text-xs font-medium border-b-2 transition-all cursor-pointer flex items-center gap-1.5 ${
              activeTab === 'graph'
                ? 'border-violet-500 text-white font-semibold'
                : 'border-transparent text-zinc-400 hover:text-zinc-200'
            }`}
          >
            <Network size={13} className={activeTab === 'graph' ? 'text-violet-400' : ''} />
            <span>Mapa do Grafo ({nodes.length} Nós)</span>
          </button>
        </div>

        {/* Tab Content */}
        <div className="p-6 space-y-4 overflow-y-auto flex-1">
          {/* Tab 1: Insights & Cross-time Connections */}
          {activeTab === 'insights' && (
            <div className="space-y-3">
              <div className="p-3 rounded-xl bg-violet-950/20 border border-violet-500/25 flex items-start gap-2.5 text-xs text-violet-200">
                <Sparkles size={16} className="text-violet-400 shrink-0 mt-0.5" />
                <div>
                  <strong className="block text-violet-300 font-semibold mb-0.5">
                    Como a IA conecta suas ideias sozinho:
                  </strong>
                  <span>
                    O Copilot cruza o que você acabou de falar ou ler na tela com dúvidas, notas e conversas de semanas ou meses atrás, descobrindo soluções que estavam esquecidas na sua memória.
                  </span>
                </div>
              </div>

              <div className="space-y-3 pt-1">
                {connections.map((c) => (
                  <div
                    key={c.id}
                    className="p-4 rounded-2xl bg-zinc-950/60 border border-zinc-800 hover:border-violet-500/40 transition-all space-y-2.5"
                  >
                    <div className="flex items-center justify-between">
                      <div className="flex items-center gap-2">
                        <span className="text-[10px] px-2 py-0.5 rounded-full bg-violet-500/20 text-violet-300 font-mono font-semibold">
                          {c.relevancePercent}% Correlação Semântica
                        </span>
                        <span className="text-[11px] text-zinc-500 flex items-center gap-1">
                          <Clock size={11} />
                          <span>{c.pastDate}</span>
                        </span>
                      </div>
                    </div>

                    <div className="grid grid-cols-1 md:grid-cols-2 gap-2 text-xs">
                      <div className="p-2.5 rounded-xl bg-zinc-900 border border-zinc-800/80">
                        <span className="text-[10px] text-zinc-500 uppercase font-semibold block mb-1">
                          💡 Ideia que você teve Hoje:
                        </span>
                        <p className="text-zinc-200 font-medium leading-relaxed">{c.currentIdea}</p>
                      </div>

                      <div className="p-2.5 rounded-xl bg-zinc-900/50 border border-zinc-800/60">
                        <span className="text-[10px] text-amber-400 uppercase font-semibold block mb-1">
                          ⏱️ Conexão de {c.pastDate}:
                        </span>
                        <p className="text-zinc-300 leading-relaxed">{c.pastConnection}</p>
                      </div>
                    </div>

                    <p className="text-[11px] text-violet-200/90 bg-violet-950/15 p-2.5 rounded-xl border border-violet-500/20 leading-relaxed font-sans">
                      ✨ <strong className="text-violet-300">Conexão da IA:</strong> {c.explanation}
                    </p>
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* Tab 2: Projects Suggested based on Topic Frequency */}
          {activeTab === 'projects' && (
            <div className="space-y-3">
              <div className="text-xs text-zinc-400">
                A IA analisou os tópicos mais recorrentes nas suas reuniões de áudio, pesquisas e anotações dos últimos 30 dias:
              </div>

              <div className="space-y-3">
                {suggestedProjects.map((p) => {
                  const isCreated = createdProjectIds.includes(p.id);
                  return (
                    <div
                      key={p.id}
                      className="p-4 rounded-2xl bg-zinc-950/60 border border-zinc-800 space-y-3"
                    >
                      <div className="flex items-start justify-between gap-3">
                        <div>
                          <div className="flex items-center gap-2">
                            <h4 className="text-xs font-bold text-white">{p.title}</h4>
                            <span className="text-[10px] px-2 py-0.5 rounded-full bg-emerald-500/15 text-emerald-300 font-mono">
                              {p.frequencyScore}
                            </span>
                          </div>
                          <p className="text-xs text-zinc-300 leading-relaxed mt-1">
                            {p.description}
                          </p>
                        </div>

                        <button
                          onClick={() => handleCreateProject(p.id)}
                          className={`flex items-center gap-1.5 px-3 py-1.5 rounded-xl text-xs font-semibold cursor-pointer transition-colors shrink-0 ${
                            isCreated
                              ? 'bg-emerald-500/20 text-emerald-300 border border-emerald-500/40'
                              : 'bg-indigo-600 hover:bg-indigo-500 text-white shadow-sm'
                          }`}
                        >
                          {isCreated ? <Check size={13} /> : <FolderPlus size={13} />}
                          <span>{isCreated ? 'Projeto Criado!' : 'Criar Este Projeto'}</span>
                        </button>
                      </div>

                      {/* Trigger Topics */}
                      <div className="flex items-center gap-1.5 flex-wrap">
                        <span className="text-[10px] text-zinc-500 font-mono">Tópicos falados:</span>
                        {p.triggerTopics.map((topic, i) => (
                          <span
                            key={i}
                            className="text-[10px] px-2 py-0.5 rounded-md bg-zinc-900 border border-zinc-800 text-zinc-300 font-mono"
                          >
                            #{topic}
                          </span>
                        ))}
                      </div>

                      {/* Suggested Action Plan */}
                      <div className="p-3 rounded-xl bg-zinc-900/60 border border-zinc-800/80 space-y-1">
                        <span className="text-[10px] font-semibold text-zinc-400 uppercase tracking-wider block">
                          Plano de Ação Sugerido:
                        </span>
                        {p.suggestedActionPlan.map((step, idx) => (
                          <div key={idx} className="flex items-center gap-2 text-xs text-zinc-300">
                            <span className="w-4 h-4 rounded-full bg-zinc-800 text-[10px] font-mono flex items-center justify-center text-indigo-400 shrink-0">
                              {idx + 1}
                            </span>
                            <span>{step}</span>
                          </div>
                        ))}
                      </div>
                    </div>
                  );
                })}
              </div>
            </div>
          )}

          {/* Tab 3: Knowledge Graph Map */}
          {activeTab === 'graph' && (
            <div className="space-y-3">
              <div className="flex items-center justify-between text-xs text-zinc-400">
                <span>Nós detectados automaticamente a partir de reuniões e OCR:</span>
                <span className="text-[10px] font-mono text-zinc-500">
                  Total: {nodes.length} nós • 14 relações
                </span>
              </div>

              {/* Cluster Badges */}
              <div className="grid grid-cols-2 md:grid-cols-3 gap-2.5">
                {nodes.map((node) => (
                  <div
                    key={node.id}
                    className="p-3 rounded-xl bg-zinc-950/70 border border-zinc-800 hover:border-violet-500/50 transition-colors space-y-1"
                  >
                    <div className="flex items-center justify-between text-[10px]">
                      <span
                        className={`px-1.5 py-0.5 rounded font-mono uppercase font-semibold ${
                          node.type === 'idea'
                            ? 'bg-indigo-500/20 text-indigo-300'
                            : node.type === 'problem'
                            ? 'bg-amber-500/20 text-amber-300'
                            : node.type === 'person'
                            ? 'bg-emerald-500/20 text-emerald-300'
                            : node.type === 'project'
                            ? 'bg-cyan-500/20 text-cyan-300'
                            : 'bg-violet-500/20 text-violet-300'
                        }`}
                      >
                        {node.type}
                      </span>
                      <span className="text-zinc-500 font-mono">{node.date}</span>
                    </div>

                    <div className="text-xs font-semibold text-white pt-0.5">{node.label}</div>

                    <div className="flex items-center justify-between text-[10px] text-zinc-500 font-mono pt-1 border-t border-zinc-800/40">
                      <span>Origem: {node.source}</span>
                      <span>{node.mentionsCount} menções</span>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="flex items-center justify-between px-6 py-4 border-t border-zinc-800 bg-zinc-900/80">
          <div className="text-xs text-zinc-400 flex items-center gap-1.5">
            <Brain size={14} className="text-violet-400" />
            <span>Grafo persistente armazenado localmente em SQLite (Zero vazamento)</span>
          </div>
          <button
            onClick={onClose}
            className="px-5 py-2 rounded-xl bg-zinc-800 hover:bg-zinc-700 text-white text-xs font-semibold cursor-pointer transition-colors"
          >
            Fechar
          </button>
        </div>
      </div>
    </div>
  );
};
