import React, { useState } from 'react';
import {
  X,
  Sparkles,
  Share2,
  Copy,
  Check,
  Briefcase,
  Mail,
  Video,
  Hash,
  Sliders,
  RefreshCw,
  FileText,
  ThumbsUp,
  MessageSquare,
  Repeat,
  Send,
  Eye,
  CheckCircle2,
  Calendar,
  Layers,
  Wand2,
} from 'lucide-react';
import {
  ContentFormat,
  WritingTone,
  GeneratedContentPiece,
  ContentRepurposingSession,
} from '../../types';

interface ConversationToContentModalProps {
  isOpen: boolean;
  onClose: () => void;
}

const DEFAULT_SESSIONS: Record<string, ContentRepurposingSession> = {
  meeting: {
    id: 'session-reuniao-1',
    sourceTitle: 'Alinhamento Comercial & Implantação Q4 (Logix Tech)',
    sourceType: 'meeting',
    durationMinutes: 28,
    selectedTone: 'punchy_provocative',
    userStyleSample: 'Direto ao ponto, zero enrolação, focado em bastidores reais de vendas e tecnologia.',
    pieces: {
      linkedin: {
        format: 'linkedin',
        title: 'Como fechamos R$ 24k em 28 minutos sem dar 1 real de desconto',
        estimatedReadTime: '1.5 min de leitura',
        keyHooks: [
          'O cliente pediu 20% de desconto. Em vez de ceder, mudamos a régua da conversa.',
          'A maioria dos consultores perde margem no primeiro “está caro”. Aqui está o que fizemos diferente hoje:',
        ],
        hashtags: ['#VendasB2B', '#Negociação', '#SaaS', '#InteligênciaArtificial', '#Liderança'],
        body: `O cliente pediu 20% de desconto na reunião de hoje.

A reação padrão de 90% dos profissionais é correr para a planilha e cortar a margem.

Em vez disso, fizemos uma única pergunta:
“Qual é a meta de implantação que vocês precisam bater no primeiro trimestre?”

A resposta dele revelou o verdadeiro gargalo: eles não estavam preocupados com o preço. Estavam com medo de comprar um escopo gigante que levasse 6 meses para entrar em produção.

O ajuste foi cirúrgico:
1. Fatiamos o projeto em duas fases (Fase 1 com MVP funcional em 20 dias).
2. Mantivemos o valor integral de R$ 24.000 anual com pagamento semestral.
3. Garantimos soberania total de dados local com SQLite e conformidade LGPD.

Resultado: contrato fechado no valor cheio e cliente aliviado.

Lição de ouro para criadores e consultores:
Quando o cliente pede desconto, raramente é sobre o dinheiro. Na maioria das vezes, é sobre a percepção de risco. Reduza o risco de execução, e o preço deixa de ser o obstáculo.

Você costuma dar desconto de cara ou investiga a raiz da objeção? Deixe sua visão nos comentários 👇`,
      },
      newsletter: {
        format: 'newsletter',
        title: 'Edição #42: Desconstruindo uma Negociação de R$ 24k ao Vivo',
        estimatedReadTime: '3 min de leitura',
        keyHooks: ['Bastidores da call', 'Estrutura de precificação', 'Framework anti-desconto'],
        body: `Olá, equipe!

Hoje pela manhã tive uma daquelas reuniões que resumem com precisão por que vendas consultivas são um jogo de psicologia e posicionamento, e não de concessões baratas.

Nesta edição da nossa newsletter, quero abrir a ata e os bastidores reais dessa conversa.

### O Cenário
Reunião de alinhamento com a diretoria da Logix Tech. Escopo: automação de processos internos e camada de IA local no Windows.

Aos 14 minutos de call, veio a frase clássica:
“Adoramos a proposta, mas o orçamento aprovado para este trimestre comporta até 20% a menos.”

### Os 3 Movimentos que Salvaram a Margem

1. Não justifique o preço, investigue o cronograma:
Descobrimos que a dor latente era o prazo do Q1. Se entregássemos tudo de uma vez, eles não teriam braço para homologar.

2. A estratégia da Entrega Faseada:
MVP focado no gargalo imediato em 20 dias úteis. Fase 2 com módulos avançados em 40 dias. O orçamento anual continuou em R$ 24k.

3. Segurança jurídica como fechamento:
Apresentar a arquitetura com armazenamento local SQLite (sem enviar dados de clientes para a nuvem pública) foi o fator decisivo contra qualquer outro fornecedor.

### Takeaway para a sua Semana
Antes de conceder qualquer abatimento no seu serviço, pergunte-se: “O que nesta proposta está gerando insegurança no comprador?”. Resolva a segurança primeiro.

Um abraço e até a próxima edição!`,
      },
      video_script: {
        format: 'video_script',
        title: 'Roteiro Curto (Shorts/Reels): O Segredo para Nunca Mais Dar Desconto',
        estimatedReadTime: '55 segundos de vídeo',
        keyHooks: ['[0-3s] Gancho na tela com corte rápido', '[3-15s] O erro comum', '[15-45s] Os 3 passos', '[45-55s] CTA'],
        body: `[CENA 1 - GANCHO / 0-3s]
(Olhando direto para a câmera, tom firme e ritmo acelerado)
“Se você dá desconto na primeira vez que o cliente pede, você acabou de dizer que seu preço original era mentira.”

[CENA 2 - PROBLEMA REAL / 3-15s]
(Texto na tela: 'R$ 24.000 FECHADOS HOJE')
Hoje de manhã, um cliente pediu 20% de desconto na nossa reunião.
A maioria das pessoas entra em pânico e baixa a margem. Mas olha o que eu fiz em vez disso:

[CENA 3 - O FRAMEWORK / 15-40s]
Eu perguntei: “Qual é a meta real de prazo que você precisa bater?”
E ele confessou: o medo dele era demorar meses para ver resultado.
Então fizemos 3 ajustes:
Primeiro: Dividimos a entrega em duas etapas. A primeira entra no ar em 20 dias.
Segundo: Mantivemos o valor de 24 mil reais integral.
Terceiro: Mostramos que os dados dele ficam 100% seguros na própria máquina.

[CENA 4 - CONCLUSÃO & CTA / 40-55s]
Resultado: ele fechou na hora e agradeceu.
Desconto não resolve medo de entrega. Estrutura resolve.
Já salva este vídeo para lembrar disso na sua próxima negociação!`,
      },
      thread: {
        format: 'thread',
        title: 'Thread no X/Threads: 7 Lições Rápidas de Negociação Consultiva',
        estimatedReadTime: '1 min de leitura',
        keyHooks: ['1/7 O cliente pediu 20% de desconto...', '7/7 Recap final'],
        body: `1/7 O cliente pediu 20% de desconto hoje na reunião de R$ 24.000.
Aqui está o passo a passo exato de como fechamos no valor cheio em menos de 30 minutos (sem parecer arrogante): 🧵👇

2/7 A reação natural de quem está inseguro é dizer “vou ver o que consigo com a diretoria” e cortar a própria margem.
Isso destrói a percepção de autoridade do seu serviço.

3/7 O segredo é mudar a pergunta.
Não pergunte sobre o preço. Pergunte sobre a meta:
“O que precisa acontecer até o final deste trimestre para esse projeto ser considerado um sucesso absoluto para você?”

4/7 Na hora, a verdade apareceu:
Eles não estavam sem caixa. Eles estavam com medo de pagar caro por um projeto gigante que demorasse 6 meses para rodar.

5/7 A solução foi a Entrega Faseada:
• Fase 1: MVP pronto em 20 dias para bater a meta imediata.
• Fase 2: Módulos complementares nos 40 dias seguintes.
• Valor: R$ 24k mantido integralmente com pagamento semestral.

6/7 Moral da história:
Cliente não pede desconto porque quer economizar alguns trocados. Ele pede desconto para compensar o risco que sente ao te contratar. Elimine o risco e o preço deixa de ser o assunto.

7/7 Curtiu esse bastidor real?
Deixe seu like no primeiro tweet e me siga para mais lições práticas de vendas e inteligência artificial aplicada. 🚀`,
      },
    },
  },
};

