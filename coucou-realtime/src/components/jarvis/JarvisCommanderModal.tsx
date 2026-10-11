import React, { useState, useEffect } from 'react';
import {
  X,
  Bot,
  Mic,
  MicOff,
  Play,
  CheckCircle2,
  AlertTriangle,
  Clock,
  ShieldCheck,
  Send,
  FileSpreadsheet,
  Filter,
  Mail,
  History,
  Terminal,
  ArrowRight,
  Sparkles,
  RotateCcw,
} from 'lucide-react';
import {
  JarvisVoiceCommandPlan,
  JarvisPlanStep,
  ActionAuditLogEntry,
} from '../../types';

interface JarvisCommanderModalProps {
  isOpen: boolean;
  onClose: () => void;
}

export const JarvisCommanderModal: React.FC<JarvisCommanderModalProps> = ({
  isOpen,
  onClose,
}) => {
  const [activeTab, setActiveTab] = useState<'execution' | 'history'>('execution');
  const [commandInput, setCommandInput] = useState(
    'abre a planilha de vendas, filtra este mês e manda para o João'
  );
  const [isListening, setIsListening] = useState(false);

  // Active multi-step plan
  const [currentPlan, setCurrentPlan] = useState<JarvisVoiceCommandPlan>({
    id: 'plan-1',
    originalSpokenCommand: 'abre a planilha de vendas, filtra este mês e manda para o João',
    createdAt: 'Agora mesmo',
    overallStatus: 'waiting_user_approval',
    steps: [
      {
        id: 's-1',
        order: 1,
        description: 'Localizar e abrir arquivo de planilha no Excel',
        toolType: 'app_launch',
        isSensitive: false,
        targetResource: 'Planilha_Vendas_Q4_2026.xlsx',
        status: 'completed',
        executionResult: 'Arquivo aberto com sucesso em primeiro plano via Windows Shell.',
      },
      {
        id: 's-2',
        order: 2,
        description: 'Aplicar filtro de dados na coluna de data',
        toolType: 'filter_data',
        isSensitive: false,
        targetResource: 'Filtro: Mês = Outubro / 2026 (Linhas: 142 selecionadas)',
        status: 'completed',
        executionResult: 'Planilha filtrada: total de R$ 184.200 em vendas ativas.',
      },
      {
        id: 's-3',
        order: 3,
        description: 'Disparar e-mail com a planilha filtrada em anexo',
        toolType: 'send_email',
        isSensitive: true, // Requer aprovação Human-in-the-Loop!
        targetResource: 'João Silva (joao.silva@empresa.com) • Anexo: Vendas_Outubro_2026.pdf',
        status: 'waiting_confirmation',
        executionResult: 'Aguardando sua autorização para efetuar o disparo do e-mail corporativo.',
      },
    ],
  });

  // Action Audit Log History
  const [auditLog, setAuditLog] = useState<ActionAuditLogEntry[]>([
    {
      id: 'log-1',
      timestamp: 'Hoje às 10:14:22',
      command: 'abre a planilha de vendas, filtra este mês e manda para o João',
      executedStepsCount: 2,
      status: 'em_andamento',
      sensitiveActionConfirmedBy: 'Aguardando aprovação na Etapa 3',
    },
    {
      id: 'log-2',
      timestamp: 'Hoje às 09:32:05',
      command: 'escanear janela ativa e extrair tabela para a área de transferência',
      executedStepsCount: 2,
      status: 'concluido',
      sensitiveActionConfirmedBy: 'Auto-executado com sucesso',
    },
    {
      id: 'log-3',
      timestamp: 'Ontem às 17:05:40',
      command: 'gerar minuta de contrato do Roberto Almeida e notificar CRM via webhook',
      executedStepsCount: 3,
      status: 'concluido',
      sensitiveActionConfirmedBy: 'Aprovado por você às 17:06:12',
    },
  ]);

  if (!isOpen) return null;

  const handleApproveStep = (stepId: string) => {
    setCurrentPlan({
      ...currentPlan,
      overallStatus: 'completed',
      steps: currentPlan.steps.map((s) =>
        s.id === stepId
          ? {
              ...s,
              status: 'completed',
              executionResult: 'E-mail enviado com sucesso com relatório em anexo para joao.silva@empresa.com!',
            }
          : s
      ),
    });

    setAuditLog([
      {
        id: `log-${Date.now()}`,
        timestamp: 'Agora mesmo',
        command: currentPlan.originalSpokenCommand,
        executedStepsCount: 3,
        status: 'concluido',
        sensitiveActionConfirmedBy: 'Aprovado por você com 1 clique',
      },
      ...auditLog.slice(1),
    ]);
  };

  const handleRejectStep = (stepId: string) => {
    setCurrentPlan({
      ...currentPlan,
      overallStatus: 'cancelled',
      steps: currentPlan.steps.map((s) =>
        s.id === stepId
          ? {
              ...s,
              status: 'rejected',
              executionResult: 'Ação cancelada pelo usuário. Nenhum dado foi enviado.',
            }
          : s
      ),
    });
  };

  const handleExecuteNewCommand = (cmd: string) => {
    setCommandInput(cmd);
    setCurrentPlan({
      id: `plan-${Date.now()}`,
      originalSpokenCommand: cmd,
      createdAt: 'Agora mesmo',
      overallStatus: 'waiting_user_approval',
      steps: [
        {
          id: 's-1',
          order: 1,
          description: 'Acessar recurso solicitado',
          toolType: 'app_launch',
          isSensitive: false,
          targetResource: 'Planilha_Vendas_Q4_2026.xlsx',
          status: 'completed',
          executionResult: 'Janela localizada e focada.',
        },
        {
          id: 's-2',
          order: 2,
          description: 'Executar filtro de dados e formatação',
          toolType: 'filter_data',
          isSensitive: false,
          targetResource: 'Filtro: Outubro / 2026',
          status: 'completed',
          executionResult: 'Filtro aplicado.',
        },
        {
          id: 's-3',
          order: 3,
          description: 'Enviar dados para contato especificado',
          toolType: 'send_email',
          isSensitive: true,
          targetResource: 'Destinatário: João Silva (joao.silva@empresa.com)',
          status: 'waiting_confirmation',
          executionResult: 'Aguardando confirmação do usuário antes de enviar.',
        },
      ],
    });
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/85 backdrop-blur-md p-4 animate-in fade-in duration-150">
      <div className="w-full max-w-3xl bg-zinc-900 border border-zinc-800 rounded-3xl shadow-2xl overflow-hidden flex flex-col max-h-[90vh]">
        {/* Header */}
        <div className="flex items-center justify-between px-6 py-4 border-b border-zinc-800 bg-zinc-900/80">
          <div className="flex items-center gap-2.5">
            <div className="w-9 h-9 rounded-xl bg-cyan-500/10 border border-cyan-500/25 flex items-center justify-center text-cyan-400 shadow-sm">
              <Bot size={18} />
            </div>
            <div>
              <div className="flex items-center gap-2">
                <h2 className="text-sm font-semibold text-white">
                  Jarvis Desktop Commander (Controle do PC por Voz)
                </h2>
                <span className="text-[10px] px-2 py-0.5 rounded-full bg-cyan-500/20 text-cyan-300 font-mono font-semibold">
                  Ações em Cadeia
                </span>
              </div>
              <p className="text-[11px] text-zinc-400">
                Executa tarefas no Windows com confirmação obrigatória para ações sensíveis e log de auditoria
              </p>
            </div>
          </div>
          <button
            onClick={onClose}
            className="p-1 rounded-lg text-zinc-400 hover:text-white hover:bg-zinc-800 transition-colors cursor-pointer"
          >
            <X size={18} />
          </button>
        </div>

        {/* Tab Selection */}
        <div className="flex border-b border-zinc-800 bg-zinc-950/40 px-6 gap-3">
          <button
            onClick={() => setActiveTab('execution')}
            className={`py-3 text-xs font-medium border-b-2 transition-all cursor-pointer flex items-center gap-1.5 ${
              activeTab === 'execution'
                ? 'border-cyan-500 text-white font-semibold'
                : 'border-transparent text-zinc-400 hover:text-zinc-200'
            }`}
          >
            <Terminal size={13} className={activeTab === 'execution' ? 'text-cyan-400' : ''} />
            <span>Comando & Decomposição em Etapas</span>
          </button>
          <button
            onClick={() => setActiveTab('history')}
            className={`py-3 text-xs font-medium border-b-2 transition-all cursor-pointer flex items-center gap-1.5 ${
              activeTab === 'history'
                ? 'border-cyan-500 text-white font-semibold'
                : 'border-transparent text-zinc-400 hover:text-zinc-200'
            }`}
          >
            <History size={13} className={activeTab === 'history' ? 'text-cyan-400' : ''} />
            <span>Auditoria & Histórico de Execuções</span>
          </button>
        </div>

        {/* Tab Content Body */}
        <div className="p-6 space-y-5 overflow-y-auto flex-1">
          {activeTab === 'execution' && (
            <>
              {/* Spoken Command Input Box */}
              <div className="space-y-2">
                <label className="text-xs font-semibold text-zinc-200 flex items-center justify-between">
                  <span className="flex items-center gap-1.5">
                    <Sparkles size={13} className="text-cyan-400" />
                    Comando de Voz Composto:
                  </span>
                  <span className="text-[10px] text-zinc-500 font-mono">
                    Atalho: Alt + J
                  </span>
                </label>
                <div className="flex gap-2">
                  <div className="relative flex-1">
                    <input
                      type="text"
                      value={commandInput}
                      onChange={(e) => setCommandInput(e.target.value)}
                      placeholder="Ex: abre a planilha de vendas, filtra este mês e manda para o João..."
                      className="w-full px-3.5 py-2.5 bg-zinc-950 border border-zinc-800 rounded-xl text-xs text-white focus:outline-none focus:border-cyan-500 font-sans shadow-inner pr-10"
                    />
                    <button
                      onClick={() => setIsListening(!isListening)}
                      className={`absolute right-2.5 top-2.5 p-1 rounded-md transition-colors cursor-pointer ${
                        isListening ? 'text-rose-400 animate-pulse' : 'text-zinc-400 hover:text-white'
                      }`}
                      title={isListening ? 'Ouvindo microfone...' : 'Ditar comando por voz'}
                    >
                      {isListening ? <Mic size={15} /> : <MicOff size={15} />}
                    </button>
                  </div>
                  <button
                    onClick={() => handleExecuteNewCommand(commandInput)}
                    className="px-4 py-2 bg-cyan-600 hover:bg-cyan-500 text-zinc-950 font-bold rounded-xl text-xs cursor-pointer transition-colors shadow-sm flex items-center gap-1.5 shrink-0"
                  >
                    <Play size={12} className="fill-current" />
                    <span>Executar</span>
                  </button>
                </div>

                {/* Quick Example Suggestions */}
                <div className="flex items-center gap-1.5 flex-wrap pt-1">
                  <span className="text-[10px] text-zinc-500 font-mono">Exemplos rápidos:</span>
                  {[
                    'abre a planilha de vendas, filtra este mês e manda para o João',
                    'gera o relatório em PDF e envia para o financeiro no Slack',
                    'abre o painel Stripe e tira um print do saldo atual',
                  ].map((example, i) => (
                    <button
                      key={i}
                      onClick={() => handleExecuteNewCommand(example)}
                      className="text-[10px] px-2 py-0.5 rounded-md bg-zinc-950 border border-zinc-800 text-zinc-400 hover:text-cyan-300 hover:border-cyan-500/40 transition-colors cursor-pointer font-sans truncate max-w-[280px]"
                    >
                      “{example}”
                    </button>
                  ))}
                </div>
              </div>

              {/* Multi-step Plan Breakdown */}
              <div className="space-y-3 p-4 rounded-2xl bg-zinc-950/70 border border-zinc-800/80">
                <div className="flex items-center justify-between">
                  <div className="flex items-center gap-2">
                    <span className="w-2 h-2 rounded-full bg-cyan-400 animate-pulse" />
                    <span className="text-xs font-bold text-white uppercase tracking-wider">
                      Plano Decomposto em {currentPlan.steps.length} Etapas
                    </span>
                  </div>
                  <span
                    className={`text-[10px] px-2 py-0.5 rounded-full font-mono font-semibold ${
                      currentPlan.overallStatus === 'completed'
                        ? 'bg-emerald-500/20 text-emerald-300 border border-emerald-500/30'
                        : currentPlan.overallStatus === 'cancelled'
                        ? 'bg-rose-500/20 text-rose-300 border border-rose-500/30'
                        : 'bg-amber-500/20 text-amber-300 border border-amber-500/30'
                    }`}
                  >
                    {currentPlan.overallStatus === 'completed'
                      ? 'EXECUÇÃO CONCLUÍDA'
                      : currentPlan.overallStatus === 'cancelled'
                      ? 'EXECUÇÃO CANCELADA'
                      : 'AGUARDANDO CONFIRMAÇÃO DO USUÁRIO'}
                  </span>
                </div>

                {/* Steps List */}
                <div className="space-y-2.5 pt-1">
                  {currentPlan.steps.map((step) => {
                    const isSensitive = step.isSensitive;
                    const isWaiting = step.status === 'waiting_confirmation';
                    const isDone = step.status === 'completed';
                    const isRejected = step.status === 'rejected';

                    return (
                      <div
                        key={step.id}
                        className={`p-3.5 rounded-xl border transition-all ${
                          isWaiting
                            ? 'bg-amber-950/20 border-amber-500/40 shadow-md'
                            : isDone
                            ? 'bg-zinc-900/60 border-zinc-800'
                            : isRejected
                            ? 'bg-rose-950/20 border-rose-500/30'
                            : 'bg-zinc-900/30 border-zinc-800'
                        }`}
                      >
                        <div className="flex items-start justify-between gap-3">
                          <div className="space-y-1">
                            <div className="flex items-center gap-2">
                              <span className="w-5 h-5 rounded-md bg-zinc-800 text-[10px] font-mono text-cyan-300 flex items-center justify-center font-bold">
                                {step.order}
                              </span>
                              <span className="text-xs font-semibold text-white">
                                {step.description}
                              </span>

                              {isSensitive && (
                                <span className="text-[9px] px-1.5 py-0.5 rounded bg-amber-500/20 text-amber-300 font-mono font-bold flex items-center gap-1">
                                  <AlertTriangle size={10} />
                                  AÇÃO SENSÍVEL
                                </span>
                              )}
                            </div>

                            <div className="text-[11px] text-zinc-400 font-mono pl-7">
                              Alvo: <strong className="text-zinc-200">{step.targetResource}</strong>
                            </div>

                            {step.executionResult && (
                              <div
                                className={`text-[11px] font-mono pl-7 ${
                                  isDone
                                    ? 'text-emerald-400'
                                    : isRejected
                                    ? 'text-rose-400'
                                    : 'text-amber-300'
                                }`}
                              >
                                {isDone ? '✓ ' : isRejected ? '✕ ' : '⏳ '}
                                {step.executionResult}
                              </div>
                            )}
                          </div>

                          {/* Action Buttons for Sensitive Step */}
                          {isWaiting && (
                            <div className="flex items-center gap-2 shrink-0">
                              <button
                                onClick={() => handleRejectStep(step.id)}
                                className="px-2.5 py-1 rounded-lg bg-zinc-800 hover:bg-zinc-700 text-rose-300 text-xs font-medium cursor-pointer transition-colors"
                              >
                                Rejeitar
                              </button>
                              <button
                                onClick={() => handleApproveStep(step.id)}
                                className="px-3 py-1 rounded-lg bg-emerald-600 hover:bg-emerald-500 text-white text-xs font-semibold cursor-pointer transition-colors shadow-sm flex items-center gap-1"
                              >
                                <CheckCircle2 size={12} />
                                <span>Aprovar Disparo</span>
                              </button>
                            </div>
                          )}
                        </div>
                      </div>
                    );
                  })}
                </div>
              </div>
            </>
          )}

          {/* Tab 2: Audit Log History */}
          {activeTab === 'history' && (
            <div className="space-y-3">
              <div className="flex items-center justify-between text-xs text-zinc-400">
                <span>Histórico de ações executadas no Windows pelo assistente:</span>
                <span className="text-[10px] font-mono text-zinc-500">
                  {auditLog.length} registros auditados
                </span>
              </div>

              <div className="space-y-2.5">
                {auditLog.map((log) => (
                  <div
                    key={log.id}
                    className="p-3.5 rounded-xl bg-zinc-950/60 border border-zinc-800 space-y-1.5"
                  >
                    <div className="flex items-center justify-between text-xs">
                      <span className="font-semibold text-white">“{log.command}”</span>
                      <span className="text-[10px] text-zinc-500 font-mono">{log.timestamp}</span>
                    </div>

                    <div className="flex items-center justify-between text-[11px] text-zinc-400 pt-1 border-t border-zinc-800/50 font-mono">
                      <span>{log.executedStepsCount} etapas executadas</span>
                      <span
                        className={
                          log.status === 'concluido'
                            ? 'text-emerald-400'
                            : 'text-amber-400'
                        }
                      >
                        🛡️ {log.sensitiveActionConfirmedBy}
                      </span>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="flex items-center justify-between px-6 py-4 border-t border-zinc-800 bg-zinc-900/80">
          <div className="text-xs text-zinc-400 flex items-center gap-1.5">
            <ShieldCheck size={14} className="text-emerald-400" />
            <span>Segurança garantida: Nenhuma ação externa é enviada sem seu consentimento explícito.</span>
          </div>
          <button
            onClick={onClose}
            className="px-5 py-2 rounded-xl bg-zinc-800 hover:bg-zinc-700 text-white text-xs font-semibold cursor-pointer transition-colors"
          >
            Fechar
          </button>
        </div>
      </div>
    </div>
  );
};
