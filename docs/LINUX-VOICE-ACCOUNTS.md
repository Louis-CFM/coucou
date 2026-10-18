# Mochi: contas CLI e conversa em português de Portugal

A versão Linux `0.5.1-mochi.2` integra a conversa contínua desta branch com o
fork de companions `eeb7844`, preservando as suas correções de áudio, os
históricos por provider e o fluxo Ollama. A integração inicial de contas está
em `a6479f0`; a voz em `35dbe2e`. O módulo Super e a configuração da estação
são geridos em `sysworkspace`, branch `sistema/coucou-super-voz`.

## Conversa e ferramentas

Codex usa o `codex app-server` instalado, autenticado com a conta ChatGPT.
Gravity usa o `agy` instalado e a sua conta/modelos. As credenciais ficam sob
gestão dos próprios CLIs; o Mochi não copia tokens. Não é preciso uma chave API
OpenAI/Google para estas conversas. Os limites das contas continuam aplicáveis.
O chat mantém a sessão nativa e as ferramentas, configurações, skills e MCP
do CLI. `cliWorkspace` escolhe o diretório; o acesso completo exige a opção
explícita `cliFullAccess`. As aprovações nativas continuam a exigir um clique.

`coucou --voice-session` alterna uma conversa contínua na instância única.
Dizer «Codex», «Gravity», «Claude», «Gemini» ou «Ollama» seleciona o pet, também com um
pedido na mesma frase. Claude e Gemini usam os modelos dessa família oferecidos
pelo Gravity, sem ativar APIs pagas. Cada pet mantém o seu próprio contexto.
As frases seguintes vão para o pet selecionado. Mencionar um nome no meio de
uma frase não muda o destino. Antes da primeira seleção, não há envio ao CLI.

Super novamente, «parar conversa», «desligar microfone», ou 60 segundos sem
conversa terminam a sessão. O intervalo é configurável entre 15 e 600 segundos;
o tempo a executar ferramentas ou a falar não conta. «Ditado» entrega o
microfone ao Flow, se já estiver ativado. O microfone fecha antes de transcrever,
executar e reproduzir a resposta. Uma exclusão mútua espera pela libertação da
captação anterior; não depende de um atraso fixo. O hotword fica suspenso depois
de terminar, para o microfone não voltar a abrir automaticamente.

O botão para aprender a pronúncia recolhe um nome e guarda só o que o ASR
transcreveu em `voicePetAliases`. O áudio é descartado. Isto aprende variantes
de escrita, não treina um perfil biométrico nem adapta os pesos do modelo.

## Voz escolhida: Raquel, pt-PT

O utilizador rejeitou Miro e Dii pela falta de naturalidade e fluidez. Depois
de ouvir Qwen masculina/feminina e Microsoft Duarte/Raquel, escolheu **Raquel**.
Não há modelo Piper selecionado implicitamente.

