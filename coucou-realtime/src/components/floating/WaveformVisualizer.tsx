import React, { useMemo } from 'react';

interface WaveformVisualizerProps {
  level: number; // 0.0 to 1.0
  status: 'idle' | 'listening' | 'analyzing' | 'speaking' | 'executing' | 'muted';
  barCount?: number;
}

export const WaveformVisualizer: React.FC<WaveformVisualizerProps> = ({
  level,
  status,
  barCount = 12,
}) => {
  const bars = useMemo(() => {
    return Array.from({ length: barCount }, (_, i) => {
      // Create a center-weighted curve
      const centerFactor = 1 - Math.abs(i - (barCount - 1) / 2) / ((barCount - 1) / 2);
      let heightPct = 15;

      if (status === 'muted') {
        heightPct = 8;
      } else if (status === 'listening') {
        const jitter = Math.sin(Date.now() / 200 + i) * 0.2 + 0.8;
        heightPct = Math.max(12, Math.min(100, (level * 80 + 15) * centerFactor * jitter));
      } else if (status === 'speaking') {
        const wave = Math.sin(Date.now() / 150 + i * 0.8) * 0.5 + 0.5;
        heightPct = Math.max(20, Math.min(100, wave * 85 * centerFactor));
      } else if (status === 'analyzing') {
        const pulse = (Math.sin(Date.now() / 250 + i * 0.5) + 1) * 25;
        heightPct = 15 + pulse;
      }

      return heightPct;
    });
  }, [level, status, barCount]);

  const getBarColor = () => {
    switch (status) {
      case 'muted':
        return '#71717a';
      case 'listening':
        return '#10b981'; // Emerald
      case 'speaking':
        return '#6366f1'; // Indigo
      case 'analyzing':
        return '#f59e0b'; // Amber
      case 'executing':
        return '#ec4899'; // Pink
      default:
        return '#52525b';
    }
  };

  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: '3px', height: '24px' }}>
      {bars.map((h, idx) => (
        <div
          key={idx}
          style={{
            width: '3px',
            height: `${h}%`,
            backgroundColor: getBarColor(),
            borderRadius: '9999px',
            transition: 'height 0.08s ease, background-color 0.3s ease',
          }}
        />
      ))}
    </div>
  );
};
