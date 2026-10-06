import { Bridge } from "./bridge";
import { State } from "./state";
import { Sound } from "./sound";

export function encodeWav(samples: Float32Array, sampleRate = 16000): Uint8Array {
  const buffer = new ArrayBuffer(44 + samples.length * 2);
  const view = new DataView(buffer);

  function writeStr(offset: number, s: string) {
    for (let i = 0; i < s.length; i++) view.setUint8(offset + i, s.charCodeAt(i));
  }

  writeStr(0, "RIFF");
  view.setUint32(4, 36 + samples.length * 2, true);
  writeStr(8, "WAVE");

  writeStr(12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true); // PCM
  view.setUint16(22, 1, true); // mono
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * 2, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);

  writeStr(36, "data");
  view.setUint32(40, samples.length * 2, true);

  let offset = 44;
  for (let i = 0; i < samples.length; i++, offset += 2) {
    const s = Math.max(-1, Math.min(1, samples[i]));
    view.setInt16(offset, s < 0 ? s * 0x8000 : s * 0x7fff, true);
  }

  return new Uint8Array(buffer);
}

export function uint8ToBase64(uint8: Uint8Array): string {
  let binary = "";
  const len = uint8.byteLength;
  for (let i = 0; i < len; i++) {
    binary += String.fromCharCode(uint8[i]);
  }
  return btoa(binary);
}

export function formatEdgeRate(speed = 1.0): string {
  const pct = Math.round((speed - 1.0) * 100);
  return pct >= 0 ? `+${pct}%` : `${pct}%`;
}

export function formatEdgeVolume(volume = 1.0): string {
  const pct = Math.round((volume - 1.0) * 100);
  return pct >= 0 ? `+${pct}%` : `${pct}%`;
}

