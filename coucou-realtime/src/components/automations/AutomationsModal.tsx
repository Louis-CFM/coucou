import React, { useState } from 'react';
import {
  X,
  Zap,
  Plus,
  Trash2,
  CheckCircle2,
  AlertCircle,
  ExternalLink,
  ShieldCheck,
  Send,
  FileText,
  Layers,
  ArrowRight,
  Play,
} from 'lucide-react';
import { AutomationRule, TriggerType, ActionType } from '../../types';

interface AutomationsModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSimulateTrigger?: (rule: AutomationRule) => void;
}

export const AutomationsModal: React.FC<AutomationsModalProps> = ({
  isOpen,
  onClose,
  onSimulateTrigger,
}) => {
  const [rules, setRules] = useState<AutomationRule[]>([
    {
      id: 'rule-1',
      name: 'Comparativo Imediato de Concorrente',
      triggerType: 'voice_keyword',
      triggerPhrase: 'concorrente|salesforce|hubspot',
      actionType: 'show_card',
      actionTitle: 'Tabela Comparativa de Recursos & Preço 2.5x Menor',
      actionPayload:
        'Diferenciais: Soberania local LGPD, Latência 8x menor, Suporte via WhatsApp, Custo anual 60% menor.',
      requiresConfirmation: false,
      isEnabled: true,
      lastTriggered: 'Hoje às 10:14',
    },
    {
      id: 'rule-2',
      name: 'Automação de Fechamento de Contrato',
      triggerType: 'intent_closing',
      triggerPhrase: 'vamos fechar|manda o contrato|fechado',
      actionType: 'create_contract',
      actionTitle: 'Gerar Minuta de Contrato & Disparar Webhook CRM',
      actionPayload:
        'Webhook: https://crm.suaempresa.com/api/deals/fechamento\nPayload: { deal: "Enterprise", status: "Won", draftContract: true }',
      requiresConfirmation: true,
      isEnabled: true,
      lastTriggered: 'Ontem às 16:40',
    },
    {
      id: 'rule-3',
      name: 'Contorno Automático de Objeção de Preço',
      triggerType: 'objection_price',
      triggerPhrase: 'está caro|fora do orçamento|sem verba',
      actionType: 'coach_whisper',
      actionTitle: 'Injetar no Coach: Propor Entrega em 2 Fases (MVP em 20 dias)',
      actionPayload:
        'Sugestão: "Entendo o orçamento para o trimestre. Podemos iniciar pela Fase 1 essencial por 40% do valor e faturar a Fase 2 no próximo mês."',
      requiresConfirmation: false,
      isEnabled: true,
    },
    {
      id: 'rule-4',
      name: 'Detector de Janela de Orçamento (OCR)',
      triggerType: 'screen_window',
      triggerPhrase: 'Proposta|Orçamento|Planilha',
      actionType: 'show_card',
      actionTitle: 'Exibir Ficha do Cliente & Histórico de Descontos',
      actionPayload:
        'Histórico do cliente Roberto Almeida: Último pedido de 15% de desconto com pagamento semestral.',
      requiresConfirmation: false,
      isEnabled: false,
    },
  ]);

  const [isCreating, setIsCreating] = useState(false);
  const [name, setName] = useState('');
  const [triggerType, setTriggerType] = useState<TriggerType>('voice_keyword');
  const [triggerPhrase, setTriggerPhrase] = useState('');
  const [actionType, setActionType] = useState<ActionType>('show_card');
  const [actionTitle, setActionTitle] = useState('');
  const [actionPayload, setActionPayload] = useState('');
  const [requiresConfirmation, setRequiresConfirmation] = useState(true);

  if (!isOpen) return null;

  const handleToggle = (id: string) => {
    setRules(
      rules.map((r) => (r.id === id ? { ...r, isEnabled: !r.isEnabled } : r))
    );
  };

  const handleDelete = (id: string) => {
    setRules(rules.filter((r) => r.id !== id));
  };

  const handleCreate = (e: React.FormEvent) => {
    e.preventDefault();
    if (!name.trim() || !triggerPhrase.trim() || !actionTitle.trim()) return;

    const newRule: AutomationRule = {
      id: `rule-${Date.now()}`,
      name: name.trim(),
      triggerType,
      triggerPhrase: triggerPhrase.trim(),
      actionType,
      actionTitle: actionTitle.trim(),
      actionPayload: actionPayload.trim(),
      requiresConfirmation,
      isEnabled: true,
    };

    setRules([newRule, ...rules]);
    setName('');
    setTriggerPhrase('');
    setActionTitle('');
    setActionPayload('');
    setIsCreating(false);
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/80 backdrop-blur-md p-4 animate-in fade-in duration-150">
      <div className="w-full max-w-3xl bg-zinc-900 border border-zinc-800 rounded-3xl shadow-2xl overflow-hidden flex flex-col max-h-[88vh]">
        {/* Header */}
        <div className="flex items-center justify-between px-6 py-4 border-b border-zinc-800 bg-zinc-900/80">
          <div className="flex items-center gap-2.5">
            <div className="w-9 h-9 rounded-xl bg-amber-500/10 border border-amber-500/20 flex items-center justify-center text-amber-400">
              <Zap size={18} />
            </div>
            <div>
              <div className="flex items-center gap-2">
                <h2 className="text-sm font-semibold text-white">
                  Automações “Se Isso, Então Aquilo” (IFTTT por Voz)
                </h2>
                <span className="text-[10px] px-2 py-0.5 rounded-full bg-amber-500/15 text-amber-300 font-mono">
                  Gatilhos Reativos & MCP
                </span>
              </div>
              <p className="text-[11px] text-zinc-400">
                Gatilhos de fala ou contexto de tela que disparam ações, cards comparativos, webhooks e contratos
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

        {/* Content Body */}
        <div className="p-6 space-y-4 overflow-y-auto flex-1">
          {/* Top Actions Bar */}
          <div className="flex items-center justify-between">
            <span className="text-xs text-zinc-400 font-medium">
              {rules.filter((r) => r.isEnabled).length} regras ativas monitorando reuniões em tempo real
            </span>
            <button
              onClick={() => setIsCreating(!isCreating)}
              className="flex items-center gap-1.5 px-3 py-1.5 bg-indigo-600 hover:bg-indigo-500 text-white rounded-xl text-xs font-semibold cursor-pointer transition-colors shadow-sm"
            >
              <Plus size={13} />
              <span>{isCreating ? 'Fechar Formulário' : 'Criar Nova Regra'}</span>
            </button>
          </div>

          {/* Create Rule Form */}
          {isCreating && (
            <form
              onSubmit={handleCreate}
              className="p-4 rounded-2xl bg-zinc-950/70 border border-indigo-500/30 space-y-3 animate-in fade-in duration-150"
            >
              <div className="flex items-center justify-between">
                <span className="text-xs font-bold text-indigo-300">
                  Nova Regra “Se Isso, Então Aquilo”
                </span>
                <span className="text-[10px] text-zinc-500 font-mono">
                  Voz • OCR • Webhook • MCP
                </span>
              </div>

              <div>
                <label className="text-[11px] text-zinc-400 font-medium block mb-1">
                  Nome da Automação:
                </label>
                <input
                  type="text"
                  placeholder="Ex: Citação de Concorrente Y -> Abrir Comparativo"
                  value={name}
                  onChange={(e) => setName(e.target.value)}
                  className="w-full px-3 py-1.5 bg-zinc-900 border border-zinc-800 rounded-xl text-xs text-zinc-200 focus:outline-none focus:border-indigo-500"
                />
              </div>

              <div className="grid grid-cols-2 gap-3">
                {/* Trigger */}
                <div className="space-y-1">
                  <label className="text-[11px] text-amber-300 font-medium block">
                    SE (Gatilho):
                  </label>
                  <select
                    value={triggerType}
                    onChange={(e) => setTriggerType(e.target.value as any)}
                    className="w-full px-2.5 py-1.5 bg-zinc-900 border border-zinc-800 rounded-xl text-xs text-zinc-300 focus:outline-none cursor-pointer"
                  >
                    <option value="voice_keyword">Palavra/Frase falada na call</option>
                    <option value="intent_closing">Sinal de Fechamento de Venda</option>
                    <option value="objection_price">Objeção de Preço/Orçamento</option>
                    <option value="screen_window">Janela/Documento na tela (OCR)</option>
                  </select>
                  <input
                    type="text"
                    placeholder="Palavras-chave (ex: concorrente x|salesforce)"
                    value={triggerPhrase}
                    onChange={(e) => setTriggerPhrase(e.target.value)}
                    className="w-full px-3 py-1.5 bg-zinc-900 border border-zinc-800 rounded-xl text-xs text-zinc-200 font-mono focus:outline-none focus:border-indigo-500 mt-1"
                  />
                </div>

                {/* Action */}
                <div className="space-y-1">
                  <label className="text-[11px] text-emerald-300 font-medium block">
                    ENTÃO (Ação):
                  </label>
                  <select
                    value={actionType}
                    onChange={(e) => setActionType(e.target.value as any)}
                    className="w-full px-2.5 py-1.5 bg-zinc-900 border border-zinc-800 rounded-xl text-xs text-zinc-300 focus:outline-none cursor-pointer"
                  >
                    <option value="show_card">Mostrar Card / Comparativo na Tela</option>
                    <option value="create_contract">Gerar Minuta de Contrato</option>
                    <option value="dispatch_webhook">Disparar Webhook REST (CRM/n8n)</option>
                    <option value="coach_whisper">Injetar Dica no Coach Sussurro</option>
                  </select>
                  <input
                    type="text"
                    placeholder="Título da Ação (ex: Tabela Comparativa de Preço)"
                    value={actionTitle}
                    onChange={(e) => setActionTitle(e.target.value)}
                    className="w-full px-3 py-1.5 bg-zinc-900 border border-zinc-800 rounded-xl text-xs text-zinc-200 focus:outline-none focus:border-indigo-500 mt-1"
                  />
                </div>
              </div>

              <div>
                <label className="text-[11px] text-zinc-400 font-medium block mb-1">
                  Conteúdo / Payload / URL da Ação:
                </label>
                <textarea
                  rows={2}
                  placeholder="Detalhes que serão apresentados no card ou JSON enviado no webhook..."
                  value={actionPayload}
                  onChange={(e) => setActionPayload(e.target.value)}
                  className="w-full px-3 py-1.5 bg-zinc-900 border border-zinc-800 rounded-xl text-xs text-zinc-200 focus:outline-none focus:border-indigo-500 font-mono"
                />
              </div>

              <div className="flex items-center justify-between pt-1">
                <label className="flex items-center gap-2 text-xs text-zinc-400 cursor-pointer">
                  <input
                    type="checkbox"
                    checked={requiresConfirmation}
                    onChange={(e) => setRequiresConfirmation(e.target.checked)}
                    className="rounded bg-zinc-900 border-zinc-800 text-indigo-600 focus:ring-0"
                  />
                  <span>Exigir confirmação do usuário antes de executar ação sensível</span>
                </label>

                <div className="flex gap-2">
                  <button
                    type="button"
                    onClick={() => setIsCreating(false)}
                    className="px-3 py-1 text-zinc-400 text-xs hover:text-white cursor-pointer"
                  >
                    Cancelar
                  </button>
                  <button
                    type="submit"
                    className="px-4 py-1.5 bg-indigo-600 hover:bg-indigo-500 text-white rounded-xl text-xs font-semibold cursor-pointer shadow-sm"
                  >
                    Salvar Automação
                  </button>
                </div>
              </div>
            </form>
          )}

          {/* Rules List */}
          <div className="space-y-3">
            {rules.map((rule) => (
              <div
                key={rule.id}
                className={`p-4 rounded-2xl border transition-all ${
                  rule.isEnabled
                    ? 'bg-zinc-950/60 border-zinc-800 hover:border-zinc-700'
                    : 'bg-zinc-950/30 border-zinc-900 opacity-60'
                }`}
              >
                <div className="flex items-start justify-between gap-3">
                  <div className="space-y-1">
                    <div className="flex items-center gap-2">
                      <h4 className="text-xs font-bold text-white">{rule.name}</h4>
                      {rule.requiresConfirmation ? (
                        <span className="text-[10px] px-1.5 py-0.5 rounded bg-zinc-800 text-zinc-400 font-mono">
                          Com Confirmação
                        </span>
                      ) : (
                        <span className="text-[10px] px-1.5 py-0.5 rounded bg-emerald-500/20 text-emerald-300 font-mono">
                          Auto-Executar
                        </span>
                      )}
                      {rule.lastTriggered && (
                        <span className="text-[10px] text-zinc-500 font-mono">
                          • Último disparo: {rule.lastTriggered}
                        </span>
                      )}
                    </div>

                    {/* Flow representation */}
                    <div className="flex items-center gap-2 pt-1 text-xs">
                      <div className="px-2.5 py-1 rounded-lg bg-amber-950/20 border border-amber-500/30 text-amber-200 flex items-center gap-1.5 font-mono text-[11px]">
                        <span className="font-bold text-amber-400">SE:</span>
                        <span>"{rule.triggerPhrase}"</span>
                      </div>
                      <ArrowRight size={13} className="text-zinc-600" />
                      <div className="px-2.5 py-1 rounded-lg bg-emerald-950/20 border border-emerald-500/30 text-emerald-200 flex items-center gap-1.5 font-mono text-[11px]">
                        <span className="font-bold text-emerald-400">ENTÃO:</span>
                        <span>{rule.actionTitle}</span>
                      </div>
                    </div>

                    {rule.actionPayload && (
                      <p className="text-[11px] text-zinc-400 font-mono pt-1 leading-relaxed whitespace-pre-line pl-1 border-l-2 border-indigo-500/40">
                        {rule.actionPayload}
                      </p>
                    )}
                  </div>

                  <div className="flex items-center gap-2 shrink-0">
                    {/* Test Trigger Button */}
                    <button
                      onClick={() => onSimulateTrigger?.(rule)}
                      className="flex items-center gap-1 px-2.5 py-1 rounded-lg bg-amber-500/10 hover:bg-amber-500/20 text-amber-300 border border-amber-500/30 text-[11px] font-semibold cursor-pointer transition-colors"
                      title="Disparar/Simular Gatilho Agora"
                    >
                      <Play size={10} />
                      <span>Simular</span>
                    </button>

                    {/* Switch Toggle */}
                    <button
                      onClick={() => handleToggle(rule.id)}
                      className={`text-[11px] px-2.5 py-1 rounded-lg font-mono font-semibold cursor-pointer border transition-colors ${
                        rule.isEnabled
                          ? 'bg-emerald-500/20 text-emerald-300 border-emerald-500/30'
                          : 'bg-zinc-800 text-zinc-500 border-zinc-700'
                      }`}
                    >
                      {rule.isEnabled ? 'ATIVO' : 'PAUSADO'}
                    </button>

                    {/* Delete */}
                    <button
                      onClick={() => handleDelete(rule.id)}
                      className="p-1 rounded text-zinc-600 hover:text-rose-400 transition-colors cursor-pointer"
                    >
                      <Trash2 size={13} />
                    </button>
                  </div>
                </div>
              </div>
            ))}
          </div>
        </div>

        {/* Footer */}
        <div className="flex items-center justify-between px-6 py-4 border-t border-zinc-800 bg-zinc-900/80">
          <div className="flex items-center gap-2 text-xs text-zinc-400">
            <ShieldCheck size={14} className="text-emerald-400" />
            <span>Execução local e segura integrada a Webhooks e MCP</span>
          </div>
          <button
            onClick={onClose}
            className="px-5 py-2 rounded-xl bg-zinc-800 hover:bg-zinc-700 text-white text-xs font-semibold cursor-pointer transition-colors"
          >
            Concluir
          </button>
        </div>
      </div>
    </div>
  );
};
