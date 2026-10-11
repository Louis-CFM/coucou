import React, { useEffect } from 'react';
import { FloatingPill } from './FloatingPill';
import { useAudioCapture } from '../../hooks/useAudioCapture';
import { useAgents } from '../../hooks/useAgents';
import { useScreenContext } from '../../hooks/useScreenContext';
import { storage } from '../../services/storage';

export const FloatingBar: React.FC = () => {
  const { activeAgent } = useAgents();
  const { isCapturing, isMuted, audioLevel, startCapture, stopCapture, toggleMute } = useAudioCapture();
  const { captureNow } = useScreenContext();

  useEffect(() => {
    // Start audio capture when pill is active
    startCapture();
    return () => {
      stopCapture();
    };
  }, [startCapture, stopCapture]);

  useEffect(() => {
    // Global keyboard shortcut listeners within window
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.altKey && (e.key === 'm' || e.key === 'M')) {
        e.preventDefault();
        toggleMute();
      }
      if (e.altKey && (e.key === 's' || e.key === 'S')) {
        e.preventDefault();
        captureNow();
      }
      if (e.altKey && e.code === 'Space') {
        e.preventDefault();
        storage.toggleMainWindow();
      }
    };

    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [toggleMute, captureNow]);

  const handleOpenMain = () => {
    storage.toggleMainWindow();
  };

  return (
    <div style={{ padding: '4px', width: '100%', boxSizing: 'border-box' }}>
      <FloatingPill
        status={isMuted ? 'muted' : isCapturing ? 'listening' : 'idle'}
        audioLevel={audioLevel}
        activeAgent={activeAgent}
        isMuted={isMuted}
        onToggleMute={toggleMute}
        onCaptureScreen={captureNow}
        onOpenMainWindow={handleOpenMain}
      />
    </div>
  );
};
