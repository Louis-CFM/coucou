import { useState, useEffect, useCallback } from 'react';
import { Agent, AgentMemory } from '../types';
import { storage } from '../services/storage';

export function useAgents() {
  const [agents, setAgents] = useState<Agent[]>([]);
  const [activeAgent, setActiveAgentState] = useState<Agent | null>(null);
  const [memories, setMemories] = useState<AgentMemory[]>([]);
  const [loading, setLoading] = useState(true);

  const loadAgents = useCallback(async () => {
    setLoading(true);
    try {
      const list = await storage.getAgents();
      setAgents(list);
      const active = list.find((a) => a.is_active) || list[0] || null;
      setActiveAgentState(active);
      if (active) {
        const mems = await storage.getMemories(active.id as string);
        setMemories(mems);
      }
    } catch (e) {
      console.error('Falha ao carregar agentes:', e);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    loadAgents();
  }, [loadAgents]);

  const selectAgent = useCallback(
    async (agentId: string) => {
      await storage.setActiveAgent(agentId);
      const list = await storage.getAgents();
      setAgents(list);
      const selected = list.find((a) => a.id === agentId) || null;
      setActiveAgentState(selected);
      if (selected) {
        const mems = await storage.getMemories(selected.id as string);
        setMemories(mems);
      }
    },
    []
  );

  const saveAgent = useCallback(
    async (agent: Agent) => {
      await storage.upsertAgent(agent);
      await loadAgents();
    },
    [loadAgents]
  );

  const removeAgent = useCallback(
    async (agentId: string) => {
      await storage.deleteAgent(agentId);
      await loadAgents();
    },
    [loadAgents]
  );

  const addMemory = useCallback(
    async (content: string, category: 'preference' | 'project' | 'fact', importance = 1) => {
      if (!activeAgent) return;
      const mem: AgentMemory = {
        id: `mem-${Date.now()}`,
        agent_id: activeAgent.id as string,
        category,
        content,
        importance,
        created_at: new Date().toISOString(),
      };
      await storage.addMemory(mem);
      const updated = await storage.getMemories(activeAgent.id as string);
      setMemories(updated);
    },
    [activeAgent]
  );

  const deleteMemory = useCallback(
    async (memoryId: string) => {
      if (!activeAgent) return;
      await storage.deleteMemory(activeAgent.id as string, memoryId);
      const updated = await storage.getMemories(activeAgent.id as string);
      setMemories(updated);
    },
    [activeAgent]
  );

  return {
    agents,
    activeAgent,
    memories,
    loading,
    selectAgent,
    saveAgent,
    removeAgent,
    addMemory,
    deleteMemory,
    reload: loadAgents,
  };
}