export const ConversationToContentModal: React.FC<ConversationToContentModalProps> = ({
  isOpen,
  onClose,
}) => {
  const [selectedFormat, setSelectedFormat] = useState<ContentFormat>('linkedin');
  const [selectedTone, setSelectedTone] = useState<WritingTone>('punchy_provocative');
  const [session, setSession] = useState<ContentRepurposingSession>(DEFAULT_SESSIONS.meeting);
  const [editableBody, setEditableBody] = useState<string>(
    DEFAULT_SESSIONS.meeting.pieces.linkedin.body
  );
  const [isCopied, setIsCopied] = useState(false);
  const [isRegenerating, setIsRegenerating] = useState(false);

  // Update content when format changes
  const handleFormatChange = (fmt: ContentFormat) => {
    setSelectedFormat(fmt);
    setEditableBody(session.pieces[fmt].body);
    setIsCopied(false);
  };

  const handleCopy = () => {
    navigator.clipboard.writeText(editableBody);
    setIsCopied(true);
    setTimeout(() => setIsCopied(false), 2000);
  };

  const handleRegenerate = () => {
    setIsRegenerating(true);
    setTimeout(() => {
      setIsRegenerating(false);
      // Simulate tone adjustment
      if (selectedTone === 'analytical_data') {
        setEditableBody(
          editableBody +
            '\n\n[Métricas Analíticas Anexadas]: ROI estimado de 3.8x no primeiro ano com redução de 40% no tempo de ciclo.'
        );
      }
    }, 800);
  };

  if (!isOpen) return null;

  const currentPiece = session.pieces[selectedFormat];

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/80 backdrop-blur-md p-4 animate-in fade-in duration-150">
      <div className="bg-[#101014] border border-zinc-800 rounded-3xl w-full max-w-5xl h-[88vh] flex flex-col shadow-2xl overflow-hidden font-sans text-zinc-100">
        {/* Top Header */}
        <div className="flex items-center justify-between px-6 py-4 border-b border-zinc-800/80 bg-zinc-950/60 shrink-0">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 rounded-2xl bg-gradient-to-tr from-pink-600 via-rose-500 to-amber-500 flex items-center justify-center shadow-lg shadow-pink-500/25">
              <Wand2 size={20} className="text-white" />
            </div>
            <div>
              <div className="flex items-center gap-2.5">
                <h2 className="text-base font-bold text-white tracking-tight">
                  Conversa Vira Conteúdo
                </h2>
                <span className="px-2.5 py-0.5 rounded-full text-[11px] font-semibold bg-rose-500/10 text-rose-400 border border-rose-500/30">
                  Repurposing Engine
                </span>
              </div>
              <p className="text-xs text-zinc-400">
                Transforme gravações de reuniões, aulas ou podcasts em posts prontos no seu estilo de escrita
              </p>
            </div>
          </div>

          {/* Quick Actions */}
          <div className="flex items-center gap-2">
            <button
              onClick={handleRegenerate}
              disabled={isRegenerating}
              className="flex items-center gap-1.5 px-3 py-1.5 rounded-xl bg-zinc-900 hover:bg-zinc-800 text-zinc-300 border border-zinc-700 text-xs font-semibold transition-all cursor-pointer"
            >
              <RefreshCw size={13} className={isRegenerating ? 'animate-spin text-pink-400' : ''} />
              <span>{isRegenerating ? 'Regerando...' : 'Regerar Variação'}</span>
            </button>

            <button
              onClick={handleCopy}
              className="flex items-center gap-1.5 px-3.5 py-1.5 rounded-xl bg-rose-600 hover:bg-rose-500 text-white text-xs font-semibold transition-all cursor-pointer shadow-md shadow-rose-600/30"
            >
              {isCopied ? <Check size={14} /> : <Copy size={14} />}
              <span>{isCopied ? 'Copiado!' : 'Copiar Texto'}</span>
            </button>

            <button
              onClick={onClose}
              className="p-2 rounded-xl bg-zinc-900 hover:bg-zinc-800 text-zinc-400 hover:text-white border border-zinc-800 transition-all cursor-pointer ml-1"
            >
              <X size={16} />
            </button>
          </div>
        </div>

        {/* Source Ingestion & Tone Calibration Bar */}
        <div className="px-6 py-3 bg-zinc-900/60 border-b border-zinc-800/80 flex flex-wrap items-center justify-between gap-3 text-xs shrink-0">
          <div className="flex items-center gap-2">
            <span className="font-semibold text-zinc-400">Fonte:</span>
            <span className="px-2.5 py-1 rounded-lg bg-zinc-950 text-zinc-200 border border-zinc-800 font-medium">
              🎙️ {session.sourceTitle} ({session.durationMinutes} min)
            </span>
          </div>

          {/* Tone Selector */}
          <div className="flex items-center gap-2">
            <span className="font-semibold text-zinc-400 flex items-center gap-1">
              <Sliders size={12} className="text-rose-400" />
              Tom de Voz:
            </span>
            <select
              value={selectedTone}
              onChange={(e) => setSelectedTone(e.target.value as WritingTone)}
              className="bg-zinc-950 border border-zinc-800 rounded-lg px-2.5 py-1 text-xs text-zinc-200 focus:outline-none focus:border-rose-500"
            >
              <option value="punchy_provocative">⚡ Direto & Provocador (Punchy)</option>
              <option value="didactic_storytelling">📖 Didático & Storytelling</option>
              <option value="analytical_data">📊 Analítico & Baseado em Dados</option>
              <option value="executive_formal">👔 Executivo & Corporativo</option>
            </select>
          </div>

          <div className="text-[11px] text-zinc-400 italic">
            Calibrado para: <strong className="text-zinc-300">“Zero enrolação, focado em bastidores reais”</strong>
          </div>
        </div>

        {/* Format Switcher Pills */}
        <div className="flex items-center px-6 pt-3 pb-2 gap-2 bg-[#0c0c10] border-b border-zinc-800/60 shrink-0">
          <button
            onClick={() => handleFormatChange('linkedin')}
            className={`flex items-center gap-2 px-4 py-2 rounded-xl text-xs font-semibold transition-all cursor-pointer ${
              selectedFormat === 'linkedin'
                ? 'bg-blue-600/20 text-blue-300 border border-blue-500/50 shadow-sm'
                : 'bg-zinc-900/80 text-zinc-400 hover:text-white border border-transparent'
            }`}
          >
            <Briefcase size={14} className={selectedFormat === 'linkedin' ? 'text-blue-400' : ''} />
            <span>Post LinkedIn</span>
          </button>

          <button
            onClick={() => handleFormatChange('newsletter')}
            className={`flex items-center gap-2 px-4 py-2 rounded-xl text-xs font-semibold transition-all cursor-pointer ${
              selectedFormat === 'newsletter'
                ? 'bg-emerald-600/20 text-emerald-300 border border-emerald-500/50 shadow-sm'
                : 'bg-zinc-900/80 text-zinc-400 hover:text-white border border-transparent'
            }`}
          >
            <Mail size={14} className={selectedFormat === 'newsletter' ? 'text-emerald-400' : ''} />
            <span>Newsletter (Substack/Beehiiv)</span>
          </button>

          <button
            onClick={() => handleFormatChange('video_script')}
            className={`flex items-center gap-2 px-4 py-2 rounded-xl text-xs font-semibold transition-all cursor-pointer ${
              selectedFormat === 'video_script'
                ? 'bg-rose-600/20 text-rose-300 border border-rose-500/50 shadow-sm'
                : 'bg-zinc-900/80 text-zinc-400 hover:text-white border border-transparent'
            }`}
          >
            <Video size={14} className={selectedFormat === 'video_script' ? 'text-rose-400' : ''} />
            <span>Roteiro de Vídeo (Reels/Shorts)</span>
          </button>

          <button
            onClick={() => handleFormatChange('thread')}
            className={`flex items-center gap-2 px-4 py-2 rounded-xl text-xs font-semibold transition-all cursor-pointer ${
              selectedFormat === 'thread'
                ? 'bg-cyan-600/20 text-cyan-300 border border-cyan-500/50 shadow-sm'
                : 'bg-zinc-900/80 text-zinc-400 hover:text-white border border-transparent'
            }`}
          >
            <Hash size={14} className={selectedFormat === 'thread' ? 'text-cyan-400' : ''} />
            <span>Thread (X / Threads)</span>
          </button>
        </div>

        {/* Content Body & Side Metadata */}
        <div className="flex-1 flex overflow-hidden">
          {/* Main Editable Editor */}
          <div className="flex-1 p-6 overflow-y-auto flex flex-col gap-3 bg-[#09090b]">
            <div className="flex items-center justify-between pb-2 border-b border-zinc-800">
              <h3 className="text-sm font-bold text-white flex items-center gap-2">
                <FileText size={16} className="text-rose-400" />
                {currentPiece.title}
              </h3>
              <span className="text-xs text-zinc-400 font-mono">
                {currentPiece.estimatedReadTime}
              </span>
            </div>

            {/* Editable Text Area */}
            <textarea
              value={editableBody}
              onChange={(e) => setEditableBody(e.target.value)}
              rows={16}
              className="w-full flex-1 p-4 rounded-2xl bg-zinc-950/80 border border-zinc-800 text-zinc-200 text-xs md:text-sm font-sans leading-relaxed focus:outline-none focus:border-rose-500 resize-none font-normal"
              placeholder="O conteúdo gerado aparecerá aqui para você editar ou copiar..."
            />

            {/* LinkedIn-Style Preview Card simulation when LinkedIn is selected */}
            {selectedFormat === 'linkedin' && (
              <div className="p-3.5 rounded-2xl bg-zinc-900/50 border border-zinc-800 flex items-center justify-between text-xs text-zinc-400">
                <div className="flex items-center gap-4">
                  <span className="flex items-center gap-1.5 hover:text-blue-400 cursor-pointer">
                    <ThumbsUp size={14} /> Curtir
                  </span>
                  <span className="flex items-center gap-1.5 hover:text-blue-400 cursor-pointer">
                    <MessageSquare size={14} /> Comentar
                  </span>
                  <span className="flex items-center gap-1.5 hover:text-blue-400 cursor-pointer">
                    <Repeat size={14} /> Compartilhar
                  </span>
                  <span className="flex items-center gap-1.5 hover:text-blue-400 cursor-pointer">
                    <Send size={14} /> Enviar
                  </span>
                </div>
                <span className="text-[11px] font-mono text-zinc-500">
                  {editableBody.length} caracteres
                </span>
              </div>
            )}
          </div>

          {/* Right Sidebar: Hooks & Optimization */}
          <div className="w-80 bg-zinc-950/90 border-l border-zinc-800 p-5 flex flex-col gap-5 overflow-y-auto shrink-0">
            {/* Box 1: Ganchos Magnéticos (Hooks) */}
            <div>
              <div className="flex items-center justify-between mb-2">
                <h4 className="text-xs font-bold text-white uppercase tracking-wider flex items-center gap-1.5">
                  <Sparkles size={13} className="text-amber-400" />
                  Ganchos Alternativos
                </h4>
                <span className="text-[10px] text-zinc-500 font-mono">Alta Retenção</span>
              </div>
              <div className="flex flex-col gap-2">
                {currentPiece.keyHooks.map((hook, idx) => (
                  <div
                    key={idx}
                    onClick={() => {
                      setEditableBody(hook + '\n\n' + editableBody);
                    }}
                    title="Clique para usar como primeira frase"
                    className="p-2.5 rounded-xl bg-zinc-900 hover:bg-zinc-850 border border-zinc-800 hover:border-amber-500/50 text-xs text-zinc-300 leading-snug cursor-pointer transition-all"
                  >
                    “{hook}”
                  </div>
                ))}
              </div>
            </div>

            {/* Box 2: Hashtags & Distribuição */}
            {currentPiece.hashtags && (
              <div>
                <h4 className="text-xs font-bold text-white uppercase tracking-wider mb-2">
                  Tags Recomendadas
                </h4>
                <div className="flex flex-wrap gap-1.5">
                  {currentPiece.hashtags.map((tag, idx) => (
                    <span
                      key={idx}
                      className="px-2 py-0.5 rounded-lg bg-zinc-900 border border-zinc-800 text-[11px] text-zinc-400 font-mono"
                    >
                      {tag}
                    </span>
                  ))}
                </div>
              </div>
            )}

            {/* Box 3: Benefício para Criadores & Consultores */}
            <div className="mt-auto p-4 rounded-2xl bg-gradient-to-br from-rose-950/30 to-pink-950/30 border border-rose-500/30 flex flex-col gap-2">
              <div className="flex items-center gap-1.5 text-rose-300 font-semibold text-xs">
                <CheckCircle2 size={14} />
                <span>Zero Esforço Criativo Extra</span>
              </div>
              <p className="text-[11px] text-zinc-400 leading-relaxed">
                Você apenas faz sua reunião ou grava seu podcast normalmente. O Coucou Copilot extrai o valor e produz 4 peças de autoridade no seu tom.
              </p>
              <button
                onClick={handleCopy}
                className="w-full mt-1 py-2 px-3 rounded-xl bg-rose-600 hover:bg-rose-500 text-white font-semibold text-xs flex items-center justify-center gap-1.5 transition-all cursor-pointer shadow-md shadow-rose-600/30"
              >
                {isCopied ? <Check size={14} /> : <Copy size={14} />}
                <span>{isCopied ? 'Copiado para o Clipboard!' : 'Copiar Texto Agora'}</span>
              </button>
            </div>
          </div>
        </div>

        {/* Footer info */}
        <div className="px-6 py-3 bg-zinc-950 border-t border-zinc-800/80 flex items-center justify-between text-xs text-zinc-400 shrink-0">
          <div className="flex items-center gap-2">
            <span className="w-2 h-2 rounded-full bg-rose-400" />
            <span>
              Suas ideias viram autoridade digital sem você gastar 2 horas escrevendo do zero.
            </span>
          </div>

          <div className="flex items-center gap-3">
            <button
              onClick={() => alert('Rascunho salvo no histórico de conteúdos da sua conta!')}
              className="text-zinc-400 hover:text-white transition-colors cursor-pointer text-xs"
            >
              Salvar Rascunho
            </button>
            <span className="text-zinc-700">•</span>
            <button
              onClick={() => alert('Integração com buffer/social media em breve!')}
              className="text-zinc-400 hover:text-white transition-colors cursor-pointer text-xs"
            >
              Agendar Publicação
            </button>
          </div>
        </div>
      </div>
    </div>
  );
};
