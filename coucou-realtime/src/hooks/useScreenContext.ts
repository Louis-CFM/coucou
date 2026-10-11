import { useState, useCallback } from 'react';
import { storage } from '../services/storage';
import { OcrResult } from '../types';

export function useScreenContext() {
  const [isCapturing, setIsCapturing] = useState(false);
  const [screenContext, setScreenContext] = useState<OcrResult | null>(null);

  const captureNow = useCallback(async () => {
    setIsCapturing(true);
    try {
      const result = await storage.captureScreenContext();
      setScreenContext(result);
      return result;
    } catch (err) {
      console.error('Falha ao capturar contexto da tela:', err);
      return null;
    } finally {
      setIsCapturing(false);
    }
  }, []);

  const clearScreenContext = useCallback(() => {
    setScreenContext(null);
  }, []);

  return {
    isCapturing,
    isScanning: isCapturing,
    screenContext,
    captureNow,
    clearScreenContext,
  };
}
