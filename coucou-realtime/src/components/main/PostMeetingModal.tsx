import React, { useState } from 'react';
import {
  X,
  FileCheck2,
  Mail,
  CheckSquare,
  Copy,
  Check,
  Send,
  ExternalLink,
  Sparkles,
  Calendar,
  Clock,
} from 'lucide-react';
import { MeetingWrapUp } from '../../types';

interface PostMeetingModalProps {
  wrapUp: MeetingWrapUp | null;
  onClose: () => void;
  onSendEmail?: (email: { to: string; subject: string; body: string }) => void;
  onPushToNotion?: (tasks: any[]) => void;
}

export const PostMeetingModal: React.FC<PostMeetingModalProps> = ({
  wrapUp,
  onClose,
  onSendEmail,
  onPushToNotion,
}) => {
  const [copiedEmail, setCopiedEmail] = useState(false);
  const [emailSent, setEmailSent] = useState(false);
  const [notionPushed, setNotionPushed] = useState(false);

  if (!wrapUp) return null;

  const handleCopyEmail = () => {
    navigator.clipboard.writeText(
      `Para: ${wrapUp.followupEmail.to}\nAssunto: ${wrapUp.followupEmail.subject}\n\n${wrapUp.followupEmail.body}`
    );
    setCopiedEmail(true);
    setTimeout(() => setCopiedEmail(false), 2000);
  };

  const handleDispatchEmail = () => {
    onSendEmail?.(wrapUp.followupEmail);
    setEmailSent(true);
    setTimeout(() => setEmailSent(false), 2500);
  };

  const handlePushNotion = () => {
    onPushToNotion?.(wrapUp.tasks);
    setNotionPushed(true);
    setTimeout(() => setNotionPushed(false), 2500);
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/85 backdrop-blur-md p-4 animate-in fade-in duration-200">
      <div className="w-full max-w-3xl max-h-[90vh] bg-zinc-900 border border-zinc-800 rounded-3xl shadow-2xl overflow-hidden flex flex-col">
        {/* Header */}
        <div className="flex items-center justify-between px-6 py-4 border-b border-zinc-800 bg-zinc-900/80">
          <div className="flex items-center gap-2.5">
            <div className="w-9 h-9 rounded-xl bg-emerald-500/10 border border-emerald-500/20 flex items-center justify-center text-emerald-400">
              <FileCheck2 size={18} />
            </div>
            <div>
              <div className="flex items-center gap-2">
                <h2 className="text-sm font-semibold text-white">Pós-Reunião Automático (Ata & Follow-up)</h2>
                <span className="text-[10px] px-2 py-0.5 rounded-full bg-emerald-500/15 text-emerald-300 font-mono">
                  Gerado por IA
                </span>
              </div>
              <p className="text-[11px] text-zinc-400">
                {wrapUp.meetingTitle} • {wrapUp.durationMinutes} minutos de gravação
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

        {/* Content Tabs */}
        <div className="p-6 space-y-5 overflow-y-auto flex-1">
          {/* Executive Summary */}
          <div className="p-4 rounded-2xl bg-zinc-950/60 border border-zinc-800/80 space-y-2">
            <div className="flex items-center gap-1.5 text-xs font-semibold text-zinc-300">
              <Sparkles size={13} className="text-indigo-400" />
              <span>Resumo Executivo da Reunião</span>
            </div>
            <p className="text-xs text-zinc-300 leading-relaxed font-sans">
              {wrapUp.summaryExecutive}
            </p>
          </div>

          {/* Decisions Made */}
          <div className="space-y-2">
            <div className="flex items-center gap-1.5 text-xs font-semibold text-zinc-300">
              <CheckSquare size={13} className="text-cyan-400" />
              <span>Decisões & Acordos Firmados</span>
            </div>
            <div className="space-y-1.5">
              {wrapUp.decisions.map((dec, idx) => (
                <div
                  key={idx}
                  className="flex items-start gap-2 p-2.5 rounded-xl bg-zinc-950/40 border border-zinc-800 text-xs text-zinc-200"
                >
                  <span className="text-cyan-400 font-bold">•</span>
                  <span>{dec}</span>
                </div>
              ))}
            </div>
          </div>

          {/* Action Items with Assignee & Deadline */}
          <div className="space-y-2">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-1.5 text-xs font-semibold text-zinc-300">
                <Clock size={13} className="text-amber-400" />
                <span>Tarefas Acordadas com Responsável e Prazo</span>
              </div>
              <button
                onClick={handlePushNotion}
                className="flex items-center gap-1 text-[11px] text-indigo-400 hover:text-indigo-300 cursor-pointer transition-colors"
              >
                <ExternalLink size={11} />
                <span>{notionPushed ? 'Enviado para Notion!' : 'Exportar para Notion / Trello'}</span>
              </button>
            </div>

            <div className="grid grid-cols-1 md:grid-cols-2 gap-2">
              {wrapUp.tasks.map((task) => (
                <div
                  key={task.id}
                  className="p-3 rounded-xl bg-zinc-950/60 border border-zinc-800 flex items-start justify-between gap-2"
                >
                  <div>
                    <div className="text-xs font-medium text-zinc-200">{task.title}</div>
                    <div className="flex items-center gap-2 mt-1.5 text-[10px] text-zinc-500 font-mono">
                      <span className="px-1.5 py-0.5 rounded bg-zinc-800 text-zinc-300">
                        👤 {task.assignee}
                      </span>
                      <span>📅 {task.deadline}</span>
                    </div>
                  </div>
                </div>
              ))}
            </div>
          </div>

          {/* Follow-up Email Ready to Send */}
          <div className="p-4 rounded-2xl bg-zinc-950/80 border border-indigo-500/30 space-y-3">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-2">
                <Mail size={14} className="text-indigo-400" />
                <span className="text-xs font-semibold text-white">E-mail de Follow-up Pronto</span>
              </div>
              <div className="flex items-center gap-2">
                <button
                  onClick={handleCopyEmail}
                  className="flex items-center gap-1 text-[11px] px-2.5 py-1 rounded-lg bg-zinc-800 hover:bg-zinc-700 text-zinc-300 transition-colors cursor-pointer"
                >
                  {copiedEmail ? <Check size={11} className="text-emerald-400" /> : <Copy size={11} />}
                  <span>{copiedEmail ? 'Copiado!' : 'Copiar E-mail'}</span>
                </button>
                <button
                  onClick={handleDispatchEmail}
                  className="flex items-center gap-1 text-[11px] px-3 py-1 rounded-lg bg-indigo-600 hover:bg-indigo-500 text-white font-semibold transition-colors cursor-pointer"
                >
                  <Send size={11} />
                  <span>{emailSent ? 'Enviado!' : 'Disparar via SMTP'}</span>
                </button>
              </div>
            </div>

            <div className="space-y-1.5 text-xs text-zinc-400 font-mono">
              <div>Para: <span className="text-zinc-200">{wrapUp.followupEmail.to}</span></div>
              <div>Assunto: <span className="text-zinc-200">{wrapUp.followupEmail.subject}</span></div>
            </div>

            <pre className="p-3 rounded-xl bg-zinc-900 border border-zinc-800 text-xs text-zinc-300 font-sans whitespace-pre-wrap leading-relaxed max-h-40 overflow-y-auto">
              {wrapUp.followupEmail.body}
            </pre>
          </div>
        </div>

        {/* Footer */}
        <div className="flex items-center justify-end px-6 py-4 border-t border-zinc-800 bg-zinc-900/80">
          <button
            onClick={onClose}
            className="px-5 py-2 rounded-xl bg-zinc-800 hover:bg-zinc-700 text-white text-xs font-semibold cursor-pointer transition-colors"
          >
            Fechar e Salvar no Histórico
          </button>
        </div>
      </div>
    </div>
  );
};
