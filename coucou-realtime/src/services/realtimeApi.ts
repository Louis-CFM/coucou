import { Agent } from '../types';

export interface RealtimeCallbacks {
  onStatusChange?: (status: 'connected' | 'connecting' | 'disconnected' | 'error') => void;
  onUserTranscript?: (text: string, isFinal: boolean) => void;
  onAgentTranscript?: (text: string, isFinal: boolean) => void;
  onAudioLevel?: (level: number) => void;
  onFunctionCall?: (name: string, callId: string, args: any) => void;
  onError?: (err: string) => void;
}

export class RealtimeClient {
  private ws: WebSocket | null = null;
  private audioContext: AudioContext | null = null;
  private audioQueue: Float32Array[] = [];
  private isPlaying = false;
  private currentSource: AudioBufferSourceNode | null = null;
  private callbacks: RealtimeCallbacks = {};
  private activeAgent: Agent | null = null;
  private mockInterval: any = null;

  constructor(callbacks: RealtimeCallbacks = {}) {
    this.callbacks = callbacks;
  }

  setCallbacks(callbacks: RealtimeCallbacks) {
    this.callbacks = { ...this.callbacks, ...callbacks };
  }

  async connect(apiKey: string, agent: Agent, screenContext?: string): Promise<void> {
    this.activeAgent = agent;
    this.callbacks.onStatusChange?.('connecting');

    if (!apiKey) {
      console.warn('Nenhuma chave OpenAI fornecida. Iniciando em Modo Demonstração Realtime.');
      this.startMockSession();
      return;
    }

    try {
      const isGemini = apiKey.startsWith('AIza');
      const url = isGemini
        ? `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent?key=${apiKey}`
        : 'wss://api.openai.com/v1/realtime?model=gpt-4o-realtime-preview-2024-10-01';

      const protocols = isGemini
        ? undefined
        : [
            'realtime',
            'openai-insecure-api-key.' + apiKey,
            'openai-beta.realtime-v1',
          ];

      this.ws = protocols ? new WebSocket(url, protocols) : new WebSocket(url);

      this.ws.onopen = () => {
        this.callbacks.onStatusChange?.('connected');
        if (isGemini) {
          this.sendGeminiSetup(agent, screenContext);
        } else {
          this.sendSessionUpdate(agent, screenContext);
        }
      };

      this.ws.onmessage = (event) => {
        try {
          const data = JSON.parse(event.data);
          if (isGemini) {
            this.handleGeminiServerEvent(data);
          } else {
            this.handleServerEvent(data);
          }
        } catch (e) {
          console.error('Erro ao processar mensagem do Realtime:', e);
        }
      };

      this.ws.onerror = (e) => {
        console.error('Erro de conexão com WebSocket do Realtime:', e);
        this.callbacks.onError?.('Falha ao conectar com o provedor de IA Realtime.');
        this.callbacks.onStatusChange?.('error');
      };

      this.ws.onclose = () => {
        this.callbacks.onStatusChange?.('disconnected');
      };

      // Init Web Audio context for agent voice playback
      const AudioCtx = window.AudioContext || (window as any).webkitAudioContext;
      this.audioContext = new AudioCtx({ sampleRate: 24000 });
    } catch (err: any) {
      this.callbacks.onError?.(err?.message || 'Erro ao inicializar cliente Realtime');
      this.callbacks.onStatusChange?.('error');
    }
  }

  private sendSessionUpdate(agent: Agent, screenContext?: string) {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;

    let instructions = `${agent.system_prompt}\nTom de voz: ${agent.tone}.\nIdioma principal: ${agent.language}.`;
    if (screenContext) {
      instructions += `\nContexto visual da tela ativa no momento:\n${screenContext}`;
    }

    const sessionUpdate = {
      type: 'session.update',
      session: {
        modalities: ['text', 'audio'],
        instructions,
        voice: agent.voice || 'alloy',
        input_audio_format: 'pcm16',
        output_audio_format: 'pcm16',
        input_audio_transcription: {
          model: 'whisper-1',
        },
        turn_detection: {
          type: 'server_vad',
          threshold: 0.5,
          prefix_padding_ms: 300,
          silence_duration_ms: 600,
        },
        tools: [
          {
            type: 'function',
            name: 'send_webhook',
            description: 'Envia dados ou notificações para um webhook externo (CRM, Slack, Zapier)',
            parameters: {
              type: 'object',
              properties: {
                summary: { type: 'string', description: 'Resumo dos dados enviados' },
                payload: { type: 'object', description: 'Dados estruturados' },
              },
              required: ['summary'],
            },
          },
          {
            type: 'function',
            name: 'send_email_summary',
            description: 'Envia ata ou resumo da conversa por e-mail',
            parameters: {
              type: 'object',
              properties: {
                recipient: { type: 'string', description: 'E-mail de destino' },
                subject: { type: 'string', description: 'Assunto do e-mail' },
                content: { type: 'string', description: 'Conteúdo em texto/markdown' },
              },
              required: ['recipient', 'subject', 'content'],
            },
          },
        ],
      },
    };

    this.ws.send(JSON.stringify(sessionUpdate));
  }

  private isGemini = false;

