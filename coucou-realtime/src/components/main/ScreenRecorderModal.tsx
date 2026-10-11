import React from 'react';
import { X, Video, Download, Play, Sparkles, Check, Trash2, Clock } from 'lucide-react';
import { ScreenRecording } from '../../hooks/useScreenRecorder';

interface ScreenRecorderModalProps {
  recording: ScreenRecording | null;
  onClose: () => void;
  onDownload: (recording: ScreenRecording) => void;
  onAnalyzeWithAi: (recording: ScreenRecording) => void;
}

export const ScreenRecorderModal: React.FC<ScreenRecorderModalProps> = ({
  recording,
  onClose,
  onDownload,
  onAnalyzeWithAi,
}) => {
  if (!recording) return null;

  const formatTime = (ms: number) => {
    const sec = Math.floor(ms / 1000);
    const m = Math.floor(sec / 60);
    const s = sec % 60;
    return `${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}`;
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/80 backdrop-blur-md p-4 animate-in fade-in duration-150">
      <div className="w-full max-w-2xl bg-zinc-900 border border-zinc-800 rounded-2xl shadow-2xl overflow-hidden flex flex-col">
        {/* Header */}
        <div className="flex items-center justify-between px-6 py-4 border-b border-zinc-800 bg-zinc-900/80">
          <div className="flex items-center gap-2.5">
            <div className="w-8 h-8 rounded-lg bg-rose-500/10 border border-rose-500/20 flex items-center justify-center text-rose-400">
              <Video size={16} />
            </div>
            <div>
              <h2 className="text-sm font-semibold text-white">Gravação de Tela Concluída</h2>
              <p className="text-[11px] text-zinc-400">
                {recording.name} • Duração: {formatTime(recording.durationMs)}
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

        {/* Video Player Preview */}
        <div className="p-6 space-y-4">
          <div className="relative rounded-xl overflow-hidden bg-black border border-zinc-800 shadow-inner aspect-video flex items-center justify-center">
            <video
              src={recording.url}
              controls
              className="w-full h-full object-contain"
              autoPlay={false}
            />
          </div>

          <div className="p-3.5 rounded-xl bg-zinc-950/60 border border-zinc-800/80 flex items-center justify-between text-xs text-zinc-300">
            <div className="flex items-center gap-2">
              <Clock size={14} className="text-indigo-400" />
              <span>Gravado às {recording.timestamp} com áudio do sistema e microfone.</span>
            </div>
            <span className="font-mono text-zinc-400">
              {(recording.blob.size / (1024 * 1024)).toFixed(2)} MB
            </span>
          </div>
        </div>

        {/* Footer Actions */}
        <div className="flex items-center justify-between px-6 py-4 border-t border-zinc-800 bg-zinc-900/80">
          <button
            onClick={onClose}
            className="px-4 py-2 text-xs font-medium text-zinc-400 hover:text-white transition-colors cursor-pointer"
          >
            Descartar
          </button>

          <div className="flex items-center gap-2.5">
            <button
              onClick={() => onDownload(recording)}
              className="flex items-center gap-1.5 px-4 py-2 rounded-xl bg-zinc-800 hover:bg-zinc-750 text-white text-xs font-semibold border border-zinc-700 transition-all cursor-pointer"
            >
              <Download size={14} />
              <span>Baixar Vídeo (.webm)</span>
            </button>

            <button
              onClick={() => onAnalyzeWithAi(recording)}
              className="flex items-center gap-1.5 px-5 py-2 rounded-xl bg-indigo-600 hover:bg-indigo-500 text-white text-xs font-semibold shadow-md shadow-indigo-600/30 transition-all cursor-pointer"
            >
              <Sparkles size={14} />
              <span>Gerar Ata & Resumo com IA</span>
            </button>
          </div>
        </div>
      </div>
    </div>
  );
};
