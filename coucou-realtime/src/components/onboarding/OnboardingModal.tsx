import React, { useState } from 'react';
import {
  Sparkles,
  Mic,
  Key,
  Bot,
  ArrowRight,
  ArrowLeft,
  Check,
  Shield,
  Volume2,
  Briefcase,
  Users,
  Cpu,
} from 'lucide-react';
import { Agent } from '../../types';
import { storage } from '../../services/storage';

interface OnboardingModalProps {
  isOpen: boolean;
  onComplete: () => void;
  agents: Agent[];
  onSelectAgent: (id: string) => void;
}

export const OnboardingModal: React.FC<OnboardingModalProps> = ({
  isOpen,
  onComplete,
  agents,
  onSelectAgent,
}) => {
  const [step, setStep] = useState(1);
  const [apiKey, setApiKey] = useState(storage.getApiKey());
  const [selectedAgentId, setSelectedAgentId] = useState(
    agents[0]?.id || 'sales-copilot'
  );

  if (!isOpen) return null;

  const handleFinish = () => {
    if (apiKey.trim()) {
      storage.setApiKey(apiKey.trim());
    }
    if (selectedAgentId) {
      onSelectAgent(selectedAgentId);
    }
    localStorage.setItem('coucou_onboarding_completed', 'true');
    onComplete();
  };

  const getAgentIcon = (name: string) => {
    switch (name) {
      case 'Meeting Assist':
        return <Users size={16} className="text-emerald-400" />;
      case 'Operations':
        return <Cpu size={16} className="text-cyan-400" />;
      default:
        return <Briefcase size={16} className="text-indigo-400" />;
    }
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/85 backdrop-blur-md p-4 animate-in fade-in duration-200">
      <div className="w-full max-w-xl bg-zinc-900 border border-zinc-800 rounded-3xl shadow-2xl overflow-hidden flex flex-col">
        {/* Progress header */}
        <div className="px-8 pt-8 pb-4">
          <div className="flex items-center justify-between mb-4">
            <span className="text-[11px] font-mono text-zinc-500 uppercase tracking-wider">
              Passo {step} de 4
            </span>
            <span className="text-xs font-semibold text-indigo-400">
              Configuração Inicial do Coucou
            </span>
          </div>
          {/* Progress bar */}
          <div className="w-full h-1.5 bg-zinc-800 rounded-full overflow-hidden flex">
            <div
              className="bg-indigo-600 transition-all duration-300 rounded-full"
              style={{ width: `${(step / 4) * 100}%` }}
            />
          </div>
        </div>

        {/* Step Contents */}
        <div className="px-8 py-6 flex-1 min-h-[300px] flex flex-col justify-center">
          {step === 1 && (
            <div className="space-y-4 text-center">
              <div className="w-16 h-16 rounded-2xl bg-gradient-to-tr from-indigo-600 to-violet-500 mx-auto flex items-center justify-center shadow-lg shadow-indigo-500/25">
                <Sparkles size={32} className="text-white" />
              </div>
              <h2 className="text-xl font-bold text-white tracking-tight">
                Bem-vindo ao Coucou Copilot
              </h2>
              <p className="text-xs text-zinc-400 max-w-md mx-auto leading-relaxed">
                Sua camada de assistência contínua e inteligente no Windows.
                Ouça, analise reuniões em tempo real, contorne objeções e execute ações sem tirar o foco da sua tela.
              </p>
              <div className="grid grid-cols-3 gap-3 pt-4 text-left">
                <div className="p-3 rounded-xl bg-zinc-950/60 border border-zinc-800/80">
                  <div className="text-indigo-400 text-xs font-semibold mb-1">Voz Realtime</div>
                  <div className="text-[10px] text-zinc-500">Conversação bidirecional com interrupção instantânea</div>
                </div>
                <div className="p-3 rounded-xl bg-zinc-950/60 border border-zinc-800/80">
                  <div className="text-cyan-400 text-xs font-semibold mb-1">Áudio Duplo</div>
                  <div className="text-[10px] text-zinc-500">Microfone + WASAPI Loopback das reuniões</div>
                </div>
                <div className="p-3 rounded-xl bg-zinc-950/60 border border-zinc-800/80">
                  <div className="text-emerald-400 text-xs font-semibold mb-1">Visão OCR</div>
                  <div className="text-[10px] text-zinc-500">Contextualização da janela ativa em tela</div>
                </div>
              </div>
            </div>
          )}

          {step === 2 && (
            <div className="space-y-4">
              <div className="flex items-center gap-3">
                <div className="w-10 h-10 rounded-xl bg-emerald-500/10 border border-emerald-500/20 flex items-center justify-center text-emerald-400">
                  <Mic size={20} />
                </div>
                <div>
                  <h3 className="text-base font-semibold text-white">Captura de Áudio & Loopback</h3>
                  <p className="text-xs text-zinc-400">Como o Coucou escuta suas reuniões e chamadas</p>
                </div>
              </div>

              <div className="space-y-3 pt-2">
                <div className="p-3.5 rounded-xl bg-zinc-950/60 border border-zinc-800 flex items-start gap-3">
                  <Mic size={16} className="text-emerald-400 shrink-0 mt-0.5" />
                  <div>
                    <div className="text-xs font-semibold text-zinc-200">Canal 1: Seu Microfone</div>
                    <p className="text-[11px] text-zinc-400 mt-0.5">
                      Processamento local em PCM16 24kHz com cancelamento de ruído e eco.
                    </p>
                  </div>
                </div>

                <div className="p-3.5 rounded-xl bg-zinc-950/60 border border-zinc-800 flex items-start gap-3">
                  <Volume2 size={16} className="text-cyan-400 shrink-0 mt-0.5" />
                  <div>
                    <div className="text-xs font-semibold text-zinc-200">Canal 2: Áudio do Sistema (Loopback)</div>
                    <p className="text-[11px] text-zinc-400 mt-0.5">
                      Grava diretamente o que o cliente ou colegas estão falando no Google Meet / Zoom / Teams sem necessidade de cabos virtuais.
                    </p>
                  </div>
                </div>

                <div className="flex items-center gap-2 p-2.5 rounded-xl bg-indigo-500/10 border border-indigo-500/20 text-[11px] text-indigo-300">
                  <Shield size={14} className="shrink-0" />
                  <span>Seus áudios não são persistidos em nuvem, garantindo total privacidade LGPD.</span>
                </div>
              </div>
            </div>
          )}

          {step === 3 && (
            <div className="space-y-4">
              <div className="flex items-center gap-3">
                <div className="w-10 h-10 rounded-xl bg-indigo-500/10 border border-indigo-500/20 flex items-center justify-center text-indigo-400">
                  <Key size={20} />
                </div>
                <div>
                  <h3 className="text-base font-semibold text-white">Chave OpenAI Realtime API</h3>
                  <p className="text-xs text-zinc-400">Conexão ultra rápida por WebSocket / WebRTC</p>
                </div>
              </div>

              <div className="space-y-2 pt-2">
                <label className="text-xs font-semibold text-zinc-300">Sua API Key (Opcional no Onboarding):</label>
                <input
                  type="password"
                  placeholder="sk-proj-..."
                  value={apiKey}
                  onChange={(e) => setApiKey(e.target.value)}
                  className="w-full px-3.5 py-2.5 bg-zinc-950 border border-zinc-800 rounded-xl text-xs text-zinc-200 font-mono placeholder-zinc-600 focus:outline-none focus:border-indigo-500"
                />
                <p className="text-[11px] text-zinc-500 leading-normal">
                  💡 Caso não possua a chave agora, você pode avançar sem ela! O assistente iniciará automaticamente no <strong>Modo Demonstração Offline</strong> com respostas simuladas ao vivo.
                </p>
              </div>
            </div>
          )}

          {step === 4 && (
            <div className="space-y-4">
              <div className="flex items-center gap-3">
                <div className="w-10 h-10 rounded-xl bg-violet-500/10 border border-violet-500/20 flex items-center justify-center text-violet-400">
                  <Bot size={20} />
                </div>
                <div>
                  <h3 className="text-base font-semibold text-white">Escolha seu Primeiro Agente</h3>
                  <p className="text-xs text-zinc-400">Você pode alternar ou criar novos agentes a qualquer momento</p>
                </div>
              </div>

              <div className="grid grid-cols-1 gap-2.5 pt-2">
                {agents.map((ag) => {
                  const isSelected = selectedAgentId === ag.id;
                  return (
                    <button
                      key={ag.id}
                      onClick={() => setSelectedAgentId(ag.id)}
                      className={`flex items-center justify-between p-3.5 rounded-xl border text-left transition-all cursor-pointer ${
                        isSelected
                          ? 'bg-zinc-800 border-indigo-500/60 shadow-sm shadow-indigo-500/10'
                          : 'bg-zinc-950/60 border-zinc-800 hover:border-zinc-700'
                      }`}
                    >
                      <div className="flex items-center gap-3">
                        <div className="w-8 h-8 rounded-lg bg-zinc-900 border border-zinc-800 flex items-center justify-center">
                          {getAgentIcon(ag.name)}
                        </div>
                        <div>
                          <div className="text-xs font-semibold text-white">{ag.name}</div>
                          <div className="text-[11px] text-zinc-400">{ag.tone}</div>
                        </div>
                      </div>
                      {isSelected && (
                        <div className="w-5 h-5 rounded-full bg-indigo-600 flex items-center justify-center text-white">
                          <Check size={12} />
                        </div>
                      )}
                    </button>
                  );
                })}
              </div>
            </div>
          )}
        </div>

        {/* Footer Navigation */}
        <div className="px-8 py-5 border-t border-zinc-800 bg-zinc-900/60 flex items-center justify-between">
          {step > 1 ? (
            <button
              onClick={() => setStep(step - 1)}
              className="flex items-center gap-1.5 px-4 py-2 rounded-xl bg-zinc-800 hover:bg-zinc-700 text-xs font-medium text-zinc-300 transition-colors cursor-pointer"
            >
              <ArrowLeft size={14} />
              <span>Voltar</span>
            </button>
          ) : (
            <div />
          )}

          {step < 4 ? (
            <button
              onClick={() => setStep(step + 1)}
              className="flex items-center gap-1.5 px-5 py-2.5 rounded-xl bg-indigo-600 hover:bg-indigo-500 text-xs font-semibold text-white shadow-md shadow-indigo-600/30 transition-all cursor-pointer"
            >
              <span>Avançar</span>
              <ArrowRight size={14} />
            </button>
          ) : (
            <button
              onClick={handleFinish}
              className="flex items-center gap-1.5 px-6 py-2.5 rounded-xl bg-emerald-600 hover:bg-emerald-500 text-xs font-semibold text-white shadow-md shadow-emerald-600/30 transition-all cursor-pointer"
            >
              <Check size={14} />
              <span>Concluir e Começar</span>
            </button>
          )}
        </div>
      </div>
    </div>
  );
};
