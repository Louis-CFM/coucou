import React from 'react';
import { AlertCircle, Check, X, ShieldAlert, Globe, Mail, Terminal } from 'lucide-react';
import { ToolConfirmationRequest } from '../../types';

interface ToolConfirmationModalProps {
  request: ToolConfirmationRequest | null;
  onApprove: (request: ToolConfirmationRequest) => void;
  onReject: (request: ToolConfirmationRequest) => void;
}

export const ToolConfirmationModal: React.FC<ToolConfirmationModalProps> = ({
  request,
  onApprove,
  onReject,
}) => {
  if (!request) return null;

  const getToolIcon = (type: string) => {
    switch (type) {
      case 'webhook':
        return <Globe size={18} className="text-cyan-400" />;
      case 'smtp':
        return <Mail size={18} className="text-amber-400" />;
      default:
        return <Terminal size={18} className="text-indigo-400" />;
    }
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/80 backdrop-blur-sm p-4 animate-in fade-in duration-150">
      <div className="w-full max-w-lg bg-zinc-900 border border-amber-500/30 rounded-2xl shadow-2xl overflow-hidden flex flex-col">
        {/* Header */}
        <div className="flex items-center gap-3 px-6 py-4 bg-amber-500/10 border-b border-amber-500/20">
          <div className="w-10 h-10 rounded-xl bg-amber-500/20 border border-amber-500/30 flex items-center justify-center text-amber-300">
            <ShieldAlert size={20} />
          </div>
          <div>
            <h2 className="text-sm font-semibold text-white">Confirmação de Ação Sensível</h2>
            <p className="text-[11px] text-amber-200/80">O assistente deseja executar uma ferramenta externa</p>
          </div>
        </div>

        {/* Details */}
        <div className="p-6 space-y-4">
          <div className="flex items-center gap-2.5 p-3 rounded-xl bg-zinc-950/60 border border-zinc-800">
            {getToolIcon(request.toolType)}
            <div>
              <div className="text-xs font-semibold text-zinc-200">{request.toolName}</div>
              <div className="text-[10px] text-zinc-500 font-mono capitalize">Tipo: {request.toolType}</div>
            </div>
          </div>

          <div className="space-y-1.5">
            <span className="text-xs font-semibold text-zinc-400">Resumo da Ação</span>
            <p className="text-xs text-zinc-200 bg-zinc-950/60 p-3 rounded-xl border border-zinc-800">
              {request.summary}
            </p>
          </div>

          <div className="space-y-1.5">
            <span className="text-xs font-semibold text-zinc-400">Parâmetros Enviados</span>
            <pre className="text-[11px] font-mono text-zinc-300 bg-zinc-950/90 p-3 rounded-xl border border-zinc-800 overflow-x-auto max-h-36">
              {JSON.stringify(request.parameters, null, 2)}
            </pre>
          </div>
        </div>

        {/* Actions */}
        <div className="flex items-center justify-end gap-3 px-6 py-4 border-t border-zinc-800 bg-zinc-900/80">
          <button
            onClick={() => onReject(request)}
            className="flex items-center gap-1.5 px-4 py-2 rounded-xl bg-zinc-800 hover:bg-zinc-700 text-zinc-300 text-xs font-medium cursor-pointer transition-colors"
          >
            <X size={14} />
            <span>Rejeitar</span>
          </button>
          <button
            onClick={() => onApprove(request)}
            className="flex items-center gap-1.5 px-5 py-2 rounded-xl bg-emerald-600 hover:bg-emerald-500 text-white text-xs font-semibold shadow-md shadow-emerald-600/30 cursor-pointer transition-colors"
          >
            <Check size={14} />
            <span>Aprovar e Executar</span>
          </button>
        </div>
      </div>
    </div>
  );
};
