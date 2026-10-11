import React, { useState, useEffect, useRef } from 'react';
import {
  X,
  Headphones,
  Play,
  Pause,
  RotateCcw,
  Volume2,
  Calendar,
  Trophy,
  Activity,
  AlertTriangle,
  Clock,
  Sparkles,
  CheckCircle2,
  Share2,
  Sliders,
  Flame,
} from 'lucide-react';
import { WeeklyAudioBriefing } from '../../types';

interface WeeklyAudioBriefingModalProps {
  isOpen: boolean;
  onClose: () => void;
}

export const WeeklyAudioBriefingModal: React.FC<WeeklyAudioBriefingModalProps> = ({
  isOpen,
  onClose,
}) => {
  const [isPlaying, setIsPlaying] = useState(false);
  const [playbackSpeed, setPlaybackSpeed] = useState<number>(1.0);
  const [progressSec, setProgressSec] = useState<number>(0);
  const totalDurationSec = 135; // 2m 15s

  const briefing: WeeklyAudioBriefing = {
    id: 'briefing-w41',
    weekLabel: 'Semana 41 • 06 a 10 de Outubro de 2026',
    durationFormatted: '02:15',
    audioNarratorVoice: 'Alloy (Voz Amigável & Empática)',
    spokenScript: `Olá! Sexta-feira chegou e este é o resumo semanal de você.

Nesta semana você teve 6 reuniões ao vivo e acumulou quase 3 horas de conversas altamente produtivas.

Sua maior conquista foi destravar o contrato da Logix Tech, de 24 mil reais, com a solução da entrega em duas fases. O cliente estava hesitante no prazo e sua saída foi cirúrgica.

Nos seus padrões: seu Talk Ratio médio foi de 64%, uma melhora incrível na escuta ativa em relação à semana passada, que estava em 78%. Você deixou os clientes falarem mais e fez perguntas abertas de alto valor.

O ponto de atenção para calibrar: na terça e quinta, duas reuniões ultrapassaram 45 minutos no mesmo tópico de precificação. Experimente puxar o fechamento antes dos 30 minutos quando sentir a primeira concordância.

Para a semana que vem, você já tem compromisso firme: quinta-feira às 14:30 com a Dra. Camila Duarte para fechar os detalhes de segurança e LGPD.

Você mandou muito bem essa semana. Descanse no fim de semana, você mereceu!`,
    achievements: [
      'Destravou o contrato anual da Logix Tech (R$ 24.000) com modelo de entrega em 2 etapas',
      'Conduziu 6 reuniões com gravação e atas automáticas geradas em menos de 10 segundos',
      'Indexou 3 novos playbooks comerciais no RAG local com busca de menos de 2s',
    ],
    patternsAndRhythm: {
      talkRatioAvg: 64,
      totalCalls: 6,
      hoursRecorded: 2.8,
      pacingAssessment: 'Ritmo Ideal (135 ppm médio • Escuta ativa aumentou 14%)',
    },
    areasToImprove: [
      'Duas reuniões passaram de 45 min no mesmo tópico. Pratique puxar o próximo passo antes dos 30 minutos.',
    ],
    nextWeekPriorities: [
      {
        title: 'Reunião Técnica de Segurança & LGPD',
        dayTime: 'Quinta-feira, 14:30',
        contactOrContext: 'Dra. Camila Duarte (Duarte & Assoc.)',
      },
      {
        title: 'Alinhamento de Implantação Fase 1',
        dayTime: 'Sexta-feira, 10:00',
        contactOrContext: 'Roberto Almeida (Logix Tech)',
      },
    ],
  };

  // Real TTS speech synthesis playback
  const utteranceRef = useRef<SpeechSynthesisUtterance | null>(null);

  useEffect(() => {
    if (!isOpen) {
      if (window.speechSynthesis) {
        window.speechSynthesis.cancel();
      }
      setIsPlaying(false);
      setProgressSec(0);
    }
  }, [isOpen]);

  const togglePlay = () => {
    if (!window.speechSynthesis) {
      setIsPlaying(!isPlaying);
      return;
    }

    if (isPlaying) {
      window.speechSynthesis.cancel();
      setIsPlaying(false);
    } else {
      window.speechSynthesis.cancel();
      const utterance = new SpeechSynthesisUtterance(briefing.spokenScript);
      utterance.lang = 'pt-BR';
      utterance.rate = playbackSpeed;
      utterance.pitch = 1.0;

      utterance.onend = () => {
        setIsPlaying(false);
        setProgressSec(totalDurationSec);
      };

      utterance.onerror = () => {
        setIsPlaying(false);
      };

      utteranceRef.current = utterance;
      window.speechSynthesis.speak(utterance);
      setIsPlaying(true);
    }
  };

  // Timer ticker for progress bar when playing
  useEffect(() => {
    let interval: any = null;
    if (isPlaying) {
      interval = setInterval(() => {
        setProgressSec((prev) => {
          if (prev >= totalDurationSec) {
            setIsPlaying(false);
            return totalDurationSec;
          }
          return prev + 1;
        });
      }, 1000 / playbackSpeed);
    }
    return () => clearInterval(interval);
  }, [isPlaying, playbackSpeed]);

  if (!isOpen) return null;

  const currentMin = Math.floor(progressSec / 60);
  const currentSec = (progressSec % 60).toString().padStart(2, '0');
  const progressPercent = (progressSec / totalDurationSec) * 100;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/85 backdrop-blur-md p-4 animate-in fade-in duration-150">
      <div className="w-full max-w-3xl bg-zinc-900 border border-zinc-800 rounded-3xl shadow-2xl overflow-hidden flex flex-col max-h-[90vh]">
        {/* Header */}
        <div className="flex items-center justify-between px-6 py-4 border-b border-zinc-800 bg-zinc-900/80">
          <div className="flex items-center gap-2.5">
            <div className="w-9 h-9 rounded-xl bg-gradient-to-tr from-amber-500/20 to-orange-500/20 border border-amber-500/30 flex items-center justify-center text-amber-400 shadow-sm">
              <Headphones size={18} />
            </div>
            <div>
              <div className="flex items-center gap-2">
                <h2 className="text-sm font-semibold text-white">
                  Relatório Semanal de Você em Áudio
                </h2>
                <span className="text-[10px] px-2 py-0.5 rounded-full bg-amber-500/20 text-amber-300 font-mono font-semibold">
                  Toda Sexta às 17h
                </span>
              </div>
              <p className="text-[11px] text-zinc-400">
                {briefing.weekLabel} • Narrado na voz de {briefing.audioNarratorVoice}
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

        {/* Content Body */}
        <div className="p-6 space-y-5 overflow-y-auto flex-1">
          {/* Main Audio Player Card */}
          <div className="p-5 rounded-2xl bg-gradient-to-br from-zinc-950 via-zinc-900 to-amber-950/20 border border-amber-500/30 shadow-xl space-y-4">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-2">
                <Flame size={16} className="text-amber-400 animate-pulse" />
                <span className="text-xs font-bold text-white tracking-wide uppercase">
                  Podcast Pessoal Semanal
                </span>
              </div>
              <div className="flex items-center gap-2">
                <span className="text-[10px] text-zinc-400 font-mono">Velocidade:</span>
                {[1.0, 1.25, 1.5].map((speed) => (
                  <button
                    key={speed}
                    onClick={() => setPlaybackSpeed(speed)}
                    className={`text-[10px] px-2 py-0.5 rounded font-mono font-semibold transition-colors cursor-pointer ${
                      playbackSpeed === speed
                        ? 'bg-amber-500 text-zinc-950'
                        : 'bg-zinc-800 text-zinc-400 hover:text-white'
                    }`}
                  >
                    {speed}x
                  </button>
                ))}
              </div>
            </div>

            {/* Play Button + Animated Waveform */}
            <div className="flex items-center gap-4">
              <button
                onClick={togglePlay}
                className="w-12 h-12 rounded-2xl bg-gradient-to-tr from-amber-500 to-orange-500 hover:from-amber-400 hover:to-orange-400 text-zinc-950 flex items-center justify-center shadow-lg shadow-amber-500/25 transition-transform active:scale-95 cursor-pointer shrink-0"
                title={isPlaying ? 'Pausar áudio' : 'Ouvir relatório falado'}
              >
                {isPlaying ? <Pause size={20} className="fill-current" /> : <Play size={20} className="fill-current ml-0.5" />}
              </button>

              <div className="flex-1 space-y-2">
                {/* Waveform Visualization Bars */}
                <div className="flex items-center gap-1 h-8 px-2 bg-zinc-950/60 rounded-xl border border-zinc-800/80">
                  {Array.from({ length: 32 }).map((_, i) => {
                    const heightPercent = isPlaying
                      ? 20 + Math.abs(Math.sin((i + progressSec * 3) * 0.4)) * 75
                      : (i % 4 + 1) * 15;
                    return (
                      <div
                        key={i}
                        className={`flex-1 rounded-full transition-all duration-150 ${
                          isPlaying ? 'bg-amber-400' : 'bg-zinc-700'
                        }`}
                        style={{ height: `${heightPercent}%` }}
                      />
                    );
                  })}
                </div>

                {/* Progress bar */}
                <div className="space-y-1">
                  <div className="w-full h-1.5 bg-zinc-800 rounded-full overflow-hidden">
                    <div
                      className="bg-amber-400 h-full transition-all duration-300"
                      style={{ width: `${progressPercent}%` }}
                    />
                  </div>
                  <div className="flex justify-between items-center text-[10px] font-mono text-zinc-400">
                    <span>
                      {currentMin}:{currentSec}
                    </span>
                    <span className="text-zinc-500">{briefing.durationFormatted}</span>
                  </div>
                </div>
              </div>
            </div>
          </div>

          {/* Section 1: Weekly Achievements */}
          <div className="p-4 rounded-2xl bg-zinc-950/60 border border-zinc-800 space-y-2.5">
            <div className="flex items-center gap-2 text-xs font-semibold text-amber-300">
              <Trophy size={14} className="text-amber-400" />
              <span>Conquistas & Vitórias da Semana</span>
            </div>
            <div className="space-y-1.5">
              {briefing.achievements.map((ach, idx) => (
                <div
                  key={idx}
                  className="flex items-start gap-2 p-2.5 rounded-xl bg-zinc-900 border border-zinc-800/80 text-xs text-zinc-200"
                >
                  <CheckCircle2 size={13} className="text-emerald-400 shrink-0 mt-0.5" />
                  <span className="leading-relaxed">{ach}</span>
                </div>
              ))}
            </div>
          </div>

          {/* Section 2: Patterns & Rhythm */}
          <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
            <div className="p-4 rounded-2xl bg-zinc-950/60 border border-zinc-800 space-y-2">
              <div className="flex items-center gap-2 text-xs font-semibold text-cyan-300">
                <Activity size={14} className="text-cyan-400" />
                <span>Padrões de Comunicação</span>
              </div>
              <div className="text-xs text-zinc-300 space-y-1 font-mono">
                <div>• Talk Ratio Médio: <strong className="text-white">{briefing.patternsAndRhythm.talkRatioAvg}%</strong> (Escuta ativa +14%)</div>
                <div>• Total de Reuniões: <strong className="text-white">{briefing.patternsAndRhythm.totalCalls} calls</strong></div>
                <div>• Tempo Gravado: <strong className="text-white">{briefing.patternsAndRhythm.hoursRecorded} horas</strong></div>
              </div>
              <p className="text-[11px] text-zinc-400 pt-1 border-t border-zinc-800/60">
                ⚡ {briefing.patternsAndRhythm.pacingAssessment}
              </p>
            </div>

            {/* Section 3: Areas to Improve */}
            <div className="p-4 rounded-2xl bg-zinc-950/60 border border-zinc-800 space-y-2">
              <div className="flex items-center gap-2 text-xs font-semibold text-rose-300">
                <AlertTriangle size={14} className="text-rose-400" />
                <span>O que Calibrar / Melhorar</span>
              </div>
              <div className="space-y-1 text-xs text-zinc-300 leading-relaxed font-sans">
                {briefing.areasToImprove.map((area, idx) => (
                  <p key={idx} className="p-2 rounded-xl bg-rose-950/15 border border-rose-500/20 text-rose-200 text-[11px]">
                    {area}
                  </p>
                ))}
              </div>
            </div>
          </div>

          {/* Section 4: Next Week Priorities */}
          <div className="p-4 rounded-2xl bg-zinc-950/60 border border-zinc-800 space-y-2.5">
            <div className="flex items-center gap-2 text-xs font-semibold text-indigo-300">
              <Calendar size={14} className="text-indigo-400" />
              <span>Compromissos Críticos da Próxima Semana</span>
            </div>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-2">
              {briefing.nextWeekPriorities.map((item, idx) => (
                <div
                  key={idx}
                  className="p-3 rounded-xl bg-zinc-900 border border-zinc-800 flex flex-col justify-between"
                >
                  <div className="text-xs font-medium text-white">{item.title}</div>
                  <div className="flex items-center justify-between text-[10px] text-zinc-400 font-mono mt-2 pt-1 border-t border-zinc-800/60">
                    <span className="text-indigo-300">📅 {item.dayTime}</span>
                    <span className="truncate max-w-[130px]">{item.contactOrContext}</span>
                  </div>
                </div>
              ))}
            </div>
          </div>
        </div>

        {/* Footer */}
        <div className="flex items-center justify-between px-6 py-4 border-t border-zinc-800 bg-zinc-900/80">
          <div className="flex items-center gap-2 text-xs text-zinc-400">
            <Sparkles size={14} className="text-amber-400" />
            <span>Gerado automaticamente toda sexta-feira às 17:00</span>
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
