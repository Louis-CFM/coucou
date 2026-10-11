import React, { useState, useEffect } from 'react';
import { X, History, Search, Calendar, Clock, ChevronRight } from 'lucide-react';
import { Session } from '../../types';
import { storage } from '../../services/storage';

interface SessionsDrawerProps {
  isOpen: boolean;
  onClose: () => void;
  onSelectSession?: (session: Session) => void;
}

export const SessionsDrawer: React.FC<SessionsDrawerProps> = ({ isOpen, onClose, onSelectSession }) => {
  const [sessions, setSessions] = useState<Session[]>([]);
  const [search, setSearch] = useState('');

  useEffect(() => {
    if (isOpen) {
      storage.getSessions().then(setSessions);
    }
  }, [isOpen]);

  if (!isOpen) return null;

  const filtered = sessions.filter((s) =>
    s.title.toLowerCase().includes(search.toLowerCase()) ||
    (s.summary && s.summary.toLowerCase().includes(search.toLowerCase()))
  );

  return (
    <div className="fixed inset-0 z-50 flex justify-end bg-black/60 backdrop-blur-sm animate-in fade-in duration-150">
      <div className="w-96 h-full bg-zinc-900 border-l border-zinc-800 shadow-2xl flex flex-col">
        {/* Header */}
        <div className="flex items-center justify-between px-5 py-4 border-b border-zinc-800 bg-zinc-900/80">
          <div className="flex items-center gap-2">
            <History size={16} className="text-indigo-400" />
            <h2 className="text-sm font-semibold text-white">Histórico de Sessões</h2>
          </div>
          <button
            onClick={onClose}
            className="p-1 rounded-lg text-zinc-400 hover:text-white hover:bg-zinc-800 transition-colors cursor-pointer"
          >
            <X size={16} />
          </button>
        </div>

        {/* Search Input */}
        <div className="p-4 border-b border-zinc-800/60 bg-zinc-950/40">
          <div className="relative">
            <Search size={14} className="absolute left-3 top-2.5 text-zinc-500" />
            <input
              type="text"
              placeholder="Buscar por reunião ou assunto..."
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              className="w-full pl-9 pr-3 py-2 bg-zinc-950 border border-zinc-800 rounded-xl text-xs text-zinc-200 placeholder-zinc-600 focus:outline-none focus:border-indigo-500"
            />
          </div>
        </div>

        {/* Sessions list */}
        <div className="flex-1 overflow-y-auto p-4 space-y-2.5">
          {filtered.length === 0 ? (
            <div className="text-center py-12 text-zinc-500 text-xs">
              Nenhuma sessão encontrada.
            </div>
          ) : (
            filtered.map((s) => (
              <div
                key={s.id}
                onClick={() => onSelectSession?.(s)}
                className="group p-3 rounded-xl bg-zinc-950/40 border border-zinc-800 hover:border-indigo-500/40 hover:bg-zinc-850 transition-all cursor-pointer"
              >
                <div className="flex items-center justify-between mb-1.5">
                  <span className="text-xs font-semibold text-zinc-200 group-hover:text-white">
                    {s.title}
                  </span>
                  <span className="text-[9px] uppercase px-1.5 py-0.5 rounded bg-zinc-800 text-zinc-400 font-mono">
                    {s.mode}
                  </span>
                </div>

                {s.summary && (
                  <p className="text-[11px] text-zinc-400 line-clamp-2 leading-relaxed mb-2">
                    {s.summary}
                  </p>
                )}

                <div className="flex items-center justify-between text-[10px] text-zinc-500 pt-1 border-t border-zinc-800/40">
                  <div className="flex items-center gap-1">
                    <Calendar size={11} />
                    <span>{new Date(s.started_at || Date.now()).toLocaleDateString('pt-BR')}</span>
                  </div>
                  <div className="flex items-center gap-1 group-hover:text-indigo-400 transition-colors">
                    <span>Ver detalhes</span>
                    <ChevronRight size={12} />
                  </div>
                </div>
              </div>
            ))
          )}
        </div>
      </div>
    </div>
  );
};
