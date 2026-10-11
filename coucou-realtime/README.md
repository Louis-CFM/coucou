# 🎙️ Coucou Copilot / Realtime Desktop Assistant

Camada de assistência contínua e não-intrusiva que atua paralelamente ao fluxo de trabalho do usuário no Windows 10/11 (64-bit).

---

## ⚡ Quickstart (Como Rodar e Testar)

### 1. Pré-requisitos
- **Node.js**: v18+ (recomendado Node 20+)
- **Rust & Cargo**: Toolchain `stable-x86_64-pc-windows-msvc`
- **Tauri CLI**: Instalado via dependências locais do projeto

### 2. Instalação das Dependências
No diretório `coucou-realtime`:
```powershell
cd g:\coucou-main\atulizacoescoucou\coucou-realtime
npm install
```

### 3. Execução em Modo de Desenvolvimento
```powershell
npm run tauri dev
```
> **Nota de Teste Web Rápido:** Você também pode rodar `npm run dev` para testar a interface do usuário imediatamente no navegador em `http://localhost:1420`.

### 4. Build de Produção (Instalador Windows)
```powershell
npm run tauri build
```
Os instaladores gerados estarão localizados em:
`src-tauri/target/release/bundle/msi/` ou `src-tauri/target/release/bundle/nsis/`.

---

## 🖥️ Arquitetura de Duas Janelas (Tauri 2)

O aplicativo foi projetado para operar com **duas janelas complementares**:

1. **Barra Flutuante (`floating_bar` - `floating.html`)**:
   - Dimensões: `460x56 px`
   - Características: `Always-on-top`, sem decorações (`decorations: false`), fundo translúcido (`transparent: true`), `skipTaskbar: true`.
   - Permite arrastar pela tela (`data-tauri-drag-region`).
   - Mini Waveform ao vivo, indicador de estado reativo (Ouvindo, Silenciado, Analisando, Falando), botões de Mudo, OCR e Expansão.

2. **Janela Principal de Controle (`main_window` - `index.html`)**:
   - Dimensões: `1120x740 px`
   - Alternada facilmente com o atalho `Alt + Space`.
   - Painel completo com **Seletor de Modo** (Realtime / Ultra / Eco), **Badge e Central de Agentes**, **Transcrição Contínua**, **Painel de Sugestões Táticas**, **Visão da Tela Ativa (OCR)** e **Configurações de Chave de API**.

---

## ⌨️ Atalhos Globais de Teclado (Windows)

| Atalho | Ação | Descrição |
|---|---|---|
| `Alt + Space` | **Alternar Janela Principal** | Abre/oculta o painel completo instantaneamente sem perder foco |
| `Alt + M` | **Mudo / Desmutar Microfone** | Ativa/desativa a captura de áudio local com feedback sonoro/visual |
| `Alt + S` | **Escanear Tela (OCR)** | Dispara captura da janela ativa em primeiro plano e injeta o texto como contexto |

---

## 🧠 Modos de Assistência

1. **Realtime (Voz Bidirecional de Baixa Latência)**:
   - Conexão WebSocket/WebRTC com a **OpenAI Realtime API** (`gpt-4o-realtime-preview`).
   - Entrada em PCM16 24kHz com detecção de voz no servidor (Server VAD).
   - Suporte a interrupção natural (**Barge-in**): quando você fala, a voz do assistente é cortada instantaneamente.
2. **Ultra (Reuniões & Sugestões Táticas)**:
   - Captura dupla simultânea: seu microfone + áudio dos outros participantes (WASAPI Loopback do Windows).
   - Separação de canais de voz com identificação de oradores e sugestões de contorno de objeções em tempo real.
3. **Eco (Otimizado por Lotes)**:
   - Transcrição em blocos VAD por trecho com menor consumo de tokens.

---

## 🔒 Segurança e Dados Locais
- **Banco de Dados Local**: SQLite persistente com esquema estruturado em `agents`, `agent_memories`, `sessions`, `session_entries` e `tools_config`.
- **Modo Demonstração Offline**: Se nenhuma chave da OpenAI for fornecida, o assistente entra automaticamente no modo simulação interativo para testes sem custo de API.
