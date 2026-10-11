import React, { useRef, useEffect, useState } from 'react';
import { AssistantMode, AssistantStatus } from '../../types';
import {
  Mic,
  Volume2,
  Sparkles,
  User,
  Copy,
  Check,
  Terminal,
  Columns,
  List,
} from 'lucide-react';

interface TranscriptItem {
  id: string;
  speaker: string; // 'user' | 'agent' | 'remote_audio' | 'system'
  text: string;
  time: string;
  translation?: string;
}

interface AudioStreamViewProps {
  mode: AssistantMode;
  status: AssistantStatus;
  history: TranscriptItem[];
  userLiveTranscript: string;
  agentLiveTranscript: string;
  onClearHistory?: () => void;
}

export const AudioStreamView: React.FC<AudioStreamViewProps> = ({
  mode,
  status,
  history,
  userLiveTranscript,
  agentLiveTranscript,
  onClearHistory,
}) => {
  const bottomRef = useRef<HTMLDivElement>(null);
  const [copiedId, setCopiedId] = useState<string | null>(null);
  const [splitView, setSplitView] = useState(mode === 'ultra');
  const [bilingualSubtitles, setBilingualSubtitles] = useState(true);
  const [targetLang, setTargetLang] = useState<'EN' | 'ES' | 'PT'>('EN');

  // Simulated live translator helper for demo and live stream
  const getBilingualTranslation = (text: string, lang: 'EN' | 'ES' | 'PT') => {
    if (lang === 'EN') {
      if (text.includes('hesitou no prazo')) return 'He hesitated on the deadline. Offer 2 phases.';
      if (text.includes('preço')) return 'Client is inquiring about the pricing structure and annual discount.';
      if (text.includes('proposta')) return 'We will send the revised commercial proposal before 6 PM.';
      if (text.includes('LGPD')) return 'Local data privacy and encryption compliance are guaranteed.';
      return `[EN] ${text}`;
    } else if (lang === 'ES') {
      return `[ES] ${text}`;
    }
    return text;
  };

  // Sync split view recommendation with Ultra mode
  useEffect(() => {
    if (mode === 'ultra') setSplitView(true);
  }, [mode]);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [history, userLiveTranscript, agentLiveTranscript]);

  const copyText = (id: string, text: string) => {
    navigator.clipboard.writeText(text);
    setCopiedId(id);
    setTimeout(() => setCopiedId(null), 2000);
  };

  const userEntries = history.filter(
    (h) => h.speaker === 'user' || h.speaker === 'user_mic'
  );
  const remoteAndAgentEntries = history.filter(
    (h) => h.speaker === 'remote_audio' || h.speaker === 'agent'
  );

  return (
    <div className="flex-1 flex flex-col h-full bg-zinc-950/40 rounded-2xl border border-zinc-800/80 overflow-hidden backdrop-blur-sm">
      {/* Header */}
      <div className="flex items-center justify-between px-4 py-3 border-b border-zinc-800/60 bg-zinc-900/30">
        <div className="flex items-center gap-2">
          <Terminal size={14} className="text-indigo-400" />
          <span className="text-xs font-semibold text-zinc-300">
            {splitView ? 'Transcrição em Colunas Paralelas (WASAPI Loopback)' : 'Fluxo de Transcrição Contínua'}
          </span>
          <span
            className={`text-[10px] px-2 py-0.5 rounded-full font-mono ${
              mode === 'ultra'
                ? 'bg-amber-500/20 text-amber-300 border border-amber-500/30'
                : mode === 'eco'
                ? 'bg-emerald-500/20 text-emerald-300 border border-emerald-500/30'
                : 'bg-indigo-500/20 text-indigo-300 border border-indigo-500/30'
            }`}
          >
            {mode.toUpperCase()}
          </span>
        </div>

        <div className="flex items-center gap-2.5">
          {/* Bilingual Subtitle Toggle */}
          <button
            onClick={() => setBilingualSubtitles(!bilingualSubtitles)}
            className={`flex items-center gap-1 text-[11px] px-2 py-1 rounded-lg border transition-colors cursor-pointer ${
              bilingualSubtitles
                ? 'bg-indigo-500/20 border-indigo-500/40 text-indigo-300 font-semibold'
                : 'bg-zinc-900 border-zinc-800 text-zinc-500'
            }`}
            title="Ativar/Desativar Legendas Bilíngues Simultâneas"
          >
            <span>🌐</span>
            <span>Legenda Bilíngue ({targetLang})</span>
          </button>

          {/* Toggle View mode */}
          <button
            onClick={() => setSplitView(!splitView)}
            className="flex items-center gap-1 text-[11px] px-2 py-1 rounded-lg bg-zinc-900 hover:bg-zinc-800 text-zinc-400 hover:text-zinc-200 border border-zinc-800 transition-colors cursor-pointer"
            title={splitView ? 'Alternar para lista unificada' : 'Alternar para colunas Você vs Reunião'}
          >
            {splitView ? <List size={12} /> : <Columns size={12} />}
            <span>{splitView ? 'Lista' : 'Colunas'}</span>
          </button>

          {history.length > 0 && (
            <button
              onClick={onClearHistory}
              className="text-[11px] text-zinc-500 hover:text-zinc-300 transition-colors cursor-pointer"
            >
              Limpar
            </button>
          )}

          <div className="flex items-center gap-1.5 text-xs text-zinc-400">
            <span
              className={`w-2 h-2 rounded-full ${
                status === 'listening'
                  ? 'bg-emerald-500 animate-pulse'
                  : status === 'speaking'
                  ? 'bg-indigo-500 animate-pulse'
                  : status === 'analyzing'
                  ? 'bg-amber-500 animate-pulse'
                  : status === 'muted'
                  ? 'bg-red-500'
                  : 'bg-zinc-600'
              }`}
            />
            <span className="text-[11px] font-mono capitalize">{status}</span>
          </div>
        </div>
      </div>

      {/* Stream messages container */}
      <div className="flex-1 overflow-y-auto p-4 select-text">
        {history.length === 0 && !userLiveTranscript && !agentLiveTranscript ? (
          <div className="h-full flex flex-col items-center justify-center text-center text-zinc-500 py-12">
            <div className="w-12 h-12 rounded-2xl bg-zinc-900 border border-zinc-800 flex items-center justify-center mb-3">
              <Mic size={22} className="text-zinc-600" />
            </div>
            <p className="text-sm font-medium text-zinc-400">Aguardando entrada de áudio...</p>
            <p className="text-xs text-zinc-600 max-w-xs mt-1">
              {mode === 'ultra'
                ? 'Modo Ultra ativo: O que você fala e o som da reunião (Loopback) são separados em colunas distintas.'
                : mode === 'eco'
                ? 'Modo Eco ativo: Detecção de voz local (VAD) suprime trechos de silêncio para economia de dados.'
                : 'Fale ao microfone para iniciar a conversação em tempo real.'}
            </p>
          </div>
        ) : splitView ? (
          /* Split Dual Column Layout for Ultra Mode */
          <div className="grid grid-cols-2 gap-4 h-full">
            {/* Left Column: Você (Microfone) */}
            <div className="flex flex-col bg-zinc-900/30 rounded-xl p-3 border border-zinc-800/60 overflow-hidden">
              <div className="flex items-center gap-1.5 pb-2 mb-2 border-b border-zinc-800/60 text-xs font-semibold text-emerald-300">
                <User size={13} />
                <span>Você (Microfone Local)</span>
              </div>
              <div className="flex-1 overflow-y-auto space-y-2.5 pr-1">
                {userEntries.map((item) => (
                  <div
                    key={item.id}
                    className="p-2.5 rounded-lg bg-zinc-900/60 border border-zinc-800/80 text-xs text-zinc-200"
                  >
                    <div className="flex justify-between items-center text-[10px] text-zinc-500 mb-1">
                      <span>{item.time}</span>
                      <button
                        onClick={() => copyText(item.id, item.text)}
                        className="hover:text-white"
                      >
                        {copiedId === item.id ? <Check size={11} className="text-emerald-400" /> : <Copy size={11} />}
                      </button>
                    </div>
                    <p className="leading-relaxed">{item.text}</p>
                    {bilingualSubtitles && (
                      <div className="mt-1 pt-1 border-t border-zinc-800/40 text-[11px] text-cyan-300/85 italic font-sans flex items-center gap-1.5">
                        <span className="text-[9px] text-zinc-500 font-mono">🌐 {targetLang}:</span>
                        <span>{item.translation || getBilingualTranslation(item.text, targetLang)}</span>
                      </div>
                    )}
                  </div>
                ))}
                {userLiveTranscript && (
                  <div className="p-2.5 rounded-lg bg-emerald-950/20 border border-emerald-500/40 text-xs text-emerald-200 animate-pulse">
                    <span className="text-[10px] text-emerald-400 font-mono block mb-1">Ao vivo...</span>
                    {userLiveTranscript}
                  </div>
                )}
              </div>
            </div>

            {/* Right Column: Participante Remoto & Assistente */}
            <div className="flex flex-col bg-zinc-900/30 rounded-xl p-3 border border-zinc-800/60 overflow-hidden">
              <div className="flex items-center gap-1.5 pb-2 mb-2 border-b border-zinc-800/60 text-xs font-semibold text-cyan-300">
                <Volume2 size={13} />
                <span>Reunião & Assistente (WASAPI)</span>
              </div>
              <div className="flex-1 overflow-y-auto space-y-2.5 pr-1">
                {remoteAndAgentEntries.map((item) => {
                  const isAgent = item.speaker === 'agent';
                  return (
                    <div
                      key={item.id}
                      className={`p-2.5 rounded-lg border text-xs ${
                        isAgent
                          ? 'bg-indigo-950/30 border-indigo-500/30 text-indigo-100'
                          : 'bg-cyan-950/20 border-cyan-500/30 text-zinc-200'
                      }`}
                    >
                      <div className="flex justify-between items-center text-[10px] text-zinc-400 mb-1">
                        <span className="font-semibold text-zinc-300">
                          {isAgent ? 'Coucou Assistente' : 'Participante Remoto'}
                        </span>
                        <span className="text-zinc-500">{item.time}</span>
                      </div>
                      <p className="leading-relaxed">{item.text}</p>
                      {bilingualSubtitles && (
                        <div className="mt-1 pt-1 border-t border-zinc-800/40 text-[11px] text-cyan-300/85 italic font-sans flex items-center gap-1.5">
                          <span className="text-[9px] text-zinc-500 font-mono">🌐 {targetLang}:</span>
                          <span>{item.translation || getBilingualTranslation(item.text, targetLang)}</span>
                        </div>
                      )}
                    </div>
                  );
                })}
                {agentLiveTranscript && (
                  <div className="p-2.5 rounded-lg bg-indigo-950/30 border border-indigo-500/40 text-xs text-indigo-200 animate-pulse">
                    <span className="text-[10px] text-indigo-400 font-mono block mb-1">Assistente respondendo...</span>
                    {agentLiveTranscript}
                  </div>
                )}
              </div>
            </div>
          </div>
        ) : (
          /* Single Chronological Unified Stream */
          <div className="space-y-3.5">
            {history.map((item) => {
              const isUser = item.speaker === 'user' || item.speaker === 'user_mic';
              const isRemote = item.speaker === 'remote_audio';
              const isAgent = item.speaker === 'agent';

              return (
                <div
                  key={item.id}
                  className={`group flex flex-col p-3 rounded-xl border transition-all duration-200 ${
                    isAgent
                      ? 'bg-indigo-950/20 border-indigo-500/20 hover:border-indigo-500/30'
                      : isRemote
                      ? 'bg-cyan-950/20 border-cyan-500/20 hover:border-cyan-500/30'
                      : 'bg-zinc-900/40 border-zinc-800/60 hover:border-zinc-700/60'
                  }`}
                >
                  <div className="flex items-center justify-between mb-1.5">
                    <div className="flex items-center gap-2">
                      <div
                        className={`w-5 h-5 rounded-md flex items-center justify-center text-[10px] font-bold ${
                          isAgent
                            ? 'bg-indigo-500/20 text-indigo-400'
                            : isRemote
                            ? 'bg-cyan-500/20 text-cyan-400'
                            : 'bg-emerald-500/20 text-emerald-400'
                        }`}
                      >
                        {isAgent ? <Sparkles size={11} /> : isRemote ? <Volume2 size={11} /> : <User size={11} />}
                      </div>
                      <span className="text-xs font-semibold text-zinc-300">
                        {isAgent
                          ? 'Coucou Copilot'
                          : isRemote
                          ? 'Participante Remoto (Reunião)'
                          : 'Você (Microfone)'}
                      </span>
                      <span className="text-[10px] text-zinc-600 font-mono">{item.time}</span>
                    </div>

                    <button
                      onClick={() => copyText(item.id, item.text)}
                      className="opacity-0 group-hover:opacity-100 text-zinc-500 hover:text-zinc-300 p-1 rounded transition-opacity"
                      title="Copiar texto"
                    >
                      {copiedId === item.id ? <Check size={12} className="text-emerald-400" /> : <Copy size={12} />}
                    </button>
                  </div>

                  <p className="text-xs leading-relaxed text-zinc-200 font-sans pl-7 whitespace-pre-wrap">{item.text}</p>
                  {bilingualSubtitles && (
                    <div className="mt-1.5 ml-7 pt-1 border-t border-zinc-800/40 text-[11px] text-cyan-300/85 italic font-sans flex items-center gap-1.5">
                      <span className="text-[9px] text-zinc-500 font-mono">🌐 {targetLang}:</span>
                      <span>{item.translation || getBilingualTranslation(item.text, targetLang)}</span>
                    </div>
                  )}
                </div>
              );
            })}

            {userLiveTranscript && (
              <div className="flex flex-col p-3 rounded-xl bg-zinc-900/60 border border-emerald-500/30 animate-pulse">
                <div className="flex items-center gap-2 mb-1.5">
                  <div className="w-5 h-5 rounded-md bg-emerald-500/20 text-emerald-400 flex items-center justify-center">
                    <Mic size={11} />
                  </div>
                  <span className="text-xs font-semibold text-emerald-300">Você (ao vivo...)</span>
                </div>
                <p className="text-xs text-zinc-300 pl-7">{userLiveTranscript}</p>
              </div>
            )}

            {agentLiveTranscript && (
              <div className="flex flex-col p-3 rounded-xl bg-indigo-950/30 border border-indigo-500/40 animate-pulse">
                <div className="flex items-center gap-2 mb-1.5">
                  <div className="w-5 h-5 rounded-md bg-indigo-500/20 text-indigo-400 flex items-center justify-center">
                    <Sparkles size={11} />
                  </div>
                  <span className="text-xs font-semibold text-indigo-300">Assistente respondendo...</span>
                </div>
                <p className="text-xs text-indigo-100 pl-7">{agentLiveTranscript}</p>
              </div>
            )}
          </div>
        )}

        <div ref={bottomRef} />
      </div>
    </div>
  );
};
