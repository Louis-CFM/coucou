import React from 'react';
import { Agent } from '../../types';
import { Sparkles, Briefcase, Users, Cpu, ShieldCheck } from 'lucide-react';

interface AgentBadgeProps {
  agent: Agent | null;
  onClick?: () => void;
}

export const AgentBadge: React.FC<AgentBadgeProps> = ({ agent, onClick }) => {
  const getIcon = (iconName?: string) => {
    switch (iconName) {
      case 'Briefcase':
        return <Briefcase size={14} className="text-indigo-400" />;
      case 'Users':
        return <Users size={14} className="text-emerald-400" />;
      case 'Cpu':
        return <Cpu size={14} className="text-cyan-400" />;
      default:
        return <Sparkles size={14} className="text-violet-400" />;
    }
  };

  if (!agent) {
    return (
      <div className="flex items-center gap-2 px-3 py-1.5 rounded-full bg-zinc-900 border border-zinc-800 text-xs text-zinc-400">
        <Sparkles size={14} />
        <span>Nenhum agente ativo</span>
      </div>
    );
  }

  return (
    <button
      onClick={onClick}
      className="group flex items-center gap-2.5 px-3 py-1.5 rounded-full bg-zinc-900/90 hover:bg-zinc-800/90 border border-zinc-800 hover:border-indigo-500/40 transition-all duration-200 cursor-pointer shadow-sm hover:shadow-indigo-500/10"
      title="Clique para alternar ou gerenciar agentes"
    >
      <div className="w-5 h-5 rounded-full bg-indigo-500/10 flex items-center justify-center border border-indigo-500/20 group-hover:scale-105 transition-transform">
        {getIcon(agent.icon)}
      </div>
      <div className="flex flex-col text-left">
        <div className="flex items-center gap-1.5">
          <span className="text-xs font-semibold text-zinc-200 group-hover:text-white transition-colors">
            {agent.name}
          </span>
          <span className="text-[10px] px-1.5 py-0.2 rounded-full bg-indigo-500/15 text-indigo-300 font-mono">
            {agent.voice}
          </span>
        </div>
      </div>
      <ShieldCheck size={12} className="text-zinc-500 group-hover:text-indigo-400 ml-1 transition-colors" />
    </button>
  );
};