  private sendGeminiSetup(agent: Agent, screenContext?: string) {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;

    let instructions = `${agent.system_prompt}\nTom de voz: ${agent.tone}.\nIdioma principal: ${agent.language}.`;
    if (screenContext) {
      instructions += `\nContexto visual da tela ativa no momento:\n${screenContext}`;
    }

    const geminiVoiceMap: Record<string, string> = {
      alloy: 'Puck',
      echo: 'Charon',
      shimmer: 'Kore',
      ash: 'Fenrir',
      ballad: 'Aoede',
      coral: 'Puck',
      sage: 'Kore',
      verse: 'Aoede',
    };
    const voiceName = geminiVoiceMap[agent.voice] || 'Puck';

    const setupMessage = {
      setup: {
        model: 'models/gemini-flash-latest',
        generationConfig: {
          responseModalities: ['AUDIO'],
          speechConfig: {
            voiceConfig: {
              prebuiltVoiceConfig: {
                voiceName,
              },
            },
          },
        },
        systemInstruction: {
          parts: [{ text: instructions }],
        },
      },
    };

    this.ws.send(JSON.stringify(setupMessage));
  }

  private handleGeminiServerEvent(data: any) {
    if (data.serverContent) {
      if (data.serverContent.interrupted) {
        this.interrupt();
      }

      const parts = data.serverContent.modelTurn?.parts || [];
      for (const part of parts) {
        if (part.text) {
          this.callbacks.onAgentTranscript?.(part.text, false);
        }
        if (part.inlineData && part.inlineData.data) {
          this.playAudioChunkBase64(part.inlineData.data);
        }
      }

      if (data.serverContent.turnComplete) {
        this.callbacks.onAgentTranscript?.('', true);
      }
    }
  }

  appendAudioChunk(base64Pcm16: string) {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      if (this.isGemini) {
        this.ws.send(
          JSON.stringify({
            realtimeInput: {
              mediaChunks: [
                {
                  mimeType: 'audio/pcm;rate=24000',
                  data: base64Pcm16,
                },
              ],
            },
          })
        );
      } else {
        this.ws.send(
          JSON.stringify({
            type: 'input_audio_buffer.append',
            audio: base64Pcm16,
          })
        );
      }
    }
  }

  interrupt() {
    // Barge-in: Clear audio playback immediately when user starts speaking
    this.audioQueue = [];
    if (this.currentSource) {
      try {
        this.currentSource.stop();
      } catch {}
      this.currentSource = null;
    }
    this.isPlaying = false;

    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(
        JSON.stringify({
          type: 'response.cancel',
        })
      );
    }
  }

  private handleServerEvent(event: any) {
    switch (event.type) {
      case 'input_audio_buffer.speech_started':
        // User spoke: trigger barge-in interruption!
        this.interrupt();
        break;

      case 'conversation.item.input_audio_transcription.completed':
        if (event.transcript) {
          this.callbacks.onUserTranscript?.(event.transcript, true);
        }
        break;

      case 'response.audio_transcript.delta':
        if (event.delta) {
          this.callbacks.onAgentTranscript?.(event.delta, false);
        }
        break;

      case 'response.audio_transcript.done':
        if (event.transcript) {
          this.callbacks.onAgentTranscript?.(event.transcript, true);
        }
        break;

      case 'response.audio.delta':
        if (event.delta) {
          this.playAudioChunkBase64(event.delta);
        }
        break;

      case 'response.function_call_arguments.done':
        try {
          const args = JSON.parse(event.arguments);
          this.callbacks.onFunctionCall?.(event.name, event.call_id, args);
        } catch (e) {
          console.error('Erro ao decodificar argumentos da função:', e);
        }
        break;
    }
  }

  private playAudioChunkBase64(base64: string) {
    if (!this.audioContext) return;
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }
    const int16 = new Int16Array(bytes.buffer);
    const float32 = new Float32Array(int16.length);
    for (let i = 0; i < int16.length; i++) {
      float32[i] = int16[i] / 32768.0;
    }

    this.audioQueue.push(float32);
    if (!this.isPlaying) {
      this.playNextInQueue();
    }
  }

  private playNextInQueue() {
    if (!this.audioContext || this.audioQueue.length === 0) {
      this.isPlaying = false;
      return;
    }

    this.isPlaying = true;
    const chunk = this.audioQueue.shift()!;
    const buffer = this.audioContext.createBuffer(1, chunk.length, 24000);
    buffer.copyToChannel(chunk as any, 0);

    const source = this.audioContext.createBufferSource();
    source.buffer = buffer;
    source.connect(this.audioContext.destination);
    this.currentSource = source;

    source.onended = () => {
      this.playNextInQueue();
    };

    source.start();
  }

  // Fallback demo session when running without OpenAI key or offline
  private startMockSession() {
    this.callbacks.onStatusChange?.('connected');
    let step = 0;
    const demoMessages = [
      { speaker: 'user', text: 'Olá! Consegue me ajudar com as objeções da reunião de hoje?' },
      { speaker: 'agent', text: 'Com certeza! Estou pronto para auxiliar. O cliente mencionou preocupação com o prazo de implantação ou com o valor do contrato?' },
      { speaker: 'user', text: 'Eles acharam o prazo de 60 dias muito longo.' },
      { speaker: 'agent', text: 'Sugiro propor uma entrega em duas fases (MVP em 20 dias com funcionalidades críticas e o restante em 40 dias). Isso reduz a percepção de risco imediatamente!' },
    ];

    this.mockInterval = setInterval(() => {
      if (step < demoMessages.length) {
        const item = demoMessages[step];
        if (item.speaker === 'user') {
          this.callbacks.onUserTranscript?.(item.text, true);
        } else {
          this.callbacks.onAgentTranscript?.(item.text, true);
        }
        step++;
      } else {
        clearInterval(this.mockInterval);
      }
    }, 4500);
  }

  disconnect() {
    if (this.mockInterval) clearInterval(this.mockInterval);
    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }
    if (this.audioContext) {
      this.audioContext.close();
      this.audioContext = null;
    }
    this.audioQueue = [];
    this.isPlaying = false;
    this.callbacks.onStatusChange?.('disconnected');
  }
}
