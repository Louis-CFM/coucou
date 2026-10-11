import React from 'react';
import { AssistantMode } from '../../types';
import { Radio, Zap, Leaf } from 'lucide-react';

interface ModeSelectorProps {
  currentMode: AssistantMode;
  onModeChange: (mode: AssistantMode) => void;
  disabled?: boolean;
}

export const ModeSelector: React.FC<ModeSelectorProps> = ({ currentMode, onModeChange, disabled }) => {
  const modes: { id: AssistantMode; label: string; icon: React.ReactNode; desc: string; badge?: string }[] = [
    {
      id: 'realtime',
      label: 'Realtime',
      icon: <Radio size={14} />,
      desc: 'Voz bidirecional direta (OpenAI Realtime API)',
      badge: 'Ultra Baixa Latência',
    },
    {
      id: 'ultra',
      label: 'Ultra',
      icon: <Zap size={14} />,
      desc: 'Captura dupla (Mic + Sistema) + Sugestões táticas contínuas',
      badge: 'Reuniões & Objeções',
    },
    {
      id: 'eco',
      label: 'Eco',
      icon: <Leaf size={14} />,
      desc: 'Transcrição VAD em blocos (Otimização de custos)',
      badge: 'Econômico',
    },
  ];

  return (
    <div className="flex items-center p-1 bg-zinc-950/70 border border-zinc-800/80 rounded-xl backdrop-blur-md shadow-inner">
      {modes.map((mode) => {
        const isActive = currentMode === mode.id;
        return (
          <button
            key={mode.id}
            onClick={() => onModeChange(mode.id)}
            disabled={disabled}
            title={mode.desc}
            className={`flex items-center gap-2 px-3 py-1.5 rounded-lg text-xs font-medium transition-all duration-200 cursor-pointer ${
              isActive
                ? 'bg-zinc-800 text-white shadow-sm border border-zinc-700/60'
                : 'text-zinc-400 hover:text-zinc-200 hover:bg-zinc-900/60'
            } ${disabled ? 'opacity-50 cursor-not-allowed' : ''}`}
          >
            <span className={isActive ? 'text-indigo-400' : 'text-zinc-500'}>
              {mode.icon}
            </span>
            <span>{mode.label}</span>
            {isActive && (
              <span className="hidden md:inline-block text-[9px] px-1.5 py-0.5 rounded-full bg-indigo-500/20 text-indigo-300 font-mono">
                {mode.badge}
              </span>
            )}
          </button>
        );
      })}
    </div>
  );
};