export function cleanTextForSpeech(raw: string): string {
  return raw
    .replace(/```[\s\S]*?```/g, "")
    .replace(/`([^`]+)`/g, "$1")
    .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
    .replace(/https?:\/\/\S+/g, "")
    .replace(/^[#*>\-+]+\s*/gm, "")
    .replace(/[*_#~|]/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

export function extractConciseSpeech(text: string, mode: "concise" | "full" = "concise"): string {
  const cleaned = cleanTextForSpeech(text);
  if (!cleaned || mode === "full") return cleaned;

  const sentences = cleaned.match(/[^.!?]+[.!?]+(\s|$)/g);
  if (sentences && sentences.length > 0) {
    let result = sentences[0].trim();
    if (sentences.length > 1 && result.length < 120) {
      result += " " + sentences[1].trim();
    }
    if (result.length > 280) {
      result = result.slice(0, 277).replace(/\s+\S*$/, "") + "...";
    }
    return result;
  }

  if (cleaned.length > 200) {
    return cleaned.slice(0, 197).replace(/\s+\S*$/, "") + "...";
  }
  return cleaned;
}

export class VoiceEngine {
  private pcmChunks: Float32Array[] = [];
  private audioContext: AudioContext | null = null;
  private analyser: AnalyserNode | null = null;
  private processor: ScriptProcessorNode | null = null;
  private stream: MediaStream | null = null;
  private vadInterval: number | null = null;
  private silenceTimer: number | null = null;
  private speakingAudio: HTMLAudioElement | null = null;
  private onTranscriptionCallback: ((text: string) => void) | null = null;
  private gainNode: GainNode | null = null;
  private speechRecognition: any = null;
  private onLiveTranscriptCallback: ((text: string, isFinal: boolean) => void) | null = null;
  private onAutoSendCallback: ((text: string) => void) | null = null;
  private autoSendTimer: number | null = null;
  private hasLiveTranscript: boolean = false;

  initWakeWord(onWake: () => void) {
    void Bridge.listenWakeWord(() => {
      if (!State.settings.voiceEnabled) return;
      void Bridge.log("voice wake word triggered, expanding island");
      Sound.play("greet");
      onWake();
      void this.startListening();
    });
  }

  setTranscriptionHandler(fn: (text: string) => void) {
    this.onTranscriptionCallback = fn;
  }

  setLiveTranscriptHandler(fn: (text: string, isFinal: boolean) => void) {
    this.onLiveTranscriptCallback = fn;
  }

  setAutoSendHandler(fn: (text: string) => void) {
    this.onAutoSendCallback = fn;
  }

  cancelAutoSend(): void {
    if (this.autoSendTimer != null) {
      window.clearTimeout(this.autoSendTimer);
      this.autoSendTimer = null;
    }
  }

  async toggleListening() {
    if (State.isVoiceListening) {
      await this.stopListeningAndTranscribe();
    } else {
      await this.startListening();
    }
  }

  async startListening() {
    if (State.isVoiceListening) return;
    State.voiceListeningPrompt = null;
    this.stopSpeaking();

    try {
      const audioConstraints: MediaTrackConstraints = {
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: false,
      };
      if (State.settings.voiceInputDevice && State.settings.voiceInputDevice !== "default") {
        audioConstraints.deviceId = { exact: State.settings.voiceInputDevice };
      }
      this.stream = await navigator.mediaDevices.getUserMedia({ audio: audioConstraints });
      void Bridge.log("voice recording using input device: " + (State.settings.voiceInputDevice || "default"));
      this.pcmChunks = [];
      this.hasLiveTranscript = false;

      this.audioContext = new AudioContext({ sampleRate: 16000 });
      const source = this.audioContext.createMediaStreamSource(this.stream);

      const gainNode = this.audioContext.createGain();
      gainNode.gain.value = State.settings.voiceMicGain || 2.0;
      this.gainNode = gainNode;
      source.connect(gainNode);

      this.analyser = this.audioContext.createAnalyser();
      this.analyser.fftSize = 512;
      gainNode.connect(this.analyser);

      this.processor = this.audioContext.createScriptProcessor(4096, 1, 1);
      this.processor.onaudioprocess = (e) => {
        if (!State.isVoiceListening) return;
        const input = e.inputBuffer.getChannelData(0);
        this.pcmChunks.push(new Float32Array(input));
      };
      gainNode.connect(this.processor);
      this.processor.connect(this.audioContext.destination);

      const SpeechRec = (window as any).SpeechRecognition || (window as any).webkitSpeechRecognition;
      if (SpeechRec) {
        try {
          const recognition = new SpeechRec();
          recognition.continuous = true;
          recognition.interimResults = true;
          recognition.lang = State.settings.voiceLanguage || "id-ID";
          this.hasLiveTranscript = false;

          recognition.onresult = (event: any) => {
            let interimTranscript = "";
            let finalTranscript = "";
            for (let i = event.resultIndex; i < event.results.length; ++i) {
              const transcript = event.results[i][0].transcript;
              if (event.results[i].isFinal) {
                finalTranscript += transcript;
              } else {
                interimTranscript += transcript;
              }
            }
            const fullText = (finalTranscript + interimTranscript).trim();
            const isFinal = Boolean(finalTranscript && !interimTranscript);

            if (fullText) {
              this.hasLiveTranscript = true;
              if (this.onLiveTranscriptCallback) {
                this.onLiveTranscriptCallback(fullText, isFinal);
              }

              if (this.autoSendTimer != null) {
                window.clearTimeout(this.autoSendTimer);
                this.autoSendTimer = null;
              }
              if (this.onAutoSendCallback && fullText.length > 0) {
                this.autoSendTimer = window.setTimeout(() => {
                  if (this.onAutoSendCallback) {
                    this.onAutoSendCallback(fullText);
                  }
                  void this.stopListeningAndTranscribe();
                }, 1500);
              }
            }
          };

          recognition.onerror = (e: any) => {
            const err = e?.error || String(e);
            void Bridge.log("speech recognition error: " + err);
            if (e?.error === "network") {
              State.voiceListeningPrompt = "Listening (Whisper)... Speak and pause to send";
              State.notify();
            }
          };

          recognition.start();
          this.speechRecognition = recognition;
        } catch (e) {
          void Bridge.log("failed to start speech recognition: " + String(e));
        }
      }

      State.isVoiceListening = true;
      State.notify();
      Sound.play("send");
      void Bridge.log("voice listening started");

      this.startVadMonitoring();
    } catch (err) {
      void Bridge.log(`voice microphone access failed: ${String(err)}`);
      State.isVoiceListening = false;
      State.notify();
    }
  }

  private startVadMonitoring() {
    if (!this.analyser) return;
    const buffer = new Uint8Array(this.analyser.fftSize);
    let hasSpoken = false;
    let speechFrameCount = 0;

    this.vadInterval = window.setInterval(() => {
      if (!this.analyser) return;
      // Settings may change while listening: apply the boost live.
      if (this.gainNode) this.gainNode.gain.value = State.settings.voiceMicGain || 2.0;
      this.analyser.getByteTimeDomainData(buffer);

      // RMS on the boosted waveform: linear, so the boost really moves the threshold.
      let sq = 0;
      for (let i = 0; i < buffer.length; i++) {
        const v = (buffer[i] - 128) / 128;
        sq += v * v;
      }
      const rms = Math.sqrt(sq / buffer.length);

      if (rms > 0.02) {
        speechFrameCount++;
        if (speechFrameCount >= 3) hasSpoken = true;
        if (this.silenceTimer != null) {
          window.clearTimeout(this.silenceTimer);
          this.silenceTimer = null;
        }
        if (this.autoSendTimer != null) {
          window.clearTimeout(this.autoSendTimer);
          this.autoSendTimer = null;
        }
      } else {
        speechFrameCount = Math.max(0, speechFrameCount - 1);
        if (hasSpoken && this.silenceTimer == null) {
          const timeoutMs = (State.settings.voiceSilenceTimeout || 1.5) * 1000;
          this.silenceTimer = window.setTimeout(() => {
            void this.stopListeningAndTranscribe();
          }, timeoutMs);
        }
      }
    }, 100);
  }

  async stopListeningAndTranscribe() {
    if (!State.isVoiceListening) return;

    if (this.speechRecognition) {
      try { this.speechRecognition.stop(); } catch {}
      this.speechRecognition = null;
    }
    if (this.autoSendTimer != null) {
      window.clearTimeout(this.autoSendTimer);
      this.autoSendTimer = null;
    }
    if (this.gainNode) {
      this.gainNode.disconnect();
      this.gainNode = null;
    }

    if (this.vadInterval != null) {
      clearInterval(this.vadInterval);
      this.vadInterval = null;
    }
    if (this.silenceTimer != null) {
      clearTimeout(this.silenceTimer);
      this.silenceTimer = null;
    }

    State.isVoiceListening = false;
    State.voiceListeningPrompt = null;
    State.notify();
    void Bridge.log("voice listening stopped, transcribing...");

    if (this.processor) {
      this.processor.disconnect();
      this.processor = null;
    }
    if (this.stream) {
      for (const t of this.stream.getTracks()) t.stop();
      this.stream = null;
    }

    const sampleRate = this.audioContext?.sampleRate || 16000;
    if (this.audioContext) {
      void this.audioContext.close();
      this.audioContext = null;
    }

    if (this.hasLiveTranscript) {
      void Bridge.log("voice live transcript was captured, skipping whisper STT");
      this.pcmChunks = [];
      return;
    }

    const totalSamples = this.pcmChunks.reduce((acc, c) => acc + c.length, 0);
    if (totalSamples < sampleRate * 0.3) {
      void Bridge.log("voice audio too short, discarded");
      this.pcmChunks = [];
      return;
    }

    const merged = new Float32Array(totalSamples);
    let offset = 0;
    for (const chunk of this.pcmChunks) {
      merged.set(chunk, offset);
      offset += chunk.length;
    }
    this.pcmChunks = [];

    let maxAmplitude = 0;
    for (let i = 0; i < merged.length; i++) {
      const abs = Math.abs(merged[i]);
      if (abs > maxAmplitude) maxAmplitude = abs;
    }
    void Bridge.log(
      `voice audio metrics: totalSamples=${totalSamples}, maxAmplitude=${maxAmplitude.toFixed(3)}`
    );

    if (maxAmplitude > 0) {
      const targetPeak = 0.85;
      const gain = Math.min(25.0, targetPeak / maxAmplitude);
      for (let i = 0; i < merged.length; i++) {
        merged[i] = Math.max(-1.0, Math.min(1.0, merged[i] * gain));
      }
      void Bridge.log(
        `voice applied peak normalization gain: ${gain.toFixed(2)}, adjusted peak to ${(maxAmplitude * gain).toFixed(3)}`
      );
    }

    const wavBytes = encodeWav(merged, sampleRate);
    const base64 = uint8ToBase64(wavBytes);

    try {
      State.isVoiceTranscribing = true;
      State.stateOverride = "thinking";
      State.notify();

      const text = await Bridge.sttTranscribe(
        base64,
        State.settings.voiceLanguage,
        State.settings.voiceSttProvider,
        State.settings.voiceWhisperUrl,
      );

      State.isVoiceTranscribing = false;
      State.stateOverride = null;
      State.notify();

      if (text && text.trim()) {
        void Bridge.log("voice transcription result: " + text);
        if (this.onTranscriptionCallback) {
          this.onTranscriptionCallback(text.trim());
        }
      } else {
        void Bridge.log("voice transcription result: ");
      }
    } catch (err) {
      void Bridge.log(`voice STT transcription failed: ${String(err)}`);
      State.isVoiceTranscribing = false;
      State.stateOverride = null;
      State.notify();
    }
  }

  async speakReply(text: string) {
    if (!State.settings.voiceEnabled || !text.trim()) return;
    this.stopSpeaking();

    const speechText = extractConciseSpeech(text, State.settings.voiceResponseMode);
    if (!speechText) return;

    try {
      State.isVoiceSpeaking = true;
      State.notify();
      void Bridge.log(`voice speaking reply: '${speechText.slice(0, 40)}...'`);

      const rateStr = formatEdgeRate(State.settings.voiceSpeed);
      const volumeStr = formatEdgeVolume(State.settings.voiceVolume);
      const pitchStr = State.settings.voicePitch || "+0Hz";

      const bytes = await Bridge.ttsSpeak(
        speechText,
        State.settings.voiceTtsVoice,
        State.settings.voiceLanguage,
        rateStr,
        volumeStr,
        pitchStr,
      );

      if (!State.isVoiceSpeaking) return;

      const uint8 = new Uint8Array(bytes);
      const isWav =
        uint8.length >= 4 &&
        uint8[0] === 0x52 &&
        uint8[1] === 0x49 &&
        uint8[2] === 0x46 &&
        uint8[3] === 0x46;
      const mime = isWav ? "audio/wav" : "audio/mpeg";
      const blob = new Blob([uint8], { type: mime });
      const url = URL.createObjectURL(blob);

      this.speakingAudio = new Audio(url);
      this.speakingAudio.onended = () => {
        URL.revokeObjectURL(url);
        State.isVoiceSpeaking = false;
        State.notify();
      };
      this.speakingAudio.onerror = (e) => {
        URL.revokeObjectURL(url);
        void Bridge.log(`voice playback error: ${String(e)}`);
        State.isVoiceSpeaking = false;
        State.notify();
      };

      void Bridge.log("voice playback started");
      await this.speakingAudio.play();
    } catch (err) {
      void Bridge.log(`voice TTS playback failed: ${String(err)}`);
      State.isVoiceSpeaking = false;
      State.notify();
    }
  }

  stopSpeaking() {
    if (this.speakingAudio) {
      this.speakingAudio.pause();
      this.speakingAudio.currentTime = 0;
      this.speakingAudio = null;
    }
    void Bridge.ttsStop();
    if (State.isVoiceSpeaking) {
      State.isVoiceSpeaking = false;
      State.notify();
    }
  }
}

export const Voice = new VoiceEngine();
