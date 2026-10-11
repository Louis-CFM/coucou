export type AssistantMode = 'realtime' | 'ultra' | 'eco';

export type AssistantStatus = 'idle' | 'listening' | 'analyzing' | 'speaking' | 'executing' | 'muted';

export type AgentStateStatus = 'active' | 'monitoring' | 'idle';

export interface Agent {
  id: string;
  name: string;
  icon: string;
  tone: string;
  system_prompt: string;
  voice: 'alloy' | 'echo' | 'shimmer' | 'ash' | 'ballad' | 'coral' | 'sage' | 'verse' | string;
  language: string;
  is_active: boolean;
  status?: AgentStateStatus;
  tools?: string[];
  created_at?: string;
}

export interface AgentMemory {
  id: string;
  agent_id: string;
  category: 'preference' | 'project' | 'fact';
  content: string;
  importance: number;
  created_at?: string;
}

export interface Session {
  id: string;
  agent_id: string;
  title: string;
  mode: AssistantMode;
  started_at?: string;
  ended_at?: string;
  summary?: string;
}

export interface SessionEntry {
  id: string;
  session_id: string;
  speaker: 'user_mic' | 'remote_audio' | 'agent' | 'system';
  text: string;
  translation?: string;
  timestamp_ms: number;
  context_data?: string;
}

export interface ToolConfig {
  id: string;
  tool_type: 'webhook' | 'smtp' | 'mcp' | 'script';
  name: string;
  config_json: string;
  requires_confirmation: boolean;
  is_enabled: boolean;
}

export interface OcrResult {
  success: boolean;
  active_window: string;
  extracted_text: string;
  confidence: number;
  timestamp_ms: number;
}

export interface AudioDeviceInfo {
  name: string;
  is_default: boolean;
}

export interface InsightItem {
  id: string;
  type: 'tactical' | 'objection' | 'action_item' | 'key_point';
  title: string;
  description: string;
  timestamp: string;
}

export interface ToolConfirmationRequest {
  id: string;
  toolId: string;
  toolName: string;
  toolType: string;
  parameters: any;
  summary: string;
}

// 1. Modo Sussurro (Coach em Tempo Real)
export interface WhisperCoachTip {
  id: string;
  type: 'tactical' | 'pacing' | 'objection' | 'sentiment';
  message: string;
  timestamp: string;
  priority: 'high' | 'normal';
}

// 2. Memória de Pessoas e Clientes (Mini-CRM)
export interface ContactProfile {
  id: string;
  name: string;
  company: string;
  role: string;
  past_preferences: string[];
  past_objections: string[];
  last_agreements: string[];
  deal_value?: string;
  last_seen: string;
}

// 3. Detecção de Emoção e Ritmo
export interface EmotionPacingMetrics {
  userTalkRatioPercent: number;
  remoteTalkRatioPercent: number;
  detectedSentiment: 'entusiasmado' | 'neutro' | 'hesitante' | 'inseguro' | 'fechamento_favoravel';
  paceWordsPerMin: number;
  interruptionsCount: number;
}

// 4. Base de Conhecimento RAG Local
export interface KnowledgeDoc {
  id: string;
  title: string;
  category: 'playbook' | 'precos' | 'faq' | 'contrato';
  snippet: string;
  source: string;
}

// 5. Pós-Reunião Automático
export interface PostMeetingTask {
  id: string;
  title: string;
  assignee: string;
  deadline: string;
  completed: boolean;
}

export interface MeetingWrapUp {
  id: string;
  meetingTitle: string;
  durationMinutes: number;
  summaryExecutive: string;
  decisions: string[];
  tasks: PostMeetingTask[];
  followupEmail: {
    to: string;
    subject: string;
    body: string;
  };
}

// 6. Automações "Se Isso, Então Aquilo" (IFTTT por Voz & Contexto)
export type TriggerType = 'voice_keyword' | 'intent_closing' | 'screen_window' | 'objection_price';
export type ActionType = 'show_card' | 'dispatch_webhook' | 'create_contract' | 'coach_whisper';

