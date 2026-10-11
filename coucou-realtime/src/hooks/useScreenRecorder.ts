import { useState, useRef, useCallback } from 'react';

export interface ScreenRecording {
  id: string;
  blob: Blob;
  url: string;
  durationMs: number;
  timestamp: string;
  name: string;
}

export function useScreenRecorder() {
  const [isRecording, setIsRecording] = useState(false);
  const [isPaused, setIsPaused] = useState(false);
  const [recordedTimeSec, setRecordedTimeSec] = useState(0);
  const [lastRecording, setLastRecording] = useState<ScreenRecording | null>(null);

  const mediaRecorderRef = useRef<MediaRecorder | null>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const chunksRef = useRef<Blob[]>([]);
  const timerRef = useRef<any>(null);
  const startTimeRef = useRef<number>(0);

  const startRecording = useCallback(async (includeMic = true) => {
    try {
      // 1. Get screen stream with system loopback audio
      const displayStream = await navigator.mediaDevices.getDisplayMedia({
        video: {
          displaySurface: 'monitor',
          frameRate: { ideal: 30, max: 60 },
        },
        audio: true, // Captures Windows system audio / meeting sound
      });

      let finalStream = displayStream;

      // 2. Optionally combine with user's microphone
      if (includeMic) {
        try {
          const micStream = await navigator.mediaDevices.getUserMedia({
            audio: { echoCancellation: true, noiseSuppression: true },
          });

          const AudioCtx = window.AudioContext || (window as any).webkitAudioContext;
          const ctx = new AudioCtx();
          const dest = ctx.createMediaStreamDestination();

          // Add display audio if available
          if (displayStream.getAudioTracks().length > 0) {
            const displayAudioSource = ctx.createMediaStreamSource(displayStream);
            displayAudioSource.connect(dest);
          }

          // Add mic audio
          const micSource = ctx.createMediaStreamSource(micStream);
          micSource.connect(dest);

          // Combine video track with combined audio
          finalStream = new MediaStream([
            ...displayStream.getVideoTracks(),
            ...dest.stream.getAudioTracks(),
          ]);
        } catch (e) {
          console.warn('Microfone não anexado ao vídeo, prosseguindo com áudio da tela:', e);
        }
      }

      streamRef.current = displayStream;
      chunksRef.current = [];

      const mimeType = MediaRecorder.isTypeSupported('video/webm;codecs=vp9,opus')
        ? 'video/webm;codecs=vp9,opus'
        : 'video/webm';

      const recorder = new MediaRecorder(finalStream, { mimeType });
      mediaRecorderRef.current = recorder;

      recorder.ondataavailable = (e) => {
        if (e.data && e.data.size > 0) {
          chunksRef.current.push(e.data);
        }
      };

      recorder.onstop = () => {
        const blob = new Blob(chunksRef.current, { type: mimeType });
        const url = URL.createObjectURL(blob);
        const durationMs = Date.now() - startTimeRef.current;
        const now = new Date();
        const recordingItem: ScreenRecording = {
          id: `rec-${Date.now()}`,
          blob,
          url,
          durationMs,
          timestamp: now.toLocaleTimeString(),
          name: `Gravacao_Coucou_${now.getFullYear()}${(now.getMonth() + 1).toString().padStart(2, '0')}${now.getDate().toString().padStart(2, '0')}_${now.getHours().toString().padStart(2, '0')}${now.getMinutes().toString().padStart(2, '0')}.webm`,
        };

        setLastRecording(recordingItem);
        setIsRecording(false);
        setIsPaused(false);
        setRecordedTimeSec(0);

        // Stop all tracks
        displayStream.getTracks().forEach((t) => t.stop());
      };

      // Handle user pressing browser's native "Stop sharing" button
      displayStream.getVideoTracks()[0].onended = () => {
        if (mediaRecorderRef.current && mediaRecorderRef.current.state !== 'inactive') {
          mediaRecorderRef.current.stop();
        }
      };

      recorder.start(1000); // 1-second chunks
      startTimeRef.current = Date.now();
      setIsRecording(true);
      setIsPaused(false);
      setRecordedTimeSec(0);

      if (timerRef.current) clearInterval(timerRef.current);
      timerRef.current = setInterval(() => {
        setRecordedTimeSec((prev) => prev + 1);
      }, 1000);
    } catch (err) {
      console.error('Falha ao iniciar gravação de tela:', err);
      setIsRecording(false);
    }
  }, []);

  const pauseRecording = useCallback(() => {
    if (mediaRecorderRef.current && mediaRecorderRef.current.state === 'recording') {
      mediaRecorderRef.current.pause();
      setIsPaused(true);
      if (timerRef.current) clearInterval(timerRef.current);
    }
  }, []);

  const resumeRecording = useCallback(() => {
    if (mediaRecorderRef.current && mediaRecorderRef.current.state === 'paused') {
      mediaRecorderRef.current.resume();
      setIsPaused(false);
      timerRef.current = setInterval(() => {
        setRecordedTimeSec((prev) => prev + 1);
      }, 1000);
    }
  }, []);

  const stopRecording = useCallback(() => {
    if (timerRef.current) {
      clearInterval(timerRef.current);
      timerRef.current = null;
    }
    if (mediaRecorderRef.current && mediaRecorderRef.current.state !== 'inactive') {
      mediaRecorderRef.current.stop();
    }
  }, []);

  const downloadRecording = useCallback((recording: ScreenRecording) => {
    const a = document.createElement('a');
    a.href = recording.url;
    a.download = recording.name;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
  }, []);

  return {
    isRecording,
    isPaused,
    recordedTimeSec,
    lastRecording,
    startRecording,
    pauseRecording,
    resumeRecording,
    stopRecording,
    downloadRecording,
    clearLastRecording: () => setLastRecording(null),
  };
}
