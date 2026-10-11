import React, { useState } from 'react';
import {
  Lightbulb,
  AlertTriangle,
  CheckSquare,
  Eye,
  RefreshCw,
  UserCheck,
  BookOpen,
  Gauge,
  Activity,
  Search,
  Sparkles,
  ArrowRight,
  TrendingUp,
  VolumeX,
} from 'lucide-react';
import {
  OcrResult,
  WhisperCoachTip,
  ContactProfile,
  EmotionPacingMetrics,
  KnowledgeDoc,
} from '../../types';

interface InsightsPanelProps {
  screenContext: OcrResult | null;
  onRefreshScreen: () => void;
  isScanningScreen: boolean;
  onOpenWrapUp?: () => void;
}

export const InsightsPanel: React.FC<InsightsPanelProps> = ({
  screenContext,
  onRefreshScreen,
  isScanningScreen,
  onOpenWrapUp,
}) => {
  const [activeTab, setActiveTab] = useState<'coach' | 'crm' | 'rag'>('coach');
  const [ragQuery, setRagQuery] = useState('');
  const [selectedSentiment, setSelectedSentiment] = useState<'hesitante' | 'inseguro' | 'entusiasmado' | 'fechamento_favoravel'>('hesitante');
  const [userTalkRatio, setUserTalkRatio] = useState(68);
  const [newNote, setNewNote] = useState('');
  const [showAddDocModal, setShowAddDocModal] = useState(false);
  const [newDocTitle, setNewDocTitle] = useState('');
  const [newDocCategory, setNewDocCategory] = useState<'playbook' | 'precos' | 'faq' | 'contrato'>('playbook');
  const [newDocSnippet, setNewDocSnippet] = useState('');

  // 1. Proactive Whisper Coach Tips
  const [whisperTips, setWhisperTips] = useState<WhisperCoachTip[]>([
    {
      id: 'tip-1',
      type: 'objection',
      message: 'O participante hesitou no prazo de 60 dias. Sugira a entrega em 2 fases (MVP em 20 dias).',
      timestamp: '10:14',
      priority: 'high',
    },
    {
      id: 'tip-2',
      type: 'pacing',
      message: 'Atenção ao ritmo: você falou 75% dos últimos 8 minutos. Faça uma pergunta aberta ao cliente.',
      timestamp: '10:18',
      priority: 'normal',
    },
    {
      id: 'tip-3',
      type: 'sentiment',
      message: 'Interlocutor demonstrou interesse alto no módulo de segurança LGPD. Reforce este ponto agora.',
      timestamp: '10:21',
      priority: 'high',
    },
  ]);

  // 2. Contacts List (Mini-CRM)
  const [contacts, setContacts] = useState<ContactProfile[]>([
    {
      id: 'c-1',
      name: 'Roberto Almeida',
      company: 'Logix Tech Soluções',
      role: 'Diretor de Operações e TI',
      past_preferences: [
        'Prefere reuniões de no máximo 30 minutos',
        'Exige soberania de dados local (LGPD)',
        'Gosta de comparativos em tabelas visuais',
      ],
      past_objections: [
        'Da última vez pediu desconto de 15% e pagamento semestral',
        'Preocupação com suporte fora do horário comercial',
      ],
      last_agreements: [
        'Ficou acordado o envio da proposta com escopo em duas etapas',
      ],
      deal_value: 'R$ 24.000 / ano',
      last_seen: 'Há 12 dias',
    },
    {
      id: 'c-2',
      name: 'Dra. Camila Duarte',
      company: 'Duarte & Associados Advocacia',
      role: 'Sócia Fundadora',
      past_preferences: [
        'Requisito absoluto de privacidade offline (sigilo profissional)',
        'Ata precisa citar números de processos e partes envolvidas',
      ],
      past_objections: [
        'Hesitou sobre latência em transcrições longas',
      ],
      last_agreements: [
        'Fechado teste de piloto de 14 dias com modo offline Whisper local',
      ],
      deal_value: 'R$ 36.000 / ano',
      last_seen: 'Ontem',
    },
  ]);
  const [activeContactId, setActiveContactId] = useState('c-1');
  const activeContact = contacts.find((c) => c.id === activeContactId) || contacts[0];

  // 3. Local RAG Knowledge Base
  const [knowledgeBase, setKnowledgeBase] = useState<KnowledgeDoc[]>([
    {
      id: 'k-1',
      title: 'Tabela de Preços e Prazos Q4 2026',
      category: 'precos',
      snippet: 'Plano Enterprise: R$ 2.000/mês. Implantação completa em 30 dias com onboarding assistido.',
      source: 'Playbook Comercial v4.pdf (Pág 12)',
    },
    {
      id: 'k-2',
      title: 'Contorno de Objeção: "Prazo de Entrega"',
      category: 'playbook',
      snippet: 'Propor o modelo de entrega faseada com liberação da primeira versão de homologação em 15 dias.',
      source: 'Guia de Objeções 2026.docx',
    },
    {
      id: 'k-3',
      title: 'Conformidade e Segurança LGPD / Offline',
      category: 'contrato',
      snippet: 'Banco de dados armazenado 100% no dispositivo do usuário com SQLite local criptografado. Modo Offline não envia pacotes para servidores externos.',
      source: 'Termo de Privacidade e Dados.pdf (Pág 3)',
    },
  ]);

  const handleAddDocument = (e: React.FormEvent) => {
    e.preventDefault();
    if (!newDocTitle.trim() || !newDocSnippet.trim()) return;
    const newDoc: KnowledgeDoc = {
      id: `doc-${Date.now()}`,
      title: newDocTitle.trim(),
      category: newDocCategory,
      snippet: newDocSnippet.trim(),
      source: 'Upload Local Manual (RAG Index)',
    };
    setKnowledgeBase([newDoc, ...knowledgeBase]);
    setNewDocTitle('');
    setNewDocSnippet('');
    setShowAddDocModal(false);
  };

  const handleAddNoteToContact = () => {
    if (!newNote.trim()) return;
    setContacts(
      contacts.map((c) =>
        c.id === activeContactId
          ? { ...c, last_agreements: [newNote.trim(), ...c.last_agreements] }
          : c
      )
    );
    setNewNote('');
  };

  const filteredDocs = knowledgeBase.filter(
    (d) =>
      d.title.toLowerCase().includes(ragQuery.toLowerCase()) ||
      d.snippet.toLowerCase().includes(ragQuery.toLowerCase()) ||
      d.category.toLowerCase().includes(ragQuery.toLowerCase())
  );

  return (
    <div className="w-84 flex flex-col h-full bg-zinc-950/40 rounded-2xl border border-zinc-800/80 overflow-hidden backdrop-blur-sm">
      {/* Panel Header & Tabs */}
      <div className="border-b border-zinc-800/60 bg-zinc-900/30">
        <div className="flex items-center justify-between px-4 pt-3 pb-2">
          <div className="flex items-center gap-2">
            <Sparkles size={14} className="text-amber-400" />
            <span className="text-xs font-semibold text-zinc-200">Painel Inteligente</span>
          </div>
          {onOpenWrapUp && (
            <button
              onClick={onOpenWrapUp}
              className="text-[10px] px-2.5 py-1 rounded-full bg-emerald-500/20 text-emerald-300 border border-emerald-500/30 hover:bg-emerald-500/30 transition-colors cursor-pointer font-semibold flex items-center gap-1 shadow-sm"
            >
              <span>Encerrar & Ata</span>
              <span>📝</span>
            </button>
          )}
        </div>

        {/* Tab selection */}
        <div className="flex px-3 gap-2">
          <button
            onClick={() => setActiveTab('coach')}
            className={`flex items-center gap-1.5 py-2 px-2.5 text-[11px] font-medium border-b-2 transition-all cursor-pointer ${
              activeTab === 'coach'
                ? 'border-indigo-500 text-white font-semibold'
                : 'border-transparent text-zinc-400 hover:text-zinc-200'
            }`}
          >
            <Lightbulb size={12} className={activeTab === 'coach' ? 'text-indigo-400' : ''} />
            <span>Coach Sussurro</span>
          </button>

          <button
            onClick={() => setActiveTab('crm')}
            className={`flex items-center gap-1.5 py-2 px-2.5 text-[11px] font-medium border-b-2 transition-all cursor-pointer ${
              activeTab === 'crm'
                ? 'border-indigo-500 text-white font-semibold'
                : 'border-transparent text-zinc-400 hover:text-zinc-200'
            }`}
          >
            <UserCheck size={12} className={activeTab === 'crm' ? 'text-indigo-400' : ''} />
            <span>Mini-CRM</span>
          </button>

          <button
            onClick={() => setActiveTab('rag')}
            className={`flex items-center gap-1.5 py-2 px-2.5 text-[11px] font-medium border-b-2 transition-all cursor-pointer ${
              activeTab === 'rag'
                ? 'border-indigo-500 text-white font-semibold'
                : 'border-transparent text-zinc-400 hover:text-zinc-200'
            }`}
          >
            <BookOpen size={12} className={activeTab === 'rag' ? 'text-indigo-400' : ''} />
            <span>RAG Playbook</span>
          </button>
        </div>
      </div>

      <div className="flex-1 overflow-y-auto p-3.5 space-y-4">
        {activeTab === 'coach' && (
          <>
            {/* Emotion & Pacing Gauge Box */}
            <div className="p-3.5 rounded-xl bg-zinc-900/60 border border-zinc-800 space-y-2.5">
              <div className="flex items-center justify-between text-xs">
                <span className="font-semibold text-zinc-300 flex items-center gap-1.5">
                  <Activity size={13} className="text-emerald-400" />
                  <span>Proporção de Fala & Emoção</span>
                </span>
                <span
                  className={`text-[10px] px-2 py-0.5 rounded-full font-mono font-medium ${
                    selectedSentiment === 'hesitante'
                      ? 'bg-amber-500/20 text-amber-300 border border-amber-500/30'
                      : selectedSentiment === 'inseguro'
                      ? 'bg-rose-500/20 text-rose-300 border border-rose-500/30'
                      : 'bg-emerald-500/20 text-emerald-300 border border-emerald-500/30'
                  }`}
                >
                  Cliente: {selectedSentiment === 'hesitante' ? 'Hesitante no Preço' : selectedSentiment === 'inseguro' ? 'Inseguro' : 'Entusiasmado'}
                </span>
              </div>

              {/* Progress bar You vs Remote */}
              <div>
                <div className="w-full h-2.5 bg-cyan-950 rounded-full overflow-hidden flex shadow-inner">
                  <div
                    className="bg-gradient-to-r from-indigo-500 to-indigo-600 h-full transition-all duration-300"
                    style={{ width: `${userTalkRatio}%` }}
                    title={`Você falou ${userTalkRatio}%`}
                  />
                  <div
                    className="bg-gradient-to-r from-cyan-400 to-cyan-500 h-full transition-all duration-300"
                    style={{ width: `${100 - userTalkRatio}%` }}
                    title={`Cliente falou ${100 - userTalkRatio}%`}
                  />
                </div>
                <div className="flex justify-between items-center text-[10px] text-zinc-400 mt-1.5 font-mono">
                  <span className="text-indigo-300 font-semibold">Você: {userTalkRatio}%</span>
                  <span className="text-cyan-300 font-semibold">Cliente: {100 - userTalkRatio}%</span>
                </div>
              </div>

              {userTalkRatio > 70 && (
                <div className="p-2 rounded-lg bg-amber-950/30 border border-amber-500/30 text-[10px] text-amber-200 flex items-center gap-1.5">
                  <AlertTriangle size={12} className="text-amber-400 shrink-0" />
                  <span>Alerta: Você falou mais de 70% da reunião. Faça uma pergunta aberta e ouça o cliente!</span>
                </div>
              )}

              <div className="flex items-center justify-between text-[10px] text-zinc-500 pt-1.5 border-t border-zinc-800/60">
                <span>⚡ 135 ppm (Ritmo Ideal)</span>
                <span>🛑 2 interrupções</span>
                <button
                  onClick={() => setUserTalkRatio(userTalkRatio === 68 ? 45 : 68)}
                  className="text-[9px] text-indigo-400 hover:text-indigo-300 underline cursor-pointer"
                >
                  Simular alternância
                </button>
              </div>
            </div>

            {/* Whisper Coach Proactive Suggestions */}
            <div className="space-y-2">
              <div className="flex items-center justify-between text-xs font-semibold text-zinc-300">
                <span className="flex items-center gap-1.5">
                  <Lightbulb size={13} className="text-amber-400" />
                  <span>Modo Sussurro (Coach Proativo)</span>
                </span>
                <span className="text-[9px] px-1.5 py-0.5 rounded bg-indigo-500/10 text-indigo-300 font-mono border border-indigo-500/20">
                  TEMPO REAL
                </span>
              </div>

              <div className="space-y-2">
                {whisperTips.map((tip) => (
                  <div
                    key={tip.id}
                    className={`p-3 rounded-xl border text-xs space-y-1.5 transition-all shadow-sm ${
                      tip.priority === 'high'
                        ? 'bg-amber-950/25 border-amber-500/30 text-amber-100'
                        : 'bg-indigo-950/20 border-indigo-500/20 text-indigo-100'
                    }`}
                  >
                    <div className="flex justify-between items-center text-[10px]">
                      <span className="font-semibold uppercase tracking-wider text-amber-300 flex items-center gap-1">
                        <span>💡</span>
                        <span>{tip.type === 'objection' ? 'Contorno de Objeção' : tip.type === 'pacing' ? 'Ritmo da Conversa' : 'Oportunidade'}</span>
                      </span>
                      <span className="text-zinc-500 font-mono">{tip.timestamp}</span>
                    </div>
                    <p className="text-[11px] leading-relaxed text-zinc-200">{tip.message}</p>
                    <div className="flex justify-end gap-2 pt-1">
                      <button
                        onClick={() => navigator.clipboard.writeText(tip.message)}
                        className="text-[9px] px-2 py-0.5 rounded bg-zinc-800 hover:bg-zinc-700 text-zinc-300 transition-colors cursor-pointer flex items-center gap-1"
                      >
                        <span>Copiar dica</span>
                      </button>
                    </div>
                  </div>
                ))}
              </div>
            </div>

            {/* Screen Context Box */}
            <div className="p-3 rounded-xl bg-zinc-900/50 border border-zinc-800">
              <div className="flex items-center justify-between mb-2">
                <div className="flex items-center gap-1.5 text-xs font-semibold text-zinc-300">
                  <Eye size={13} className="text-cyan-400" />
                  <span>Visão de Tela Ativa (Alt+S)</span>
                </div>
                <button
                  onClick={onRefreshScreen}
                  disabled={isScanningScreen}
                  className="p-1 rounded-md text-zinc-400 hover:text-white hover:bg-zinc-800 transition-colors cursor-pointer"
                  title="Atualizar Leitura de Tela (Alt+S)"
                >
                  <RefreshCw size={12} className={isScanningScreen ? 'animate-spin text-indigo-400' : ''} />
                </button>
              </div>

              {screenContext ? (
                <div className="space-y-1.5">
                  <div className="text-[11px] font-mono text-cyan-300/80 truncate">
                    🪟 {screenContext.active_window || 'Janela do Windows'}
                  </div>
                  <div className="text-[11px] text-zinc-400 max-h-20 overflow-y-auto bg-zinc-950/60 p-2 rounded border border-zinc-800/40 font-mono leading-tight whitespace-pre-wrap">
                    {screenContext.extracted_text || 'Nenhum texto detectado'}
                  </div>
                </div>
              ) : (
                <div className="text-[11px] text-zinc-500 py-1">
                  Pressione <kbd className="px-1 py-0.5 bg-zinc-800 rounded text-zinc-400">Alt+S</kbd> para escanear a tela atual.
                </div>
              )}
            </div>
          </>
        )}

        {/* Mini-CRM Profile View */}
        {activeTab === 'crm' && (
          <div className="space-y-3.5">
            {/* Contact Selector */}
            <div className="flex items-center justify-between gap-2">
              <select
                value={activeContactId}
                onChange={(e) => setActiveContactId(e.target.value)}
                className="flex-1 px-2.5 py-1.5 bg-zinc-900 border border-zinc-800 rounded-xl text-xs text-white focus:outline-none focus:border-indigo-500 cursor-pointer"
              >
                {contacts.map((c) => (
                  <option key={c.id} value={c.id}>
                    👤 {c.name} ({c.company})
                  </option>
                ))}
              </select>
            </div>

            <div className="p-3.5 rounded-xl bg-zinc-900/70 border border-zinc-800 space-y-2">
              <div className="flex justify-between items-start">
                <div>
                  <h4 className="text-xs font-bold text-white">{activeContact.name}</h4>
                  <p className="text-[11px] text-zinc-400">{activeContact.role}</p>
                  <p className="text-[10px] text-indigo-400 font-medium">{activeContact.company}</p>
                </div>
                <div className="text-right">
                  <span className="text-[10px] px-2 py-0.5 rounded-full bg-emerald-500/20 text-emerald-300 font-mono block">
                    {activeContact.deal_value}
                  </span>
                  <span className="text-[9px] text-zinc-500 font-mono mt-1 block">
                    Última call: {activeContact.last_seen}
                  </span>
                </div>
              </div>
            </div>

            {/* Past Objections */}
            <div className="space-y-1.5">
              <span className="text-[11px] font-semibold text-rose-300 flex items-center gap-1">
                <AlertTriangle size={11} />
                <span>Objeções Anteriores (Histórico):</span>
              </span>
              {activeContact.past_objections.map((o, i) => (
                <div key={i} className="p-2.5 rounded-lg bg-rose-950/20 border border-rose-500/25 text-[11px] text-zinc-200">
                  ⚠️ {o}
                </div>
              ))}
            </div>

            {/* Past Preferences */}
            <div className="space-y-1.5">
              <span className="text-[11px] font-semibold text-indigo-300 flex items-center gap-1">
                <Lightbulb size={11} />
                <span>Preferências do Cliente:</span>
              </span>
              {activeContact.past_preferences.map((p, i) => (
                <div key={i} className="p-2 rounded-lg bg-zinc-900 border border-zinc-800 text-[11px] text-zinc-300">
                  💡 {p}
                </div>
              ))}
            </div>

            {/* Last Agreement & Notes */}
            <div className="space-y-1.5">
              <span className="text-[11px] font-semibold text-emerald-300 flex items-center gap-1">
                <CheckSquare size={11} />
                <span>Acordos & Próximos Passos:</span>
              </span>
              {activeContact.last_agreements.map((a, i) => (
                <div key={i} className="p-2 rounded-lg bg-emerald-950/20 border border-emerald-500/25 text-[11px] text-zinc-200">
                  ✅ {a}
                </div>
              ))}
            </div>

            {/* Add note to contact */}
            <div className="pt-2 border-t border-zinc-800/80 space-y-1.5">
              <span className="text-[10px] text-zinc-400 font-medium">Registrar Novo Acordo na Ficha:</span>
              <div className="flex gap-1.5">
                <input
                  type="text"
                  placeholder="Ex: Pediu 20 dias para validar internamente..."
                  value={newNote}
                  onChange={(e) => setNewNote(e.target.value)}
                  onKeyDown={(e) => e.key === 'Enter' && handleAddNoteToContact()}
                  className="flex-1 px-2.5 py-1 bg-zinc-950 border border-zinc-800 rounded-lg text-[11px] text-zinc-200 placeholder-zinc-600 focus:outline-none focus:border-indigo-500"
                />
                <button
                  onClick={handleAddNoteToContact}
                  className="px-2.5 py-1 bg-indigo-600 hover:bg-indigo-500 text-white rounded-lg text-[11px] font-semibold cursor-pointer transition-colors"
                >
                  Salvar
                </button>
              </div>
            </div>
          </div>
        )}

        {/* Local RAG Playbook Search View */}
        {activeTab === 'rag' && (
          <div className="space-y-3">
            <div className="flex items-center justify-between gap-2">
              <div className="relative flex-1">
                <Search size={13} className="absolute left-3 top-2.5 text-zinc-500" />
                <input
                  type="text"
                  placeholder="Buscar em playbooks, preços e FAQs..."
                  value={ragQuery}
                  onChange={(e) => setRagQuery(e.target.value)}
                  className="w-full pl-8 pr-3 py-1.5 bg-zinc-950 border border-zinc-800 rounded-xl text-xs text-zinc-200 placeholder-zinc-600 focus:outline-none focus:border-indigo-500"
                />
              </div>
              <button
                onClick={() => setShowAddDocModal(!showAddDocModal)}
                className="px-2.5 py-1.5 bg-indigo-600/20 hover:bg-indigo-600/30 text-indigo-300 border border-indigo-500/30 rounded-xl text-[11px] font-semibold cursor-pointer transition-colors shrink-0"
              >
                + Adicionar
              </button>
            </div>

            {showAddDocModal && (
              <form onSubmit={handleAddDocument} className="p-3 rounded-xl bg-zinc-900 border border-indigo-500/30 space-y-2">
                <span className="text-[11px] font-bold text-indigo-300 block">Indexar Novo Documento RAG</span>
                <input
                  type="text"
                  placeholder="Título (ex: Política de Descontos Q4)"
                  value={newDocTitle}
                  onChange={(e) => setNewDocTitle(e.target.value)}
                  className="w-full px-2.5 py-1 bg-zinc-950 border border-zinc-800 rounded-lg text-xs text-zinc-200 focus:outline-none focus:border-indigo-500"
                />
                <select
                  value={newDocCategory}
                  onChange={(e) => setNewDocCategory(e.target.value as any)}
                  className="w-full px-2.5 py-1 bg-zinc-950 border border-zinc-800 rounded-lg text-xs text-zinc-300 focus:outline-none"
                >
                  <option value="playbook">Playbook Comercial</option>
                  <option value="precos">Tabela de Preços</option>
                  <option value="faq">FAQ & Suporte</option>
                  <option value="contrato">Contrato & LGPD</option>
                </select>
                <textarea
                  rows={2}
                  placeholder="Conteúdo / Trecho do documento para consulta instantânea..."
                  value={newDocSnippet}
                  onChange={(e) => setNewDocSnippet(e.target.value)}
                  className="w-full px-2.5 py-1 bg-zinc-950 border border-zinc-800 rounded-lg text-xs text-zinc-200 focus:outline-none focus:border-indigo-500 font-sans"
                />
                <div className="flex justify-end gap-2">
                  <button
                    type="button"
                    onClick={() => setShowAddDocModal(false)}
                    className="px-2 py-0.5 text-zinc-400 text-[10px] cursor-pointer"
                  >
                    Cancelar
                  </button>
                  <button
                    type="submit"
                    className="px-3 py-1 bg-indigo-600 text-white rounded-lg text-[10px] font-semibold cursor-pointer"
                  >
                    Indexar Documento
                  </button>
                </div>
              </form>
            )}

            <div className="space-y-2">
              {filteredDocs.map((doc) => (
                <div
                  key={doc.id}
                  className="p-3 rounded-xl bg-zinc-900/60 border border-zinc-800 hover:border-indigo-500/40 transition-colors space-y-1.5"
                >
                  <div className="flex justify-between items-center text-xs">
                    <span className="font-semibold text-white">{doc.title}</span>
                    <span className="text-[9px] uppercase px-1.5 py-0.5 rounded bg-indigo-500/20 text-indigo-300 font-mono">
                      {doc.category}
                    </span>
                  </div>
                  <p className="text-[11px] text-zinc-300 leading-relaxed font-sans">{doc.snippet}</p>
                  <div className="text-[10px] text-zinc-500 font-mono pt-1 border-t border-zinc-800/40 flex items-center justify-between">
                    <span>📖 {doc.source}</span>
                    <span className="text-emerald-400">Resposta em 1.8s</span>
                  </div>
                </div>
              ))}
            </div>
          </div>
        )}
      </div>
    </div>
  );
};
