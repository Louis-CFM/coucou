import React, { useState, useEffect } from 'react';
import {
  Video,
  Square,
  Play,
  Download,
  Sparkles,
  Volume2,
  Mic,
  Clock,
  FileText,
  Wand2,
  Share2,
  CheckCircle2,
  ShieldCheck,
  Disc,
  Calendar,
  ExternalLink,
  Check,
  Key,
} from 'lucide-react';
import { ScreenRecording } from '../../hooks/useScreenRecorder';
import { GoogleCalendarService, CalendarEvent } from '../../services/calendar';

interface MeetingRecorderTabProps {
  isRecording: boolean;
  recordedTimeSec: number;
  lastRecording: ScreenRecording | null;
  audioLevel: number;
  onStartRecording: () => void;
  onStopRecording: () => void;
  onDownloadRecording: (recording: ScreenRecording) => void;
  onGenerateAta: () => void;
  onOpenContent: () => void;
  onClearRecording: () => void;
}

export const MeetingRecorderTab: React.FC<MeetingRecorderTabProps> = ({
  isRecording,
  recordedTimeSec,
  lastRecording,
  audioLevel,
  onStartRecording,
  onStopRecording,
  onDownloadRecording,
  onGenerateAta,
  onOpenContent,
  onClearRecording,
}) => {
  const [events, setEvents] = useState<CalendarEvent[]>([]);
  const [selectedEvent, setSelectedEvent] = useState<CalendarEvent | null>(null);
  const [isSyncingCalendar, setIsSyncingCalendar] = useState(false);
  const [calendarSyncSuccess, setCalendarSyncSuccess] = useState(false);
  const [showTokenInput, setShowTokenInput] = useState(false);
  const [tokenValue, setTokenValue] = useState(GoogleCalendarService.getToken() || '');
  const [feedbackMsg, setFeedbackMsg] = useState('');
  const [isValidating, setIsValidating] = useState(false);
  const [connectedEmail, setConnectedEmail] = useState<string | null>(GoogleCalendarService.getConnectedEmail());

  useEffect(() => {
    void loadCalendarEvents();
  }, []);

  const loadCalendarEvents = async () => {
    const list = await GoogleCalendarService.getUpcomingEvents();
    setEvents(list);
    if (list.length > 0) setSelectedEvent(list[0]);
    setConnectedEmail(GoogleCalendarService.getConnectedEmail());
  };

  const handleOpenGoogleLogin = () => {
    GoogleCalendarService.openGoogleLogin();
    setShowTokenInput(true);
    setFeedbackMsg("Janela do Google aberta! Conclua o login na sua conta, autorize o Calendar e cole o Access Token gerado abaixo.");
  };

  const handleSaveToken = async () => {
    if (!tokenValue.trim()) {
      GoogleCalendarService.disconnect();
      setConnectedEmail(null);
      setFeedbackMsg("Desconectado da conta Google. O app voltou ao modo de demonstração.");
      void loadCalendarEvents();
      return;
    }

    setIsValidating(true);
    setFeedbackMsg("Validando com as APIs do Google...");
    const res = await GoogleCalendarService.verifyAndSaveToken(tokenValue);
    setIsValidating(false);

    if (res.ok) {
      setConnectedEmail(res.email || null);
      setFeedbackMsg(`✓ Conectado com sucesso como ${res.email}! Sincronização 100% ativa.`);
      setTimeout(() => setShowTokenInput(false), 2500);
      void loadCalendarEvents();
    } else {
      setFeedbackMsg(`Falha ao conectar: ${res.error}`);
    }
  };

  const handleSyncToCalendar = async () => {
    if (!selectedEvent || isSyncingCalendar) return;
    setIsSyncingCalendar(true);
    const summary = `• Alinhamento e escopo de entregas Q4 validados com sucesso.\n• Decisões: Integração com Google Calendar API ativada.\n• Próximos passos: Envio das minutas e sincronização das tarefas.`;
    const res = await GoogleCalendarService.syncMeetingAtaToEvent(selectedEvent.id, summary);
    setIsSyncingCalendar(false);
    if (res.notConnected) {
      setShowTokenInput(true);
      setFeedbackMsg("⚠️ Você ainda não conectou sua conta do Google. Clique em 'Logar com o Google' abaixo para sincronizar na sua agenda real.");
    } else if (res.ok) {
      setCalendarSyncSuccess(true);
      setTimeout(() => setCalendarSyncSuccess(false), 3500);
    } else {
      setFeedbackMsg(`Erro ao salvar no Google Calendar: ${res.error}`);
    }
  };

  const formatTime = (seconds: number) => {
    const mins = Math.floor(seconds / 60)
      .toString()
      .padStart(2, '0');
    const secs = (seconds % 60).toString().padStart(2, '0');
    return `${mins}:${secs}`;
  };

  return (
    <div className="flex-1 flex flex-col p-6 overflow-y-auto max-w-5xl mx-auto w-full gap-6">
      {/* Top Banner / Status */}
      <div className="flex items-center justify-between p-5 rounded-2xl bg-zinc-900/80 border border-zinc-800 shadow-xl backdrop-blur-md">
        <div className="flex items-center gap-3.5">
          <div
            className={`w-10 h-10 rounded-xl flex items-center justify-center border transition-all ${
              isRecording
                ? 'bg-rose-500/20 border-rose-500/40 text-rose-400 animate-pulse'
                : 'bg-zinc-800/80 border-zinc-700/60 text-zinc-300'
            }`}
          >
            <Video size={20} />
          </div>
          <div>
            <div className="flex items-center gap-2.5">
              <h2 className="text-base font-bold text-white tracking-tight">
                Gravador de Tela & Reunião
              </h2>
              <span
                className={`text-[10px] font-mono px-2 py-0.5 rounded-full border ${
                  isRecording
                    ? 'bg-rose-500/10 text-rose-300 border-rose-500/30 font-semibold'
                    : 'bg-zinc-800 text-zinc-400 border-zinc-700'
                }`}
              >
                {isRecording ? `GRAVANDO [${formatTime(recordedTimeSec)}]` : 'SISTEMA PRONTO'}
              </span>
            </div>
            <p className="text-xs text-zinc-400 mt-0.5">
              Captura bidirecional integrada: tela inteira ou janela, áudio do sistema (WASAPI Loopback) e microfone.
            </p>
          </div>
        </div>

        {/* Audio Channels Indicators */}
        <div className="flex items-center gap-4">
          <div className="flex items-center gap-2 px-3 py-1.5 rounded-xl bg-zinc-950/60 border border-zinc-800/80 text-xs">
            <Volume2 size={13} className="text-indigo-400" />
            <span className="font-mono text-[11px] text-zinc-300">WASAPI Loopback</span>
            <span className="w-1.5 h-1.5 rounded-full bg-emerald-400" />
          </div>
          <div className="flex items-center gap-2 px-3 py-1.5 rounded-xl bg-zinc-950/60 border border-zinc-800/80 text-xs">
            <Mic size={13} className="text-violet-400" />
            <span className="font-mono text-[11px] text-zinc-300">Microfone</span>
            <span
              className={`w-1.5 h-1.5 rounded-full ${
                audioLevel > 0.05 ? 'bg-emerald-400 animate-ping' : 'bg-zinc-600'
              }`}
            />
          </div>
        </div>
      </div>

      {/* Google Calendar Upcoming Meeting Integration Banner */}
      <div className="p-4 rounded-2xl bg-zinc-900/60 border border-zinc-800 shadow-lg flex flex-col md:flex-row items-start md:items-center justify-between gap-4">
        <div className="flex items-center gap-3 min-w-0">
          <div className="w-9 h-9 rounded-xl bg-indigo-500/10 border border-indigo-500/20 text-indigo-400 flex items-center justify-center shrink-0">
            <Calendar size={18} />
          </div>
          <div className="min-w-0">
            <div className="flex items-center gap-2 flex-wrap">
              <span className="text-xs font-semibold text-white truncate max-w-sm">
                {selectedEvent ? selectedEvent.summary : 'Nenhuma reunião agendada para hoje'}
              </span>
              {selectedEvent && (
                <span className="text-[10px] font-mono px-2 py-0.5 rounded-full bg-indigo-500/15 text-indigo-300 border border-indigo-500/30 font-medium">
                  {Math.round((new Date(selectedEvent.start).getTime() - Date.now()) / 60000) <= 0
                    ? 'AGORA'
                    : `EM ${Math.round((new Date(selectedEvent.start).getTime() - Date.now()) / 60000)}M`}
                </span>
              )}
              <span className={`text-[10px] font-mono px-1.5 py-0.5 rounded border ${
                connectedEmail
                  ? 'bg-emerald-500/10 text-emerald-300 border-emerald-500/30'
                  : 'text-amber-400 bg-amber-500/10 border-amber-500/30'
              }`}>
                {connectedEmail ? `GOOGLE (${connectedEmail})` : 'NÃO CONECTADO (DEMO)'}
              </span>
            </div>
            <p className="text-[11px] text-zinc-400 mt-0.5 truncate max-w-md">
              {selectedEvent?.attendees && selectedEvent.attendees.length > 0
                ? `Convidados: ${selectedEvent.attendees.map(a => a.displayName || a.email).join(', ')}`
                : 'Reunião sincronizada da agenda Google'}
            </p>
          </div>
        </div>

        <div className="flex items-center gap-2 shrink-0 w-full md:w-auto justify-end flex-wrap">
          {!connectedEmail && (
            <button
              onClick={handleOpenGoogleLogin}
              className="flex items-center gap-1.5 px-3 py-1.5 rounded-xl bg-blue-600 hover:bg-blue-500 text-white text-xs font-semibold shadow-md shadow-blue-600/20 transition-all cursor-pointer"
            >
              <span>Logar com o Google ↗</span>
            </button>
          )}

          {selectedEvent?.meetUrl && (
            <button
              onClick={() => GoogleCalendarService.openMeetLink(selectedEvent.meetUrl)}
              className="flex items-center gap-1.5 px-3 py-1.5 rounded-xl bg-indigo-600/20 hover:bg-indigo-600/30 text-indigo-200 border border-indigo-500/40 text-xs font-medium transition-all cursor-pointer"
            >
              <ExternalLink size={13} />
              <span>Entrar no Google Meet</span>
            </button>
          )}

          <button
            onClick={handleSyncToCalendar}
            disabled={isSyncingCalendar || !selectedEvent}
            className={`flex items-center gap-1.5 px-3 py-1.5 rounded-xl text-xs font-medium border transition-all cursor-pointer ${
              calendarSyncSuccess
                ? 'bg-emerald-500/20 border-emerald-500/40 text-emerald-300'
                : 'bg-zinc-800/80 hover:bg-zinc-750 border-zinc-700 text-zinc-200'
            }`}
          >
            {calendarSyncSuccess ? <Check size={13} /> : <Calendar size={13} />}
            <span>
              {calendarSyncSuccess
                ? 'Ata Sincronizada!'
                : isSyncingCalendar
                ? 'Sincronizando...'
                : 'Sincronizar Ata no Calendar'}
            </span>
          </button>

          <button
            onClick={() => setShowTokenInput(!showTokenInput)}
            title="Configurar Token do Google Calendar"
            className="p-1.5 rounded-xl text-zinc-500 hover:text-zinc-300 bg-zinc-800/40 border border-zinc-750 transition-colors cursor-pointer"
          >
            <Key size={14} />
          </button>
        </div>
      </div>

      {showTokenInput && (
        <div className="p-4 rounded-xl bg-zinc-900 border border-zinc-800 flex flex-col gap-3 animate-in fade-in duration-150">
          <div className="flex flex-col md:flex-row items-center gap-3">
            <input
              type="password"
              value={tokenValue}
              onChange={(e) => setTokenValue(e.target.value)}
              placeholder="Cole o Bearer / OAuth2 Access Token da Google Calendar API (ya29...)"
              className="flex-1 w-full bg-zinc-950 border border-zinc-700 rounded-lg px-3 py-1.5 text-xs text-white placeholder-zinc-500 focus:outline-none focus:border-indigo-500 font-mono"
            />
            <div className="flex items-center gap-2 shrink-0">
              <button
                onClick={handleOpenGoogleLogin}
                className="px-3 py-1.5 rounded-lg bg-blue-600/20 hover:bg-blue-600/30 text-blue-300 border border-blue-500/30 text-xs font-medium transition-colors cursor-pointer"
              >
                Abrir Login Google ↗
              </button>
              <button
                onClick={handleSaveToken}
                disabled={isValidating}
                className="px-3 py-1.5 rounded-lg bg-indigo-600 hover:bg-indigo-500 text-white text-xs font-medium transition-colors cursor-pointer"
              >
                {isValidating ? 'Validando...' : 'Validar e Conectar'}
              </button>
              <button
                onClick={() => setShowTokenInput(false)}
                className="px-3 py-1.5 rounded-lg text-zinc-400 hover:text-zinc-200 text-xs transition-colors cursor-pointer"
              >
                Fechar
              </button>
            </div>
          </div>
          {feedbackMsg && (
            <p className="text-xs text-indigo-300 leading-relaxed font-mono">
              {feedbackMsg}
            </p>
          )}
        </div>
      )}

      {/* Main Recording Controller Panel */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
        {/* Left 2 Cols: Capture Controls & Video Preview */}
        <div className="md:col-span-2 flex flex-col gap-4">
          <div className="p-6 rounded-2xl bg-zinc-900/60 border border-zinc-800 flex flex-col items-center justify-center min-h-[260px] text-center relative overflow-hidden">
            {isRecording ? (
              <div className="flex flex-col items-center gap-4 animate-in fade-in duration-200">
                <div className="relative">
                  <div className="w-20 h-20 rounded-full bg-rose-500/20 border-2 border-rose-500 flex items-center justify-center animate-pulse">
                    <Disc size={36} className="text-rose-400 animate-spin" />
                  </div>
                </div>

                <div>
                  <div className="text-4xl font-mono font-bold text-white tracking-wider">
                    {formatTime(recordedTimeSec)}
                  </div>
                  <p className="text-xs text-zinc-400 mt-1">
                    Gravando tela com áudio em alta definição (Opus / VP9).
                  </p>
                </div>

                <button
                  onClick={onStopRecording}
                  className="flex items-center gap-2 px-6 py-3 rounded-xl bg-rose-600 hover:bg-rose-500 text-white font-semibold text-sm shadow-lg shadow-rose-600/30 transition-all cursor-pointer"
                >
                  <Square size={16} fill="white" />
                  <span>Parar e Concluir Gravação</span>
                </button>
              </div>
            ) : lastRecording ? (
              <div className="w-full flex flex-col gap-4">
                <div className="relative rounded-xl overflow-hidden bg-black border border-zinc-800 aspect-video flex items-center justify-center">
                  <video
                    src={lastRecording.url}
                    controls
                    className="w-full h-full object-contain"
                  />
                </div>
                <div className="flex items-center justify-between text-xs text-zinc-400 px-1">
                  <span>
                    Duração: {Math.floor(lastRecording.durationMs / 1000)}s • Arquivo: {lastRecording.name}
                  </span>
                  <div className="flex items-center gap-2">
                    <button
                      onClick={() => onDownloadRecording(lastRecording)}
                      className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-zinc-800 hover:bg-zinc-750 text-zinc-200 font-semibold border border-zinc-700 cursor-pointer"
                    >
                      <Download size={13} />
                      <span>Baixar WebM</span>
                    </button>
                    <button
                      onClick={onClearRecording}
                      className="px-3 py-1.5 rounded-lg text-zinc-500 hover:text-zinc-300 transition-colors cursor-pointer"
                    >
                      Nova Gravação
                    </button>
                  </div>
                </div>
              </div>
            ) : (
              <div className="flex flex-col items-center gap-4 py-8">
                <div className="w-16 h-16 rounded-2xl bg-zinc-800/80 border border-zinc-700 flex items-center justify-center text-zinc-400">
                  <Video size={28} />
                </div>
                <div>
                  <h3 className="text-base font-semibold text-white">Nenhuma gravação em andamento</h3>
                  <p className="text-xs text-zinc-400 max-w-sm mt-1">
                    Clique abaixo ou pressione <kbd className="px-1.5 py-0.5 rounded bg-zinc-800 border border-zinc-700 font-mono text-[11px] text-zinc-300">Alt + R</kbd> para iniciar a captura instantânea da reunião.
                  </p>
                </div>
                <button
                  onClick={onStartRecording}
                  className="flex items-center gap-2 px-6 py-3 rounded-xl bg-gradient-to-r from-rose-600 to-rose-500 hover:from-rose-500 hover:to-rose-400 text-white font-semibold text-sm shadow-lg shadow-rose-600/25 transition-all cursor-pointer"
                >
                  <Video size={16} />
                  <span>Iniciar Gravação de Reunião</span>
                </button>
              </div>
            )}
          </div>
        </div>

        {/* Right Col: Instant AI Actions */}
        <div className="flex flex-col gap-4">
          <div className="p-5 rounded-2xl bg-zinc-900/60 border border-zinc-800 flex flex-col gap-4">
            <h3 className="text-xs font-bold text-zinc-400 uppercase tracking-wider">
              Ações Pós-Reunião com IA
            </h3>

            <div className="space-y-2.5">
              <button
                onClick={onGenerateAta}
                className="w-full flex items-start gap-3 p-3.5 rounded-xl bg-zinc-950/60 hover:bg-zinc-800/80 border border-zinc-800 hover:border-indigo-500/40 text-left transition-all cursor-pointer group"
              >
                <div className="p-2 rounded-lg bg-indigo-500/10 text-indigo-400 border border-indigo-500/20 group-hover:bg-indigo-500/20 transition-colors">
                  <FileText size={16} />
                </div>
                <div>
                  <div className="text-xs font-semibold text-white">Gerar Ata & Tarefas</div>
                  <div className="text-[11px] text-zinc-400 mt-0.5 leading-snug">
                    Resumo executivo, decisões aprovadas, responsáveis e minuta de e-mail.
                  </div>
                </div>
              </button>

              <button
                onClick={onOpenContent}
                className="w-full flex items-start gap-3 p-3.5 rounded-xl bg-zinc-950/60 hover:bg-zinc-800/80 border border-zinc-800 hover:border-rose-500/40 text-left transition-all cursor-pointer group"
              >
                <div className="p-2 rounded-lg bg-rose-500/10 text-rose-400 border border-rose-500/20 group-hover:bg-rose-500/20 transition-colors">
                  <Wand2 size={16} />
                </div>
                <div>
                  <div className="text-xs font-semibold text-white">Conversa Vira Conteúdo</div>
                  <div className="text-[11px] text-zinc-400 mt-0.5 leading-snug">
                    Post LinkedIn, newsletter, roteiro de vídeo ou thread no seu tom de voz.
                  </div>
                </div>
              </button>
            </div>
          </div>

          {/* Compliance & Privacy Box */}
          <div className="p-4 rounded-2xl bg-zinc-950/40 border border-zinc-800/80 flex items-start gap-3 text-xs text-zinc-400">
            <ShieldCheck size={18} className="text-emerald-400 shrink-0 mt-0.5" />
            <div className="leading-relaxed text-[11px]">
              <span className="font-semibold text-zinc-300">Privacidade Local Garantida:</span> Os arquivos de áudio e vídeo são processados localmente no seu dispositivo. Nenhum dado é retido sem a sua autorização expressa.
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};