A transcrição usa o Parakeet já instalado, localmente. Para sintetizar a voz,
o texto da resposta é enviado ao Read Aloud da Microsoft através de
[`edge-tts`](https://github.com/rany2/edge-tts), cliente **não oficial**.
O áudio do microfone não é enviado ao serviço de voz. O teste não exigiu chave
API, subscrição Microsoft ou configuração de faturação. Isto não garante
disponibilidade permanente ou condições futuras do serviço. Se falhar, a
resposta continua em texto; não há mudança automática para API paga ou outra voz.

Preparar apenas as dependências do projeto:

```sh
python3 linux/prepare-edge-voice.py
```

O script cria `.build/edge-voice-env` com `uv` e dependências fixadas por versão
e hash em `linux/requirements-edge-voice.txt`. Não instala ferramentas globais.
Na build integrada, escolher **Raquel · pt-PT** em Voz → Respostas e usar o
caminho Python impresso pelo script em **Ambiente da voz (Python)**
(`edgeVoicePython`). O prefixo `~/` é expandido para a pasta pessoal. A preferência Flow correspondente é `voiceOutput: "edge"`.
Usar **Ouvir** para verificar. A síntese passa o texto por stdin, mantém MP3 em
memória, limita tamanho/tempo e termina apenas o seu próprio processo ao cancelar.
Não remover o ambiente enquanto a app estiver configurada para o usar.

## Avaliação no equipamento

Ryzen AI 9 HX 370, 32 GB RAM, RTX 4060 Laptop 8 GB. Resultados de frases
sintéticas, não de gravações do utilizador:

| Candidato | Resultado observado |
| --- | --- |
| Piper Miro/Dii, CPU | Síntese quente 0,34–0,39 s; ambos rejeitados pelo utilizador |
| Parakeet, CPU | Transcrição quente 0,43–0,46 s para as amostras sintéticas; nomes próprios com erros |
| Qwen3-TTS 1.7B VoiceDesign, GPU | Carga 3,14 s; 8,2–10,0 s para 9,2–9,8 s de áudio; pico 4,3 GB VRAM |
| Microsoft Duarte, online | Primeiro áudio 1,80 s; amostra completa 2,68 s |
| Microsoft Raquel, online | Primeiro áudio 2,15 s; amostra completa 4,00 s; preferida pelo utilizador |

Qwen foi executado com BF16/SDPA, sem Flash Attention e sem otimizações de
streaming. Estes tempos não são um limite do hardware nem uma garantia futura.
As amostras não validam a precisão do reconhecimento da voz real do utilizador.
O ensaio de teclado, microfone e retorno acústico fica para a build integrada.

`linux/evaluate-voices.py` reproduz as amostras com `--engine qwen` (offline,
modelo local obrigatório) ou `--engine edge` (online explícito). Qwen foi
avaliado com `qwen-tts==0.1.1`, `torch==2.14.1`, `transformers==4.57.3`,
`soundfile==0.14.0` e `accelerate==1.12.0`, Python 3.11, modelo
`Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign`, revisão
`5ecdb67327fd37bb2e042aab12ff7391903235d3`.
Modelos, ambientes, logs e amostras ficam em `.build/`, fora do Git.
`linux/prepare-local-voices.py` conserva apenas a reprodução da avaliação Piper.

## Voz incluída em subscrições

O Codex 0.163.0 expõe um protocolo experimental de áudio. A descoberta nativa
da conta mostrou vozes, incluindo `porto`, mas o catálogo não prova acesso ao
serviço. Testes sem microfone, sem chaves API e com uma thread temporária própria:
WebSocket recusou a autenticação ChatGPT; WebRTC recebeu SDP, mas o canal de
controlo falhou com 404, ou 403 com o endereço experimental do backend ChatGPT.
O problema corresponde ao [relato no Codex](https://github.com/openai/codex/issues/35094).
Não há fallback para API nem compra de créditos. Não usar esta via como solução
funcional. A [voz do desktop](https://learn.chatgpt.com/docs/pricing) usa o
orçamento Codex partilhado, não é a mesma franquia de voz do ChatGPT Chat.

[Gemini Live](https://support.google.com/gemini/answer/15274899?hl=en) é uma
funcionalidade da aplicação. Não foi encontrada uma interface oficial estável
para reutilizar essa voz no Mochi com a conta do Gravity. Os benefícios de
subscrição não devem ser tratados como acesso genérico à
[API Gemini](https://ai.google.dev/gemini-api/docs/billing).

## Instalação da versão integrada

A integração conserva os providers locais, atalhos Ctrl+Alt, configuração de
áudio e os pets separados. Super usa só `--voice-session`; `--shortcut voiceTalk`
mantém a conversa manual anterior. O feedback inclui o ID do pet escolhido,
para a bolha não ser atribuída ao Ollama quando a resposta é de um CLI.
Construir o RPM com `linux/build-fedora-rpm.sh` no contentor do projeto;
a receita conserva o relay oficial verificado. Não iniciar uma segunda app
com a mesma identidade Tauri. Instalar o RPM, preparar o ambiente de voz e
aplicar os alvos revistos do sysworkspace. O `binds.lua` deve conservar os
atalhos existentes. As versões macOS e o seu Info.plist não foram alterados.
Os testes de protocolo, parser, contexto, cancelamento e eventos UI não
substituem a validação manual final com o hardware real.

Validação desta implementação: 445 testes JavaScript, TypeScript e build Vite;
507 testes Rust da app e 34 do relay, mais a síntese online pelo caminho real
Rust → Python → MP3. O ensaio da ponte Raquel gerou 37 152 bytes em 3,71 s.
O sysworkspace passou 423 testes (2 ignorados) e a verificação de configuração
do Hyprland. Nenhuma destas verificações abriu o microfone do utilizador.
