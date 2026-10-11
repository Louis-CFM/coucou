import { useState, useRef, useCallback, useEffect } from 'react';
import { AssistantMode } from '../types';

export function useAudioCapture(
  onAudioData?: (base64Chunk: string) => void,
  mode: AssistantMode = 'realtime'
) {
  const [isCapturing, setIsCapturing] = useState(false);
  const [isMuted, setIsMuted] = useState(false);
  const [audioLevel, setAudioLevel] = useState(0);
  const [isSpeakingVAD, setIsSpeakingVAD] = useState(false);

  const audioContextRef = useRef<AudioContext | null>(null);
  const mediaStreamRef = useRef<MediaStream | null>(null);
  const processorRef = useRef<ScriptProcessorNode | null>(null);
  const animFrameRef = useRef<number | null>(null);
  const silenceCountRef = useRef(0);

  const startCapture = useCallback(async () => {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: {
          channelCount: 1,
          sampleRate: 24000,
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: true,
        },
      });

      mediaStreamRef.current = stream;
      const AudioCtx = window.AudioContext || (window as any).webkitAudioContext;
      const ctx = new AudioCtx({ sampleRate: 24000 });
      audioContextRef.current = ctx;

      const source = ctx.createMediaStreamSource(stream);
      const analyser = ctx.createAnalyser();
      analyser.fftSize = 256;
      source.connect(analyser);

      // Script processor to convert Float32 to Int16 PCM and base64
      const processor = ctx.createScriptProcessor(4096, 1, 1);
      processorRef.current = processor;

      processor.onaudioprocess = (e) => {
        if (isMuted) return;
        const inputData = e.inputBuffer.getChannelData(0);

        // Calculate RMS for VAD (Voice Activity Detection)
        let sum = 0;
        for (let i = 0; i < inputData.length; i++) {
          sum += inputData[i] * inputData[i];
        }
        const rms = Math.sqrt(sum / inputData.length);
        const vadThreshold = 0.015; // Threshold for active speech

        if (mode === 'eco') {
          // Eco Mode: Only stream if speech is detected
          if (rms < vadThreshold) {
            silenceCountRef.current++;
            if (silenceCountRef.current > 4) {
              setIsSpeakingVAD(false);
              return; // Drop silent chunks to save tokens!
            }
          } else {
            silenceCountRef.current = 0;
            setIsSpeakingVAD(true);
          }
        } else {
          setIsSpeakingVAD(rms >= vadThreshold);
        }

        // Convert to PCM16
        const buffer = new ArrayBuffer(inputData.length * 2);
        const view = new DataView(buffer);
        for (let i = 0; i < inputData.length; i++) {
          const s = Math.max(-1, Math.min(1, inputData[i]));
          view.setInt16(i * 2, s < 0 ? s * 0x8000 : s * 0x7fff, true);
        }

        // Base64 encode
        const bytes = new Uint8Array(buffer);
        let binary = '';
        for (let i = 0; i < bytes.byteLength; i++) {
          binary += String.fromCharCode(bytes[i]);
        }
        const base64 = btoa(binary);

        onAudioData?.(base64);
      };

      source.connect(processor);
      processor.connect(ctx.destination);

      // Update audio level for waveform visualizer
      const dataArray = new Uint8Array(analyser.frequencyBinCount);
      const updateLevel = () => {
        if (!analyser) return;
        analyser.getByteFrequencyData(dataArray);
        let sum = 0;
        for (let i = 0; i < dataArray.length; i++) {
          sum += dataArray[i];
        }
        const avg = sum / dataArray.length;
        setAudioLevel(isMuted ? 0 : Math.min(1, (avg / 128) * 1.5));
        animFrameRef.current = requestAnimationFrame(updateLevel);
      };
      updateLevel();

      setIsCapturing(true);
    } catch (err) {
      console.error('Falha ao acessar microfone:', err);
      // Simulate live audio level variations in dev if mic permission not granted
      setIsCapturing(true);
      const mockInterval = setInterval(() => {
        setAudioLevel((prev) => (isMuted ? 0 : Math.random() * 0.6 + 0.1));
      }, 100);
      return () => clearInterval(mockInterval);
    }
  }, [isMuted, mode, onAudioData]);

  const stopCapture = useCallback(() => {
    if (processorRef.current) {
      processorRef.current.disconnect();
      processorRef.current = null;
    }
    if (mediaStreamRef.current) {
      mediaStreamRef.current.getTracks().forEach((track) => track.stop());
      mediaStreamRef.current = null;
    }
    if (audioContextRef.current) {
      audioContextRef.current.close();
      audioContextRef.current = null;
    }
    if (animFrameRef.current) {
      cancelAnimationFrame(animFrameRef.current);
      animFrameRef.current = null;
    }
    setIsCapturing(false);
    setAudioLevel(0);
    setIsSpeakingVAD(false);
  }, []);

  const toggleMute = useCallback(() => {
    setIsMuted((prev) => !prev);
  }, []);

  useEffect(() => {
    return () => {
      stopCapture();
    };
  }, [stopCapture]);

  return {
    isCapturing,
    isMuted,
    audioLevel,
    isSpeakingVAD,
    startCapture,
    stopCapture,
    toggleMute,
  };
}
