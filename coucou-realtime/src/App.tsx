import React, { useState, useEffect } from 'react';
import { useAgents } from './hooks/useAgents';
import { useAudioCapture } from './hooks/useAudioCapture';
import { useRealtimeClient } from './hooks/useRealtimeClient';
import { useScreenContext } from './hooks/useScreenContext';
import { ModeSelector } from './components/main/ModeSelector';
import { AgentBadge } from './components/main/AgentBadge';
import { AudioStreamView } from './components/main/AudioStreamView';
import { InsightsPanel } from './components/main/InsightsPanel';
import { SettingsModal } from './components/settings/SettingsModal';
import { AgentManagerModal } from './components/agents/AgentManagerModal';
import { ToolConfirmationModal } from './components/tools/ToolConfirmationModal';
import { SessionsDrawer } from './components/sessions/SessionsDrawer';
import { OnboardingModal } from './components/onboarding/OnboardingModal';
import { ScreenRecorderModal } from './components/main/ScreenRecorderModal';
import { MeetingRecorderTab } from './components/main/MeetingRecorderTab';
import { PostMeetingModal } from './components/main/PostMeetingModal';
import { AutomationsModal } from './components/automations/AutomationsModal';
import { SecondBrainModal } from './components/brain/SecondBrainModal';
import { WeeklyAudioBriefingModal } from './components/audio/WeeklyAudioBriefingModal';
import { JarvisCommanderModal } from './components/jarvis/JarvisCommanderModal';
import { LiveMindMapModal } from './components/mindmap/LiveMindMapModal';
import { ConversationToContentModal } from './components/content/ConversationToContentModal';
import { useScreenRecorder } from './hooks/useScreenRecorder';
import { AssistantMode, ToolConfirmationRequest, MeetingWrapUp, AutomationRule } from './types';
import {
  Mic,
  MicOff,
  Settings,
  History,
  Radio,
  Send,
  Sparkles,
  Wifi,
  WifiOff,
  Scan,
  Compass,
  Video,
  Zap,
  Brain,
  Headphones,
  Bot,
  Network,
  Wand2,
} from 'lucide-react';

