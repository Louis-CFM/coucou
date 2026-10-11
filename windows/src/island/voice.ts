// Web Speech API Voice Recognition & Wake-Word Detector for Coucou
// Listens for "coucou", "คูกู", "เฮ้ คูกู", "ok coucou" and expands island to chat/prompt view.

import { Sound } from "../core/sound";
import type { ShortcutHost } from "./shortcuts";

// Extend Window interface for Web Speech API
interface IWindow extends Window {
  webkitSpeechRecognition?: any;
  SpeechRecognition?: any;
}

export class VoiceWakeListener {
  private host: ShortcutHost;
  private recognition: any = null;
  private listening = false;
  private resumeApp: () => void;

  constructor(host: ShortcutHost, resumeApp: () => void) {
    this.host = host;
    this.resumeApp = resumeApp;
    this.initSpeech();
  }

  private initSpeech() {
    const win = window as unknown as IWindow;
    const SpeechRecognition = win.SpeechRecognition || win.webkitSpeechRecognition;
    if (!SpeechRecognition) {
      console.warn("Web Speech API not supported in this Webview environment.");
      return;
    }

    try {
      this.recognition = new SpeechRecognition();
      this.recognition.continuous = true;
      this.recognition.interimResults = true;
      this.recognition.lang = "th-TH";

      this.recognition.onresult = (event: any) => {
        for (let i = event.resultIndex; i < event.results.length; ++i) {
          const transcript = event.results[i][0].transcript.trim().toLowerCase();
          if (this.isWakeWord(transcript)) {
            this.handleWake();
            break;
          }
        }
      };

      this.recognition.onerror = (_e: any) => {
        // Automatically restart if recognition disconnects or errors
        if (this.listening) {
          setTimeout(() => this.start(), 1000);
        }
      };

      this.recognition.onend = () => {
        // Keep listening in background
        if (this.listening) {
          setTimeout(() => this.start(), 500);
        }
      };
    } catch (err) {
      console.warn("Failed to initialize speech recognition:", err);
    }
  }

  private isWakeWord(text: string): boolean {
    const wakePatterns = [
      /\bcoucou\b/i,
      /\bcuckoo\b/i,
      /\bok coucou\b/i,
      /คูกู/,
      /คูคู/,
      /กูคู/,
      /เฮ้ คูกู/,
      /โอเค คูกู/
    ];
    return wakePatterns.some((pattern) => pattern.test(text));
  }

  private handleWake() {
    this.resumeApp();
    Sound.play("peek");
    this.host.emote("happy");
    this.host.alert("prompt");
    this.host.takeKeyboard();
  }

  start() {
    if (!this.recognition) return;
    try {
      this.listening = true;
      this.recognition.start();
    } catch {
      // Already running
    }
  }

  stop() {
    this.listening = false;
    if (this.recognition) {
      try {
        this.recognition.stop();
      } catch {}
    }
  }
}