export interface AutomationRule {
  id: string;
  name: string;
  triggerType: TriggerType;
  triggerPhrase: string; // Ex: "concorrente", "vamos fechar", "está caro"
  actionType: ActionType;
  actionTitle: string;
  actionPayload: string; // Detalhes do comparativo, payload do webhook ou dados do contrato
  requiresConfirmation: boolean;
  isEnabled: boolean;
  lastTriggered?: string;
}

// 7. Segundo Cérebro & Grafo de Conhecimento Autônomo
export type KnowledgeNodeType = 'idea' | 'problem' | 'project' | 'person' | 'insight';

export interface KnowledgeNode {
  id: string;
  label: string;
  type: KnowledgeNodeType;
  source: 'conversa' | 'tela_ocr' | 'anotacao';
  date: string;
  mentionsCount: number;
}

export interface KnowledgeEdge {
  fromNodeId: string;
  toNodeId: string;
  relationLabel: string;
  strength: number;
}

export interface BrainConnectionInsight {
  id: string;
  currentIdea: string;
  pastConnection: string;
  pastDate: string; // Ex: "Há 3 meses"
  explanation: string;
  relevancePercent: number;
}

export interface SuggestedProject {
  id: string;
  title: string;
  description: string;
  triggerTopics: string[];
  frequencyScore: string;
  suggestedActionPlan: string[];
}

// 8. Relatório Semanal de Você em Áudio (Friday Audio Briefing)
export interface WeeklyAudioBriefing {
  id: string;
  weekLabel: string; // Ex: "Semana 41 • 06 a 10 de Outubro"
  durationFormatted: string; // Ex: "02:15"
  audioNarratorVoice: string;
  spokenScript: string;
  achievements: string[];
  patternsAndRhythm: {
    talkRatioAvg: number;
    totalCalls: number;
    hoursRecorded: number;
    pacingAssessment: string;
  };
  areasToImprove: string[];
  nextWeekPriorities: {
    title: string;
    dayTime: string;
    contactOrContext: string;
  }[];
}

// 9. Comandos por Voz que Controlam o Computador (Jarvis com Confirmação e Auditoria)
export type StepStatus = 'pending' | 'executing' | 'completed' | 'waiting_confirmation' | 'rejected' | 'failed';

export interface JarvisPlanStep {
  id: string;
  order: number;
  description: string;
  toolType: 'app_launch' | 'filter_data' | 'send_email' | 'mcp_action' | 'file_operation';
  isSensitive: boolean;
  targetResource: string;
  status: StepStatus;
  executionResult?: string;
}

export interface JarvisVoiceCommandPlan {
  id: string;
  originalSpokenCommand: string;
  createdAt: string;
  overallStatus: 'analyzing' | 'in_progress' | 'waiting_user_approval' | 'completed' | 'cancelled';
  steps: JarvisPlanStep[];
}

export interface ActionAuditLogEntry {
  id: string;
  timestamp: string;
  command: string;
  executedStepsCount: number;
  status: 'concluido' | 'cancelado_pelo_usuario' | 'em_andamento';
  sensitiveActionConfirmedBy: string;
}

export type MindMapNodeType = 'central' | 'theme' | 'subtopic' | 'decision' | 'task_owner' | 'insight';

export interface MindMapNode {
  id: string;
  label: string;
  type: MindMapNodeType;
  parentId?: string;
  owner?: string;
  timestamp?: string;
  notes?: string;
  color?: string;
  isNew?: boolean;
}

export interface MindMapSession {
  id: string;
  title: string;
  mode: 'brainstorming' | 'aula' | 'planejamento';
  createdAt: string;
  isLiveRecording: boolean;
  nodes: MindMapNode[];
  summary: string;
}

export type ContentFormat = 'linkedin' | 'newsletter' | 'video_script' | 'thread';

export type WritingTone = 'punchy_provocative' | 'didactic_storytelling' | 'analytical_data' | 'executive_formal';

export interface GeneratedContentPiece {
  format: ContentFormat;
  title: string;
  body: string;
  estimatedReadTime: string;
  keyHooks: string[];
  hashtags?: string[];
}

export interface ContentRepurposingSession {
  id: string;
  sourceTitle: string;
  sourceType: 'meeting' | 'lecture' | 'podcast';
  durationMinutes: number;
  selectedTone: WritingTone;
  userStyleSample: string;
  pieces: Record<ContentFormat, GeneratedContentPiece>;
}
