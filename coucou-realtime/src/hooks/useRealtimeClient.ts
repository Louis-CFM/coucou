import { useState, useRef, useCallback, useEffect } from 'react';
import { RealtimeClient } from '../services/realtimeApi';
import { Agent, AssistantStatus, ToolConfirmationRequest } from '../types';
import { storage } from '../services/storage';

export function useRealtimeClient(agent: Agent | null) {
  const [status, setStatus] = useState<AssistantStatus>('idle');
  const [connectionState, setConnectionState] = useState<'connected' | 'connecting' | 'disconnected' | 'error'>('disconnected');
  const [userTranscript, setUserTranscript] = useState('');
  const [agentTranscript, setAgentTranscript] = useState('');
  const [history, setHistory] = useState<{ id: string; speaker: string; text: string; time: string }[]>([]);
  const [pendingConfirmation, setPendingConfirmation] = useState<ToolConfirmationRequest | null>(null);

  const clientRef = useRef<RealtimeClient | null>(null);

  useEffect(() => {
    const client = new RealtimeClient({
      onStatusChange: (conn) => {
        setConnectionState(conn);
        if (conn === 'connected') setStatus('listening');
        else if (conn === 'disconnected') setStatus('idle');
      },
      onUserTranscript: (text, isFinal) => {
        setUserTranscript(text);
        if (isFinal) {
          setStatus('analyzing');
          setHistory((prev) => [
            ...prev,
            { id: Math.random().toString(), speaker: 'user', text, time: new Date().toLocaleTimeString() },
          ]);
        }
      },
      onAgentTranscript: (text, isFinal) => {
        setAgentTranscript((prev) => (isFinal ? text : prev + text));
        setStatus('speaking');
        if (isFinal) {
          setHistory((prev) => [
            ...prev,
            { id: Math.random().toString(), speaker: 'agent', text, time: new Date().toLocaleTimeString() },
          ]);
          setTimeout(() => setStatus('listening'), 800);
        }
      },
      onFunctionCall: (name, callId, args) => {
        setStatus('executing');
        // Check if tool requires user confirmation
        setPendingConfirmation({
          id: callId,
          toolId: callId,
          toolName: name === 'send_webhook' ? 'Webhook CRM' : 'Disparo de E-mail',
          toolType: name === 'send_webhook' ? 'webhook' : 'smtp',
          parameters: args,
          summary: args.summary || `Execução da ferramenta ${name}`,
        });
      },
      onError: (err) => {
        console.error('Erro no cliente Realtime:', err);
      },
    });

    clientRef.current = client;

    return () => {
      client.disconnect();
    };
  }, []);

  const connect = useCallback(async (screenContext?: string) => {
    if (!agent || !clientRef.current) return;
    const apiKey = storage.getApiKey();
    await clientRef.current.connect(apiKey, agent, screenContext);
  }, [agent]);

  const disconnect = useCallback(() => {
    clientRef.current?.disconnect();
    setStatus('idle');
  }, []);

  const sendAudioChunk = useCallback((base64: string) => {
    clientRef.current?.appendAudioChunk(base64);
  }, []);

  const interrupt = useCallback(() => {
    clientRef.current?.interrupt();
  }, []);

  return {
    status,
    connectionState,
    userTranscript,
    agentTranscript,
    history,
    pendingConfirmation,
    setPendingConfirmation,
    connect,
    disconnect,
    sendAudioChunk,
    interrupt,
  };
}