export const App: React.FC = () => {
  const [currentMode, setCurrentMode] = useState<AssistantMode>('realtime');
  const [activeNavTab, setActiveNavTab] = useState<'copilot' | 'recorder'>('copilot');
  const [isSettingsOpen, setIsSettingsOpen] = useState(false);
  const [isAgentsOpen, setIsAgentsOpen] = useState(false);
  const [isSessionsOpen, setIsSessionsOpen] = useState(false);
  const [isOnboardingOpen, setIsOnboardingOpen] = useState(false);
  const [isAutomationsOpen, setIsAutomationsOpen] = useState(false);
  const [isBrainOpen, setIsBrainOpen] = useState(false);
  const [isBriefingOpen, setIsBriefingOpen] = useState(false);
  const [isJarvisOpen, setIsJarvisOpen] = useState(false);
  const [isMindMapOpen, setIsMindMapOpen] = useState(false);
  const [isContentOpen, setIsContentOpen] = useState(false);
  const [triggeredRuleAction, setTriggeredRuleAction] = useState<AutomationRule | null>(null);
  const [wrapUpData, setWrapUpData] = useState<MeetingWrapUp | null>(null);
  const [textInput, setTextInput] = useState('');
  const [activeWhisperAlert, setActiveWhisperAlert] = useState<{
    id: string;
    type: string;
    message: string;
    suggestedAction?: string;
  } | null>({
    id: 'w-1',
    type: 'hesitacao',
    message: 'O cliente hesitou no preço. Sugestão: pergunte sobre a meta de orçamento antes de conceder desconto.',
    suggestedAction: 'Qual margem de orçamento você tinha previsto para esta contratação?',
  });

  const handleOpenWrapUp = () => {
    setWrapUpData({
      id: `wrapup-${Date.now()}`,
      meetingTitle: 'Alinhamento Comercial & Implantação Q4',
      durationMinutes: 28,
      summaryExecutive: 'Reunião com Roberto Almeida (Logix Tech). Alinhado modelo de implantação em duas etapas para atender à meta do Q1. Cliente validou escopo técnico e solicitou envio formal da proposta revisada.',
      decisions: [
        'Aprovado modelo de entrega em 2 fases: Fase 1 (MVP em 20 dias) e Fase 2 (Módulos avançados em 40 dias)',
        'Acordo de precificação fixado em R$ 24.000 anual com pagamento semestral',
        'Soberania de dados confirmada com armazenamento local SQLite (conforme LGPD)',
      ],
      tasks: [
        {
          id: 't-1',
          title: 'Enviar proposta formal com tabela de preços atualizada',
          assignee: 'Você',
          deadline: 'Hoje até 18:00',
          completed: false,
        },
        {
          id: 't-2',
          title: 'Agendar call técnica de segurança da informação',
          assignee: 'Roberto (Cliente)',
          deadline: 'Quinta-feira, 14:30',
          completed: false,
        },
      ],
      followupEmail: {
        to: 'roberto.almeida@logixtech.com.br',
        subject: 'Ata de Alinhamento: Próximos Passos & Proposta Q4 — Coucou',
        body: `Olá Roberto,\n\nObrigado pelo tempo na reunião de hoje. Foi excelente alinhar os pontos para o projeto.\n\nConforme combinamos:\n• Implantação dividida em 2 fases (MVP em 20 dias e entrega final em 40 dias);\n• Armazenamento e processamento com conformidade total à LGPD;\n• Proposta formal em anexo com condições semestrais.\n\nFico no aguardo do seu retorno para formalizarmos o contrato.\n\nAtenciosamente,\nSua Equipe`,
      },
    });
  };

  const {
    agents,
    activeAgent,
    memories,
    selectAgent,
    saveAgent,
    removeAgent,
    addMemory,
    deleteMemory,
  } = useAgents();

  const {
    status: aiStatus,
    connectionState,
    userTranscript,
    agentTranscript,
    history,
    pendingConfirmation,
    setPendingConfirmation,
    connect,
    disconnect,
    sendAudioChunk,
    interrupt,
  } = useRealtimeClient(activeAgent);

  const {
    isCapturing,
    isMuted,
    audioLevel,
    isSpeakingVAD,
    startCapture,
    stopCapture,
    toggleMute,
  } = useAudioCapture((base64Chunk) => {
    sendAudioChunk(base64Chunk);
  }, currentMode);

  const { screenContext, isScanning, captureNow } = useScreenContext();

  const {
    isRecording,
    recordedTimeSec,
    lastRecording,
    startRecording,
    stopRecording,
    downloadRecording,
    clearLastRecording,
  } = useScreenRecorder();

  const isConnected = connectionState === 'connected';

  // Check onboarding on initial launch
  useEffect(() => {
    const done = localStorage.getItem('coucou_onboarding_completed');
    if (!done) {
      setIsOnboardingOpen(true);
    }
  }, []);

  // Toggle Live Voice Session
  const toggleSession = async () => {
    if (isConnected) {
      stopCapture();
      disconnect();
    } else {
      await startCapture();
      // Inject memories and screen context into realtime prompt
      const memorySnippet = memories
        .map((m) => `[${m.category.toUpperCase()}]: ${m.content}`)
        .join('\n');
      const fullContext = [memorySnippet, screenContext?.extracted_text]
        .filter(Boolean)
        .join('\n\n');
      await connect(fullContext);
    }
  };

  // Keyboard shortcut listener
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.altKey && (e.key === 'm' || e.key === 'M')) {
        e.preventDefault();
        toggleMute();
      }
      if (e.altKey && (e.key === 's' || e.key === 'S')) {
        e.preventDefault();
        captureNow();
      }
      if (e.altKey && (e.key === 'r' || e.key === 'R')) {
        e.preventDefault();
        if (isRecording) {
          stopRecording();
        } else {
          startRecording(true);
        }
      }
      if (e.altKey && (e.key === 'j' || e.key === 'J')) {
        e.preventDefault();
        setIsJarvisOpen((prev) => !prev);
      }
      if (e.altKey && (e.key === 'd' || e.key === 'D')) {
        e.preventDefault();
        setIsMindMapOpen((prev) => !prev);
      }
      if (e.altKey && (e.key === 'c' || e.key === 'C')) {
        e.preventDefault();
        setIsContentOpen((prev) => !prev);
      }
    };
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [toggleMute, captureNow, isRecording, startRecording, stopRecording]);

  const handleToolApprove = (req: ToolConfirmationRequest) => {
    console.log('Ferramenta aprovada pelo usuário:', req);
    setPendingConfirmation(null);
  };

  const handleToolReject = (req: ToolConfirmationRequest) => {
    console.log('Ferramenta rejeitada pelo usuário:', req);
    setPendingConfirmation(null);
  };

  const handleSendText = (e: React.FormEvent) => {
    e.preventDefault();
    if (!textInput.trim()) return;
    setTextInput('');
  };

  return (
    <div className="flex flex-col h-screen w-screen bg-[#09090b] text-zinc-100 overflow-hidden font-sans select-none">
      {/* Top Header Bar */}
      <header className="flex items-center justify-between px-5 py-3 border-b border-zinc-800/80 bg-zinc-950/60 backdrop-blur-md shrink-0">
        <div className="flex items-center gap-3">
          <div className="w-8 h-8 rounded-xl bg-gradient-to-tr from-indigo-600 via-indigo-500 to-violet-500 flex items-center justify-center shadow-lg shadow-indigo-500/25">
            <Sparkles size={16} className="text-white" />
          </div>
          <div>
            <div className="flex items-center gap-2">
              <h1 className="text-sm font-bold tracking-tight text-white">Coucou Copilot</h1>
              <span className="text-[10px] px-1.5 py-0.5 rounded-full bg-indigo-500/10 text-indigo-400 font-mono border border-indigo-500/20">
                Realtime v1.0
              </span>
            </div>
            <p className="text-[10px] text-zinc-500">Camada de Assistência Contínua & Inteligente</p>
          </div>
        </div>

        {/* Center: Navigation Tabs & Mode Selector */}
        <div className="flex items-center gap-3">
          <div className="flex items-center p-1 rounded-xl bg-zinc-900/90 border border-zinc-800">
            <button
              onClick={() => setActiveNavTab('copilot')}
              className={`flex items-center gap-2 px-3 py-1.5 rounded-lg text-xs font-semibold transition-all cursor-pointer ${
                activeNavTab === 'copilot'
                  ? 'bg-zinc-800 text-white shadow-sm border border-zinc-700/60'
                  : 'text-zinc-400 hover:text-zinc-200'
              }`}
            >
              <Radio size={13} className={activeNavTab === 'copilot' ? 'text-indigo-400' : ''} />
              <span>Copilot ao Vivo</span>
            </button>

            <button
              onClick={() => setActiveNavTab('recorder')}
              className={`flex items-center gap-2 px-3 py-1.5 rounded-lg text-xs font-semibold transition-all cursor-pointer ${
                activeNavTab === 'recorder'
                  ? 'bg-zinc-800 text-white shadow-sm border border-zinc-700/60'
                  : 'text-zinc-400 hover:text-zinc-200'
              }`}
            >
              <Video
                size={13}
                className={isRecording ? 'text-rose-400 animate-pulse' : activeNavTab === 'recorder' ? 'text-rose-400' : ''}
              />
              <span>Gravador & Reunião</span>
              {isRecording && (
                <span className="w-1.5 h-1.5 rounded-full bg-rose-500 animate-ping" />
              )}
            </button>
          </div>

          <ModeSelector currentMode={currentMode} onModeChange={setCurrentMode} />
        </div>

        {/* Right: Agent Badge & Quick Controls */}
        <div className="flex items-center gap-2.5">
          <AgentBadge agent={activeAgent} onClick={() => setIsAgentsOpen(true)} />

          <button
            onClick={() => {
              if (isRecording) {
                stopRecording();
              } else {
                startRecording(true);
                setActiveNavTab('recorder');
              }
            }}
            title={isRecording ? 'Parar Gravação (Alt+R)' : 'Gravar Tela & Reunião (Alt+R)'}
            className={`flex items-center gap-1.5 px-3 py-1.5 rounded-xl text-xs font-semibold border transition-all cursor-pointer ${
              isRecording
                ? 'bg-rose-500/20 text-rose-300 border-rose-500/50 animate-pulse shadow-sm shadow-rose-500/30'
                : 'bg-zinc-900 hover:bg-zinc-800 text-zinc-400 hover:text-rose-400 border-zinc-800'
            }`}
          >
            <Video size={14} className={isRecording ? 'text-rose-400' : ''} />
            <span>
              {isRecording
                ? `REC ${Math.floor(recordedTimeSec / 60).toString().padStart(2, '0')}:${(recordedTimeSec % 60).toString().padStart(2, '0')}`
                : 'Gravar Tela'}
            </span>
          </button>

          <button
            onClick={captureNow}
            disabled={isScanning}
            title="Escanear Janela Ativa (Alt+S)"
            className="p-2 rounded-xl bg-zinc-900 hover:bg-zinc-800 text-zinc-400 hover:text-cyan-300 border border-zinc-800 transition-all cursor-pointer"
          >
            <Scan size={15} className={isScanning ? 'animate-spin text-cyan-400' : ''} />
          </button>

          <button
            onClick={() => setIsAutomationsOpen(true)}
            title="Automações 'Se Isso, Então Aquilo' (Gatilhos de Voz & MCP)"
            className="flex items-center gap-1.5 px-3 py-1.5 rounded-xl bg-zinc-900 hover:bg-zinc-800 text-zinc-400 hover:text-amber-400 border border-zinc-800 transition-all cursor-pointer text-xs font-semibold"
          >
            <Zap size={14} className="text-amber-400" />
            <span>Automações</span>
          </button>

          <button
            onClick={() => setIsBrainOpen(true)}
            title="Segundo Cérebro Autônomo & Grafo de Conhecimento"
            className="flex items-center gap-1.5 px-3 py-1.5 rounded-xl bg-zinc-900 hover:bg-zinc-800 text-zinc-400 hover:text-violet-400 border border-zinc-800 transition-all cursor-pointer text-xs font-semibold"
          >
            <Brain size={14} className="text-violet-400" />
            <span>Segundo Cérebro</span>
          </button>

          <button
            onClick={() => setIsBriefingOpen(true)}
            title="Relatório Semanal de Você em Áudio (Podcast Pessoal de Sexta-feira)"
            className="flex items-center gap-1.5 px-3 py-1.5 rounded-xl bg-zinc-900 hover:bg-zinc-800 text-zinc-400 hover:text-amber-400 border border-zinc-800 transition-all cursor-pointer text-xs font-semibold"
          >
            <Headphones size={14} className="text-amber-400" />
            <span>Resumo Falado</span>
          </button>

          <button
            onClick={() => setIsJarvisOpen(true)}
            title="Jarvis: Comandos por Voz que Controlam o Computador (Alt+J)"
            className="flex items-center gap-1.5 px-3 py-1.5 rounded-xl bg-zinc-900 hover:bg-zinc-800 text-zinc-400 hover:text-emerald-400 border border-zinc-800 transition-all cursor-pointer text-xs font-semibold"
          >
            <Bot size={14} className="text-emerald-400" />
            <span>Jarvis PC</span>
          </button>

          <button
            onClick={() => setIsMindMapOpen(true)}
            title="Mapa Mental ao Vivo: Diagrama Auto-Montado por Voz (Alt+D)"
            className="flex items-center gap-1.5 px-3 py-1.5 rounded-xl bg-zinc-900 hover:bg-zinc-800 text-zinc-400 hover:text-cyan-400 border border-zinc-800 transition-all cursor-pointer text-xs font-semibold"
          >
            <Network size={14} className="text-cyan-400" />
            <span>Mapa Mental</span>
          </button>

          <button
            onClick={() => setIsContentOpen(true)}
            title="Conversa Vira Conteúdo: LinkedIn, Newsletter, Vídeo & Thread (Alt+C)"
            className="flex items-center gap-1.5 px-3 py-1.5 rounded-xl bg-zinc-900 hover:bg-zinc-800 text-zinc-400 hover:text-rose-400 border border-zinc-800 transition-all cursor-pointer text-xs font-semibold"
          >
            <Wand2 size={14} className="text-rose-400" />
            <span>Criar Conteúdo</span>
          </button>

          <button
            onClick={() => setIsSessionsOpen(true)}
            title="Histórico de Sessões"
            className="p-2 rounded-xl bg-zinc-900 hover:bg-zinc-800 text-zinc-400 hover:text-white border border-zinc-800 transition-all cursor-pointer"
          >
            <History size={15} />
          </button>

          <button
            onClick={() => setIsOnboardingOpen(true)}
            title="Tour Guiado do Sistema"
            className="p-2 rounded-xl bg-zinc-900 hover:bg-zinc-800 text-zinc-400 hover:text-white border border-zinc-800 transition-all cursor-pointer"
          >
            <Compass size={15} />
          </button>

          <button
            onClick={() => setIsSettingsOpen(true)}
            title="Configurações e Chave de API"
            className="p-2 rounded-xl bg-zinc-900 hover:bg-zinc-800 text-zinc-400 hover:text-white border border-zinc-800 transition-all cursor-pointer"
          >
            <Settings size={15} />
          </button>
        </div>
      </header>

      {/* Floating Whisper Proactive Coach Banner */}
      {activeWhisperAlert && (
        <div className="mx-4 mt-2 px-4 py-2 rounded-xl bg-amber-500/10 border border-amber-500/30 flex items-center justify-between shadow-lg shadow-amber-500/5 backdrop-blur-md animate-in fade-in slide-in-from-top-2 duration-200">
          <div className="flex items-center gap-2.5 text-xs text-amber-200">
            <span className="w-2 h-2 rounded-full bg-amber-400 animate-ping shrink-0" />
            <span className="font-semibold text-amber-300">Coach Sussurro (Proativo):</span>
            <span className="text-zinc-200">{activeWhisperAlert.message}</span>
          </div>
          <div className="flex items-center gap-2">
            {activeWhisperAlert.suggestedAction && (
              <button
                onClick={() => {
                  navigator.clipboard.writeText(activeWhisperAlert.suggestedAction!);
                }}
                className="text-[10px] px-2.5 py-1 rounded-lg bg-amber-500/20 hover:bg-amber-500/30 text-amber-200 font-semibold cursor-pointer transition-colors border border-amber-500/30"
                title="Copiar pergunta para fazer ao cliente"
              >
                Copiar Pergunta Sugerida
              </button>
            )}
            <button
              onClick={() => setActiveWhisperAlert(null)}
              className="text-zinc-500 hover:text-zinc-300 text-xs px-1.5 py-0.5 rounded hover:bg-zinc-800 transition-colors cursor-pointer"
              title="Dispensar sugestão"
            >
              ✕
            </button>
          </div>
        </div>
      )}

      {/* Main Workspace Body */}
      {activeNavTab === 'recorder' ? (
        <MeetingRecorderTab
          isRecording={isRecording}
          recordedTimeSec={recordedTimeSec}
          lastRecording={lastRecording}
          audioLevel={audioLevel}
          onStartRecording={() => startRecording(true)}
          onStopRecording={stopRecording}
          onDownloadRecording={downloadRecording}
          onGenerateAta={handleOpenWrapUp}
          onOpenContent={() => setIsContentOpen(true)}
          onClearRecording={clearLastRecording}
        />
      ) : (
        <main className="flex-1 flex overflow-hidden p-4 gap-4">
          {/* Left Column: Live Audio Stream View (Unified or Split Columns) */}
          <AudioStreamView
            mode={currentMode}
            status={isMuted ? 'muted' : isConnected ? aiStatus : 'idle'}
            history={history}
            userLiveTranscript={userTranscript}
            agentLiveTranscript={agentTranscript}
          />

          {/* Right Column: Insights, Whisper Coach, Mini-CRM & Screen OCR */}
          <InsightsPanel
            screenContext={screenContext}
            onRefreshScreen={captureNow}
            isScanningScreen={isScanning}
            onOpenWrapUp={handleOpenWrapUp}
          />
        </main>
      )}

      {/* Bottom Audio & Action Control Bar */}
      <footer className="flex items-center justify-between px-6 py-3 border-t border-zinc-800/80 bg-zinc-950/80 backdrop-blur-md shrink-0">
        {/* Left: Connection State & Mic Level */}
        <div className="flex items-center gap-4">
          <div className="flex items-center gap-2">
            {isConnected ? (
              <Wifi size={14} className="text-emerald-400" />
            ) : (
              <WifiOff size={14} className="text-zinc-600" />
            )}
            <span className="text-xs font-mono text-zinc-400">
              {connectionState === 'connected'
                ? 'OpenAI Realtime Conectado'
                : connectionState === 'connecting'
                ? 'Conectando...'
                : 'Desconectado'}
            </span>
          </div>

          {/* Mini audio level meter + VAD indicator */}
          <div className="flex items-center gap-1.5 h-3">
            {[0.2, 0.4, 0.6, 0.8, 1.0].map((step, idx) => (
              <div
                key={idx}
                className={`w-1 rounded-full transition-all duration-75 ${
                  audioLevel >= step && !isMuted
                    ? 'h-3 bg-indigo-500 shadow-sm shadow-indigo-500/50'
                    : 'h-1.5 bg-zinc-800'
                }`}
              />
            ))}
            {currentMode === 'eco' && (
              <span
                className={`text-[9px] px-1.5 py-0.2 rounded-full font-mono transition-colors ${
                  isSpeakingVAD ? 'bg-emerald-500/20 text-emerald-300' : 'bg-zinc-800 text-zinc-500'
                }`}
              >
                VAD: {isSpeakingVAD ? 'VOZ' : 'SILÊNCIO'}
              </span>
            )}
          </div>
        </div>

        {/* Center: Primary Voice Toggle Button */}
        <div className="flex items-center gap-3">
          <button
            onClick={toggleMute}
            disabled={!isConnected}
            title={isMuted ? 'Desmutar (Alt+M)' : 'Silenciar (Alt+M)'}
            className={`p-2.5 rounded-full border transition-all cursor-pointer ${
              isMuted
                ? 'bg-red-500/20 text-red-400 border-red-500/40 hover:bg-red-500/30'
                : 'bg-zinc-900 text-zinc-300 border-zinc-800 hover:bg-zinc-800'
            } ${!isConnected ? 'opacity-40 cursor-not-allowed' : ''}`}
          >
            {isMuted ? <MicOff size={16} /> : <Mic size={16} />}
          </button>

          <button
            onClick={toggleSession}
            className={`flex items-center gap-2 px-6 py-2.5 rounded-full font-semibold text-xs transition-all shadow-lg cursor-pointer ${
              isConnected
                ? 'bg-rose-600 hover:bg-rose-500 text-white shadow-rose-600/25 animate-pulse'
                : 'bg-indigo-600 hover:bg-indigo-500 text-white shadow-indigo-600/30 hover:scale-102'
            }`}
          >
            <Radio size={14} />
            <span>{isConnected ? 'Desconectar Voz' : 'Conectar Voz Realtime'}</span>
          </button>
        </div>

        {/* Right: Quick text prompt / info */}
        <form onSubmit={handleSendText} className="flex items-center gap-2">
          <input
            type="text"
            placeholder="Interagir por texto..."
            value={textInput}
            onChange={(e) => setTextInput(e.target.value)}
            className="w-56 px-3 py-1.5 bg-zinc-900 border border-zinc-800 rounded-xl text-xs text-zinc-200 placeholder-zinc-600 focus:outline-none focus:border-indigo-500"
          />
          <button
            type="submit"
            disabled={!textInput.trim()}
            className="p-1.5 rounded-xl bg-zinc-800 text-zinc-400 hover:text-white disabled:opacity-40 cursor-pointer"
          >
            <Send size={13} />
          </button>
        </form>
      </footer>

      {/* Modals & Drawers */}
      <OnboardingModal
        isOpen={isOnboardingOpen}
        onComplete={() => setIsOnboardingOpen(false)}
        agents={agents}
        onSelectAgent={selectAgent}
      />

      <SettingsModal
        isOpen={isSettingsOpen}
        onClose={() => setIsSettingsOpen(false)}
        onApiKeySaved={() => {}}
      />

      <AgentManagerModal
        isOpen={isAgentsOpen}
        onClose={() => setIsAgentsOpen(false)}
        agents={agents}
        activeAgent={activeAgent}
        memories={memories}
        onSelectAgent={selectAgent}
        onSaveAgent={saveAgent}
        onDeleteAgent={removeAgent}
        onAddMemory={addMemory}
        onDeleteMemory={deleteMemory}
      />

      <ToolConfirmationModal
        request={pendingConfirmation}
        onApprove={handleToolApprove}
        onReject={handleToolReject}
      />

      <SessionsDrawer
        isOpen={isSessionsOpen}
        onClose={() => setIsSessionsOpen(false)}
      />

      <ScreenRecorderModal
        recording={lastRecording}
        onClose={clearLastRecording}
        onDownload={downloadRecording}
        onAnalyzeWithAi={(rec) => {
          handleOpenWrapUp();
          clearLastRecording();
        }}
      />

      <PostMeetingModal
        wrapUp={wrapUpData}
        onClose={() => setWrapUpData(null)}
        onSendEmail={(email) => {
          alert(`E-mail de follow-up pronto para envio via SMTP para: ${email.to}`);
          setWrapUpData(null);
        }}
        onPushToNotion={(tasks) => {
          alert('Decisões e tarefas exportadas com sucesso para o Notion!');
        }}
      />

      <AutomationsModal
        isOpen={isAutomationsOpen}
        onClose={() => setIsAutomationsOpen(false)}
        onSimulateTrigger={(rule) => {
          setTriggeredRuleAction(rule);
          setIsAutomationsOpen(false);
        }}
      />

      <SecondBrainModal
        isOpen={isBrainOpen}
        onClose={() => setIsBrainOpen(false)}
      />

      <WeeklyAudioBriefingModal
        isOpen={isBriefingOpen}
        onClose={() => setIsBriefingOpen(false)}
      />

      <JarvisCommanderModal
        isOpen={isJarvisOpen}
        onClose={() => setIsJarvisOpen(false)}
      />

      <LiveMindMapModal
        isOpen={isMindMapOpen}
        onClose={() => setIsMindMapOpen(false)}
      />

      <ConversationToContentModal
        isOpen={isContentOpen}
        onClose={() => setIsContentOpen(false)}
      />

      {/* Floating Triggered Action Card (IFTTT popup) */}
      {triggeredRuleAction && (
        <div className="fixed bottom-16 right-6 z-40 max-w-md w-full p-4 rounded-2xl bg-zinc-900 border-2 border-indigo-500/80 shadow-2xl backdrop-blur-md animate-in slide-in-from-bottom-3 duration-200">
          <div className="flex items-center justify-between pb-2 mb-2 border-b border-zinc-800">
            <div className="flex items-center gap-2">
              <Zap size={14} className="text-amber-400 animate-pulse" />
              <span className="text-xs font-bold text-white">
                Gatilho Disparado: {triggeredRuleAction.name}
              </span>
            </div>
            <button
              onClick={() => setTriggeredRuleAction(null)}
              className="text-zinc-500 hover:text-white cursor-pointer"
            >
              ✕
            </button>
          </div>
          <div className="text-xs text-indigo-300 font-semibold mb-1">
            {triggeredRuleAction.actionTitle}
          </div>
          <p className="text-xs text-zinc-300 font-mono bg-zinc-950 p-2.5 rounded-xl border border-zinc-800 mb-3 whitespace-pre-wrap leading-relaxed">
            {triggeredRuleAction.actionPayload}
          </p>
          <div className="flex justify-end gap-2">
            <button
              onClick={() => setTriggeredRuleAction(null)}
              className="px-3 py-1 bg-zinc-800 hover:bg-zinc-700 text-zinc-300 rounded-lg text-xs font-medium cursor-pointer"
            >
              Dispensar
            </button>
            <button
              onClick={() => {
                alert(
                  triggeredRuleAction.actionType === 'create_contract'
                    ? 'Minuta de contrato gerada com sucesso e salva no Drive / Notion!'
                    : triggeredRuleAction.actionType === 'dispatch_webhook'
                    ? 'Payload do webhook enviado com sucesso para o CRM / n8n!'
                    : 'Comparativo copiado para a área de transferência!'
                );
                setTriggeredRuleAction(null);
              }}
              className="px-3 py-1 bg-indigo-600 hover:bg-indigo-500 text-white rounded-lg text-xs font-semibold cursor-pointer shadow-sm"
            >
              {triggeredRuleAction.actionType === 'create_contract'
                ? 'Gerar Contrato Agora 📑'
                : triggeredRuleAction.actionType === 'dispatch_webhook'
                ? 'Disparar Webhook CRM 🚀'
                : 'Copiar Comparativo 📋'}
            </button>
          </div>
        </div>
      )}
    </div>
  );
};
export default App;
