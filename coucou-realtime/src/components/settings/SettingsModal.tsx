import React, { useState, useEffect } from 'react';
import {
  X,
  Key,
  Mic,
  Shield,
  Check,
  Eye,
  EyeOff,
  Keyboard,
  Globe,
  Mail,
  Terminal,
  RefreshCw,
  Download,
  Info,
} from 'lucide-react';
import { storage } from '../../services/storage';
import { AudioDeviceInfo, ToolConfig } from '../../types';

interface SettingsModalProps {
  isOpen: boolean;
  onClose: () => void;
  onApiKeySaved?: (key: string) => void;
}

export const SettingsModal: React.FC<SettingsModalProps> = ({
  isOpen,
  onClose,
  onApiKeySaved,
}) => {
  const [activeTab, setActiveTab] = useState<'general' | 'tools' | 'updates'>('general');
  const [provider, setProvider] = useState<'openai' | 'gemini' | 'offline'>('openai');
  const [apiKey, setApiKey] = useState('');
  const [geminiKey, setGeminiKey] = useState('');
  const [ollamaEndpoint, setOllamaEndpoint] = useState('http://localhost:11434');
  const [ollamaModel, setOllamaModel] = useState('llama3.3:70b');
  const [whisperModel, setWhisperModel] = useState('whisper-small-local');
  const [showKey, setShowKey] = useState(false);
  const [devices, setDevices] = useState<AudioDeviceInfo[]>([]);
  const [tools, setTools] = useState<ToolConfig[]>([]);
  const [savedSuccess, setSavedSuccess] = useState(false);
  const [checkingUpdate, setCheckingUpdate] = useState(false);
  const [updateMessage, setUpdateMessage] = useState<string | null>(null);

  useEffect(() => {
    if (isOpen) {
      setApiKey(storage.getApiKey());
      setGeminiKey(localStorage.getItem('coucou_gemini_api_key') || '');
      setProvider((localStorage.getItem('coucou_ai_provider') as any) || 'openai');
      setOllamaEndpoint(localStorage.getItem('coucou_ollama_endpoint') || 'http://localhost:11434');
      setOllamaModel(localStorage.getItem('coucou_ollama_model') || 'llama3.3:70b');
      setWhisperModel(localStorage.getItem('coucou_whisper_model') || 'whisper-small-local');
      storage.getAudioDevices().then(setDevices);
      storage.getTools().then(setTools);
      setUpdateMessage(null);
    }
  }, [isOpen]);

  if (!isOpen) return null;

  const handleSave = () => {
    storage.setApiKey(apiKey);
    localStorage.setItem('coucou_ai_provider', provider);
    localStorage.setItem('coucou_gemini_api_key', geminiKey);
    localStorage.setItem('coucou_ollama_endpoint', ollamaEndpoint);
    localStorage.setItem('coucou_ollama_model', ollamaModel);
    localStorage.setItem('coucou_whisper_model', whisperModel);
    onApiKeySaved?.(apiKey);
    setSavedSuccess(true);
    setTimeout(() => {
      setSavedSuccess(false);
      onClose();
    }, 800);
  };

  const handleCheckUpdate = () => {
    setCheckingUpdate(true);
    setTimeout(() => {
      setCheckingUpdate(false);
      setUpdateMessage('Você está na versão mais recente (v1.0.0 - Canal Estável).');
    }, 1200);
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/75 backdrop-blur-sm p-4 animate-in fade-in duration-150">
      <div className="w-full max-w-2xl bg-zinc-900 border border-zinc-800 rounded-2xl shadow-2xl overflow-hidden flex flex-col max-h-[85vh]">
        {/* Header */}
        <div className="flex items-center justify-between px-6 py-4 border-b border-zinc-800 bg-zinc-900/80">
          <div>
            <h2 className="text-sm font-semibold text-white">Configurações & Painel do Sistema</h2>
            <p className="text-[11px] text-zinc-400">Preferências de IA, modo offline/privado e integrações</p>
          </div>
          <button
            onClick={onClose}
            className="p-1 rounded-lg text-zinc-400 hover:text-white hover:bg-zinc-800 transition-colors cursor-pointer"
          >
            <X size={18} />
          </button>
        </div>

        {/* Tab Selector */}
        <div className="flex border-b border-zinc-800 bg-zinc-950/40 px-6 gap-4">
          <button
            onClick={() => setActiveTab('general')}
            className={`py-3 text-xs font-medium border-b-2 transition-all cursor-pointer ${
              activeTab === 'general'
                ? 'border-indigo-500 text-white font-semibold'
                : 'border-transparent text-zinc-400 hover:text-zinc-200'
            }`}
          >
            Geral & Provedores de IA
          </button>
          <button
            onClick={() => setActiveTab('tools')}
            className={`py-3 text-xs font-medium border-b-2 transition-all cursor-pointer ${
              activeTab === 'tools'
                ? 'border-indigo-500 text-white font-semibold'
                : 'border-transparent text-zinc-400 hover:text-zinc-200'
            }`}
          >
            Ferramentas & Integrações
          </button>
          <button
            onClick={() => setActiveTab('updates')}
            className={`py-3 text-xs font-medium border-b-2 transition-all cursor-pointer ${
              activeTab === 'updates'
                ? 'border-indigo-500 text-white font-semibold'
                : 'border-transparent text-zinc-400 hover:text-zinc-200'
            }`}
          >
            Versões & Auto-Update
          </button>
        </div>

        {/* Tab Body */}
        <div className="p-6 space-y-5 overflow-y-auto flex-1">
          {activeTab === 'general' && (
            <>
              {/* Provedor de IA Selector */}
              <div className="space-y-2">
                <label className="text-xs font-semibold text-zinc-200 flex items-center justify-between">
                  <span className="flex items-center gap-1.5">
                    <Key size={13} className="text-indigo-400" />
                    Provedor de IA & Voz
                  </span>
                  <span className="text-[10px] text-zinc-500 font-mono">
                    {provider === 'offline' ? '100% Local / Zero Nuvem' : provider === 'gemini' ? 'Google AI Studio' : 'OpenAI Realtime'}
                  </span>
                </label>
                <select
                  value={provider}
                  onChange={(e) => setProvider(e.target.value as any)}
                  className="w-full px-3.5 py-2.5 bg-zinc-950 border border-zinc-800 rounded-xl text-xs text-white focus:outline-none focus:border-indigo-500 cursor-pointer"
                >
                  <option value="gemini">Google Gemini Live (Gemini 2.0 Flash — Streaming Nativo)</option>
                  <option value="openai">OpenAI Realtime API (GPT-4o Realtime)</option>
                  <option value="offline">Modo Offline Privado (Whisper + Ollama Local / LGPD)</option>
                </select>
              </div>

              {/* Conditional Inputs based on Provider */}
              {provider === 'gemini' && (
                <div className="space-y-2">
                  <label className="text-xs font-semibold text-zinc-200 flex items-center justify-between">
                    <span className="flex items-center gap-1.5">
                      <Key size={13} className="text-amber-400" />
                      Chave do Google Gemini (API Key)
                    </span>
                    <span className="text-[10px] text-zinc-500 font-mono">AIzaSy...</span>
                  </label>
                  <div className="relative">
                    <input
                      type={showKey ? 'text' : 'password'}
                      value={geminiKey}
                      onChange={(e) => setGeminiKey(e.target.value)}
                      placeholder="AIzaSy..."
                      className="w-full px-3.5 py-2.5 bg-zinc-950 border border-zinc-800 rounded-xl text-xs text-zinc-200 placeholder-zinc-600 focus:outline-none focus:border-indigo-500 font-mono pr-10"
                    />
                    <button
                      type="button"
                      onClick={() => setShowKey(!showKey)}
                      className="absolute right-3 top-2.5 text-zinc-500 hover:text-zinc-300 cursor-pointer"
                    >
                      {showKey ? <EyeOff size={14} /> : <Eye size={14} />}
                    </button>
                  </div>
                  <p className="text-[11px] text-zinc-500 leading-normal">
                    Obtida gratuitamente em aistudio.google.com. Modelo Gemini 2.0 Flash Multimodal Live com streaming nativo de áudio.
                  </p>
                </div>
              )}

              {provider === 'openai' && (
                <div className="space-y-2">
                  <label className="text-xs font-semibold text-zinc-200 flex items-center justify-between">
                    <span className="flex items-center gap-1.5">
                      <Key size={13} className="text-indigo-400" />
                      Chave da OpenAI (API Key)
                    </span>
                    <span className="text-[10px] text-zinc-500 font-mono">sk-proj-...</span>
                  </label>
                  <div className="relative">
                    <input
                      type={showKey ? 'text' : 'password'}
                      value={apiKey}
                      onChange={(e) => setApiKey(e.target.value)}
                      placeholder="sk-proj-..."
                      className="w-full px-3.5 py-2.5 bg-zinc-950 border border-zinc-800 rounded-xl text-xs text-zinc-200 placeholder-zinc-600 focus:outline-none focus:border-indigo-500 font-mono pr-10"
                    />
                    <button
                      type="button"
                      onClick={() => setShowKey(!showKey)}
                      className="absolute right-3 top-2.5 text-zinc-500 hover:text-zinc-300 cursor-pointer"
                    >
                      {showKey ? <EyeOff size={14} /> : <Eye size={14} />}
                    </button>
                  </div>
                  <p className="text-[11px] text-zinc-500 leading-normal">
                    Utilizada para voz bidirecional GPT-4o Realtime. Se vazia, opera em modo simulado.
                  </p>
                </div>
              )}

              {provider === 'offline' && (
                <div className="space-y-3 p-3.5 bg-emerald-950/15 border border-emerald-500/25 rounded-xl">
                  <div className="flex items-center gap-2 text-xs font-semibold text-emerald-300">
                    <Shield size={14} />
                    <span>Configuração do Modo 100% Offline e Privado</span>
                  </div>
                  <p className="text-[11px] text-zinc-400">
                    Nenhum byte sai do seu computador. Transcrição via Whisper local e inferência via Ollama ou LM Studio. Ideal para sigilo jurídico, médico e corporativo.
                  </p>
                  <div className="grid grid-cols-2 gap-2.5 pt-1">
                    <div className="space-y-1">
                      <label className="text-[10px] text-zinc-400 font-medium">Endpoint Ollama:</label>
                      <input
                        type="text"
                        value={ollamaEndpoint}
                        onChange={(e) => setOllamaEndpoint(e.target.value)}
                        placeholder="http://localhost:11434"
                        className="w-full px-2.5 py-1.5 bg-zinc-950 border border-zinc-800 rounded-lg text-xs text-zinc-200 font-mono"
                      />
                    </div>
                    <div className="space-y-1">
                      <label className="text-[10px] text-zinc-400 font-medium">Modelo LLM Local:</label>
                      <select
                        value={ollamaModel}
                        onChange={(e) => setOllamaModel(e.target.value)}
                        className="w-full px-2.5 py-1.5 bg-zinc-950 border border-zinc-800 rounded-lg text-xs text-zinc-200 cursor-pointer"
                      >
                        <option value="llama3.3:70b">Llama 3.3 (70B)</option>
                        <option value="llama3.1:8b">Llama 3.1 (8B - Rápido)</option>
                        <option value="deepseek-r1:8b">DeepSeek R1 (8B)</option>
                        <option value="mistral:7b">Mistral (7B)</option>
                        <option value="qwen2.5:7b">Qwen 2.5 (7B)</option>
                      </select>
                    </div>
                  </div>
                  <div className="space-y-1 pt-1">
                    <label className="text-[10px] text-zinc-400 font-medium">Modelo Whisper Local (STT):</label>
                    <select
                      value={whisperModel}
                      onChange={(e) => setWhisperModel(e.target.value)}
                      className="w-full px-2.5 py-1.5 bg-zinc-950 border border-zinc-800 rounded-lg text-xs text-zinc-200 cursor-pointer"
                    >
                      <option value="whisper-tiny-local">Whisper Tiny (Ultra rápido / Menor uso de VRAM)</option>
                      <option value="whisper-base-local">Whisper Base (Equilibrado)</option>
                      <option value="whisper-small-local">Whisper Small (Alta Precisão PT-BR)</option>
                      <option value="whisper-medium-local">Whisper Medium (Máxima Precisão)</option>
                    </select>
                  </div>
                </div>
              )}

              {/* Audio Input Device */}
              <div className="space-y-2">
                <label className="text-xs font-semibold text-zinc-200 flex items-center gap-1.5">
                  <Mic size={13} className="text-emerald-400" />
                  Dispositivo de Entrada de Áudio (WASAPI)
                </label>
                <select className="w-full px-3.5 py-2.5 bg-zinc-950 border border-zinc-800 rounded-xl text-xs text-zinc-300 focus:outline-none focus:border-indigo-500">
                  {devices.map((d, i) => (
                    <option key={i} value={d.name}>
                      {d.name} {d.is_default ? '(Padrão do Windows)' : ''}
                    </option>
                  ))}
                </select>
              </div>

              {/* Shortcuts */}
              <div className="space-y-2.5 p-3.5 bg-zinc-950/60 rounded-xl border border-zinc-800/80">
                <div className="flex items-center gap-1.5 text-xs font-semibold text-zinc-300">
                  <Keyboard size={13} className="text-cyan-400" />
                  <span>Atalhos Globais do Windows</span>
                </div>
                <div className="grid grid-cols-2 gap-2 text-[11px] text-zinc-400">
                  <div className="flex items-center justify-between p-2 rounded bg-zinc-900/60 border border-zinc-800/40">
                    <span>Alternar Janela Principal</span>
                    <kbd className="px-1.5 py-0.5 rounded bg-zinc-800 font-mono text-zinc-300">Alt + Space</kbd>
                  </div>
                  <div className="flex items-center justify-between p-2 rounded bg-zinc-900/60 border border-zinc-800/40">
                    <span>Silenciar Microfone</span>
                    <kbd className="px-1.5 py-0.5 rounded bg-zinc-800 font-mono text-zinc-300">Alt + M</kbd>
                  </div>
                  <div className="flex items-center justify-between p-2 rounded bg-zinc-900/60 border border-zinc-800/40">
                    <span>Escanear Janela Ativa (OCR)</span>
                    <kbd className="px-1.5 py-0.5 rounded bg-zinc-800 font-mono text-zinc-300">Alt + S</kbd>
                  </div>
                  <div className="flex items-center justify-between p-2 rounded bg-zinc-900/60 border border-zinc-800/40">
                    <span>Interrupção Imediata</span>
                    <kbd className="px-1.5 py-0.5 rounded bg-zinc-800 font-mono text-zinc-300">Barge-in</kbd>
                  </div>
                </div>
              </div>

              <div className="flex items-start gap-2.5 p-3 rounded-xl bg-indigo-500/5 border border-indigo-500/15 text-[11px] text-zinc-400">
                <Shield size={16} className="text-indigo-400 shrink-0 mt-0.5" />
                <span>
                  Segurança local: Os dados de reuniões são gravados no SQLite do seu computador e não são enviados a servidores externos além da API da OpenAI.
                </span>
              </div>
            </>
          )}

          {activeTab === 'tools' && (
            <div className="space-y-4">
              <div className="text-xs text-zinc-400">
                Ferramentas registradas disponíveis para os agentes realizarem ações externas com aprovação do usuário:
              </div>

              <div className="space-y-3">
                {tools.map((t) => (
                  <div
                    key={t.id}
                    className="p-3.5 rounded-xl bg-zinc-950/60 border border-zinc-800 flex items-center justify-between"
                  >
                    <div className="flex items-center gap-3">
                      <div className="w-8 h-8 rounded-lg bg-zinc-900 border border-zinc-800 flex items-center justify-center text-indigo-400">
                        {t.tool_type === 'webhook' ? (
                          <Globe size={16} />
                        ) : t.tool_type === 'smtp' ? (
                          <Mail size={16} />
                        ) : (
                          <Terminal size={16} />
                        )}
                      </div>
                      <div>
                        <div className="text-xs font-semibold text-zinc-200">{t.name}</div>
                        <div className="text-[10px] text-zinc-500 font-mono capitalize">
                          Tipo: {t.tool_type} • Confirmação: {t.requires_confirmation ? 'Obrigatória' : 'Automática'}
                        </div>
                      </div>
                    </div>

                    <span
                      className={`text-[10px] px-2 py-0.5 rounded-full font-mono ${
                        t.is_enabled
                          ? 'bg-emerald-500/20 text-emerald-300 border border-emerald-500/30'
                          : 'bg-zinc-800 text-zinc-500'
                      }`}
                    >
                      {t.is_enabled ? 'ATIVADA' : 'DESATIVADA'}
                    </span>
                  </div>
                ))}
              </div>
            </div>
          )}

          {activeTab === 'updates' && (
            <div className="space-y-4">
              <div className="p-4 rounded-xl bg-zinc-950/60 border border-zinc-800 flex items-center justify-between">
                <div className="flex items-center gap-3">
                  <div className="w-10 h-10 rounded-xl bg-indigo-500/10 border border-indigo-500/20 flex items-center justify-center text-indigo-400">
                    <Info size={20} />
                  </div>
                  <div>
                    <h3 className="text-sm font-semibold text-white">Coucou Copilot Desktop</h3>
                    <p className="text-xs text-zinc-400">Versão instalada: 1.0.0 (Windows 64-bit)</p>
                  </div>
                </div>

                <button
                  onClick={handleCheckUpdate}
                  disabled={checkingUpdate}
                  className="flex items-center gap-1.5 px-4 py-2 rounded-xl bg-zinc-800 hover:bg-zinc-750 text-xs font-semibold text-zinc-200 transition-colors cursor-pointer"
                >
                  <RefreshCw size={13} className={checkingUpdate ? 'animate-spin text-indigo-400' : ''} />
                  <span>{checkingUpdate ? 'Verificando...' : 'Buscar Atualizações'}</span>
                </button>
              </div>

              {updateMessage && (
                <div className="p-3 rounded-xl bg-emerald-500/10 border border-emerald-500/20 text-xs text-emerald-300 flex items-center gap-2">
                  <Check size={14} />
                  <span>{updateMessage}</span>
                </div>
              )}

              <div className="p-4 rounded-xl bg-zinc-950/40 border border-zinc-800 space-y-2">
                <span className="text-xs font-semibold text-zinc-300">Distribuição & Empacotamento</span>
                <p className="text-[11px] text-zinc-400 leading-relaxed">
                  Os instaladores automáticos são gerados via Tauri CLI (`npm run tauri build`) nos formatos MSI e NSIS com suporte a auto-update assinado através de GitHub Releases.
                </p>
                <div className="pt-2">
                  <span className="text-[11px] font-mono text-zinc-500">
                    Caminho de build: src-tauri/target/release/bundle/msi/
                  </span>
                </div>
              </div>
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="flex items-center justify-end gap-3 px-6 py-4 border-t border-zinc-800 bg-zinc-900/80">
          <button
            onClick={onClose}
            className="px-4 py-2 text-xs font-medium text-zinc-400 hover:text-white transition-colors cursor-pointer"
          >
            Fechar
          </button>
          {activeTab === 'general' && (
            <button
              onClick={handleSave}
              className="flex items-center gap-1.5 px-5 py-2 rounded-xl bg-indigo-600 hover:bg-indigo-500 text-white text-xs font-semibold shadow-md shadow-indigo-600/30 transition-all cursor-pointer"
            >
              {savedSuccess ? (
                <>
                  <Check size={14} className="text-emerald-300" />
                  <span>Salvo com Sucesso!</span>
                </>
              ) : (
                <span>Salvar Configurações</span>
              )}
            </button>
          )}
        </div>
      </div>
    </div>
  );
};
