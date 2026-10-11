import React from 'react';
import { Mic, MicOff, Maximize2, Scan, Sparkles } from 'lucide-react';
import { WaveformVisualizer } from './WaveformVisualizer';
import { AssistantStatus, Agent } from '../../types';
import { storage } from '../../services/storage';

interface FloatingPillProps {
  status: AssistantStatus;
  audioLevel: number;
  activeAgent: Agent | null;
  isMuted: boolean;
  onToggleMute: () => void;
  onCaptureScreen: () => void;
  onOpenMainWindow: () => void;
}

export const FloatingPill: React.FC<FloatingPillProps> = ({
  status,
  audioLevel,
  activeAgent,
  isMuted,
  onToggleMute,
  onCaptureScreen,
  onOpenMainWindow,
}) => {
  const getStatusLabel = () => {
    if (isMuted) return 'Silenciado';
    switch (status) {
      case 'listening':
        return 'Ouvindo...';
      case 'analyzing':
        return 'Analisando...';
      case 'speaking':
        return 'Falando...';
      case 'executing':
        return 'Executando Ação';
      default:
        return 'Coucou Pronto';
    }
  };

  const getStatusDotColor = () => {
    if (isMuted) return '#ef4444';
    switch (status) {
      case 'listening':
        return '#10b981';
      case 'analyzing':
        return '#f59e0b';
      case 'speaking':
        return '#6366f1';
      case 'executing':
        return '#ec4899';
      default:
        return '#71717a';
    }
  };

  return (
    <div
      data-tauri-drag-region
      style={{
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        width: '100%',
        height: '48px',
        padding: '0 12px',
        borderRadius: '24px',
        background: 'rgba(15, 15, 18, 0.92)',
        backdropFilter: 'blur(20px)',
        border: '1px solid rgba(255, 255, 255, 0.12)',
        boxShadow: '0 8px 32px rgba(0, 0, 0, 0.5)',
        cursor: 'grab',
        userSelect: 'none',
        boxSizing: 'border-box',
      }}
    >
      {/* Left: Agent & Status */}
      <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
        <div
          style={{
            width: '28px',
            height: '28px',
            borderRadius: '50%',
            background: 'linear-gradient(135deg, #6366f1, #a855f7)',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            boxShadow: '0 0 10px rgba(99, 102, 241, 0.4)',
          }}
        >
          <Sparkles size={14} color="#ffffff" />
        </div>

        <div style={{ display: 'flex', flexDirection: 'column' }}>
          <span style={{ fontSize: '11px', fontWeight: 600, color: '#f4f4f5', lineHeight: 1.2 }}>
            {activeAgent?.name || 'Coucou Realtime'}
          </span>
          <div style={{ display: 'flex', alignItems: 'center', gap: '5px' }}>
            <span
              style={{
                width: '6px',
                height: '6px',
                borderRadius: '50%',
                backgroundColor: getStatusDotColor(),
                boxShadow: `0 0 6px ${getStatusDotColor()}`,
              }}
            />
            <span style={{ fontSize: '10px', color: '#a1a1aa' }}>{getStatusLabel()}</span>
          </div>
        </div>
      </div>

      {/* Center: Live Waveform */}
      <div style={{ padding: '0 8px' }}>
        <WaveformVisualizer level={audioLevel} status={isMuted ? 'muted' : status} barCount={10} />
      </div>

      {/* Right: Quick Action Buttons */}
      <div style={{ display: 'flex', alignItems: 'center', gap: '4px' }}>
        <button
          onClick={onToggleMute}
          title={isMuted ? 'Ativar Microfone (Alt+M)' : 'Silenciar (Alt+M)'}
          style={{
            background: isMuted ? 'rgba(239, 68, 68, 0.2)' : 'rgba(255, 255, 255, 0.06)',
            border: `1px solid ${isMuted ? 'rgba(239, 68, 68, 0.4)' : 'rgba(255, 255, 255, 0.1)'}`,
            borderRadius: '50%',
            width: '28px',
            height: '28px',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            cursor: 'pointer',
            color: isMuted ? '#ef4444' : '#d4d4d8',
            transition: 'all 0.15s ease',
          }}
        >
          {isMuted ? <MicOff size={13} /> : <Mic size={13} />}
        </button>

        <button
          onClick={onCaptureScreen}
          title="Capturar Contexto da Tela (Alt+S)"
          style={{
            background: 'rgba(255, 255, 255, 0.06)',
            border: '1px solid rgba(255, 255, 255, 0.1)',
            borderRadius: '50%',
            width: '28px',
            height: '28px',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            cursor: 'pointer',
            color: '#d4d4d8',
            transition: 'all 0.15s ease',
          }}
        >
          <Scan size={13} />
        </button>

        <button
          onClick={onOpenMainWindow}
          title="Abrir Painel Completo (Alt+Space)"
          style={{
            background: 'rgba(99, 102, 241, 0.2)',
            border: '1px solid rgba(99, 102, 241, 0.4)',
            borderRadius: '50%',
            width: '28px',
            height: '28px',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            cursor: 'pointer',
            color: '#818cf8',
            transition: 'all 0.15s ease',
          }}
        >
          <Maximize2 size={13} />
        </button>
      </div>
    </div>
  );
};
