// UI strings: English is the key, PT-BR lives in the table.
// Missing entries fall back to the key itself (readable English), so the UI
// can be translated incrementally without ever showing a blank label.

import { State } from "./state";

const PT: Record<string, string> = {
  // Header
  "Overview": "Visão geral",
  "Ask": "Perguntar",
  "Drop": "Anexar",
  "Mute": "Mudo",
  "Language: English — switch in Settings": "Idioma: Português (Brasil) — trocar em Configurações",
  "Language: Portuguese (Brazil) — switch in Settings": "Idioma: Português (Brasil) — trocar em Configurações",
  // Overview / empty
  "Nothing running right now.": "Nada rodando no momento.",
  "Ask Claude": "Perguntar ao Claude",
  "Ask AI": "Perguntar à IA",
  "Drop a file or window, or ask me anything.": "Solte um arquivo ou janela, ou me pergunte qualquer coisa.",
  "in progress": "em curso",
  // Approval
  "Allow": "Permitir",
  "Deny": "Negar",
  "Always allow": "Sempre permitir",
  "Refuse": "Recusar",
  "wants to run": "quer executar",
  "needs permission": "precisa de permissão",
  "is asking a question": "está fazendo uma pergunta",
  "needs an answer.": "precisa de resposta.",
  "Answer in your terminal — Coucou can't reply for you yet.": "Responda no terminal — o Coucou ainda não responde por você.",
  // Finished / error
  "finished": "terminou",
  "Session finished": "Sessão terminada",
  "Workflow stopped.": "Fluxo parado.",
  "Session stopped on an error.": "Sessão parada por erro.",
  "No detail available.": "Sem detalhes.",
  "Too many slaps at once.": "Tapas demais de uma vez.",
  "Copy": "Copiar",
  "Open result": "Abrir resultado",
  // Finished / error / question
  "See terminal": "Ver terminal",
  "Open terminal": "Abrir terminal",
  "OK": "OK",
  "Retry": "Tentar de novo",
  "Open in n8n": "Abrir no n8n",
  "Open": "Abrir",
  "Close": "Fechar",
  "Cancel": "Cancelar",
  "Back": "Voltar",
  "Save": "Salvar",
  "Remove": "Remover",
  "Refresh": "Atualizar",
  "Settings…": "Configurações…",
  "Open Visual Studio Code": "Abrir Visual Studio Code",
  "Open n8n": "Abrir n8n",
  // Upload / choose
  "Drop your files here": "Solte seus arquivos aqui",
  "Drop your file here": "Solte seu arquivo aqui",
  "PDF": "PDF",
  "Images": "Imagens",
  "Code": "Código",
  "Docs": "Documentos",
  "Choose file": "Escolher arquivo",
  "Uploading": "Enviando",
  "File": "Arquivo",
  "file": "arquivo",
  "files": "arquivos",
  "What do you want to do with it?": "O que fazer com ele?",
  "Ask a question": "Fazer uma pergunta",
  "is ready.": "está pronto.",
  "Ask about it": "Perguntar sobre ele",
  "Send by mail": "Enviar por e-mail",
  "To": "Para",
  "Subject": "Assunto",
  "Message (optional)": "Mensagem (opcional)",
  "Send": "Enviar",
  // Chat
  "Ask me anything…": "Pergunte qualquer coisa…",
  "Continue…": "Continuar…",
  "New chat": "Nova conversa",
  // Integrations
  "Integration": "Integração",
  "Hooks not installed": "Hooks não instalados",
  "Key not configured": "Chave não configurada",
  "Nothing playing": "Nada tocando",
  "Now playing": "Tocando agora",
  "Paused": "Pausado",
  "Open Spotify": "Abrir Spotify",
  "Open Spotify and play something": "Abra o Spotify e toque algo",
  "Open WhatsApp Web in your browser": "Abra o WhatsApp Web no navegador",
  "No unread messages": "Nenhuma mensagem nova",
  "1 unread message": "1 mensagem nova",
  "{n} unread messages": "{n} mensagens novas",
  "New messages": "Mensagens novas",
  "Open WhatsApp": "Abrir WhatsApp",
  "1 unread mail": "1 e-mail novo",
  "{n} unread mails": "{n} e-mails novos",
  "Inbox zero — nothing unread": "Caixa zerada — nada novo",
  "Inbox": "Caixa de entrada",
  "unread": "novos",
  "Email address": "Endereço de e-mail",
  "App password": "Senha de app",
  "Client ID": "ID do cliente",
  "Client secret": "Segredo do cliente",
  "OAuth client ID": "ID do cliente OAuth",
  "OAuth client secret": "Segredo do cliente OAuth",
  "Sign in with Google": "Entrar com Google",
  "Sign out": "Sair",
  "Signed in as": "Logado como",
  "Signed out.": "Deslogado.",
  "Signed in with Google.": "Logado com Google.",
  "App password saved (IMAP fallback).": "Senha de app salva (IMAP reserva).",
  "Sign in with Google (works behind firewalls), or use an app password.":
    "Entre com Google (funciona atrás de firewall) ou use senha de app.",
  "Browser opened — approve, then come back.": "Navegador aberto — aprove e volte.",
  "Paste the OAuth client ID and secret first.": "Cole o ID e o segredo OAuth primeiro.",
  // Settings window
  "General": "Geral",
  "Sound": "Som",
  "Auto-close": "Fechamento auto",
  "seconds after you leave the island": "segundos após sair da ilha",
  "Island lives on": "Ilha fica em",
  "Main display": "Tela principal",
  "Display under the cursor": "Tela sob o cursor",
  "Launch at startup": "Iniciar com o sistema",
  "Language": "Idioma",
  "Theme": "Tema",
  "Onyx (black)": "Ônix (preto)",
  "Ice (frost white)": "Gelo (branco gelo)",
  "Frost (translucent blue)": "Geada (azul translúcido)",
  "English": "Inglês",
  "Portuguese (Brazil)": "Português (Brasil)",
  "Chat AI": "IA do chat",
  "Provider": "Provedor",
  "Claude (Anthropic)": "Claude (Anthropic)",
  "Gemini (Google)": "Gemini (Google)",
  "Claude key": "Chave Claude",
  "Gemini key": "Chave Gemini",
  "Model": "Modelo",
  "Gemini model": "Modelo Gemini",
  "API key": "Chave de API",
  "Claude Code": "Claude Code",
  "Gemini CLI": "Gemini CLI",
  "opencode": "opencode",
  "Integrations": "Integrações",
  "Secret key": "Chave secreta",
  "Token": "Token",
  "Instance URL": "URL da instância",
  "Integration token": "Token de integração",
  "Save key": "Salvar chave",
  "Key removed.": "Chave removida.",
  "Key saved in the Windows Credential Manager.": "Chave salva no Gerenciador de Credenciais.",
  "No key yet — the chat needs one.": "Sem chave ainda — o chat precisa de uma.",
  "No telemetry. Network requests only go to the services you configure yourself.":
    "Sem telemetria. Rede só fala com os serviços que você configurar.",
  "Pick up to {n} pills to show next to Mochi — {used}/{n} in use. Keys are stored in the Windows Credential Manager, never on disk.":
    "Escolha até {n} pílulas ao lado do Mochi — {used}/{n} em uso. Chaves ficam no Gerenciador de Credenciais, nunca em disco.",
  // Settings window cont.
  "Relay": "Retransmissor",
  "Install hooks…": "Instalar hooks…",
  "Reinstall hooks…": "Reinstalar hooks…",
  "Install Gemini CLI hooks…": "Instalar hooks do Gemini CLI…",
  "Reinstall Gemini CLI hooks…": "Reinstalar hooks do Gemini CLI…",
  "Install Antigravity (agy) hooks…": "Instalar hooks do Antigravity (agy)…",
  "Reinstall Antigravity (agy) hooks…": "Reinstalar hooks do Antigravity (agy)…",
  "Uninstall hooks…": "Desinstalar hooks…",
  "Uninstall…": "Desinstalar…",
  "Back up and write": "Backup e gravar",
  "Back up and remove": "Backup e remover",
  "Done. Previous settings saved as": "Pronto. Backup salvo em",
  "Done. Backup:": "Pronto. Backup:",
  "Open a new session to pick the hooks up.": "Abra uma sessão nova para ativar os hooks.",
  "Could not write": "Não gravou",
  "Could not save": "Não salvou",
  "Could not remove": "Não removeu",
  "Saved. It never touches disk.": "Salvo. Nunca toca o disco.",
  "Gemini key saved.": "Chave Gemini salva.",
  "Gemini key removed.": "Chave Gemini removida.",
  "This is exactly what will change in your settings.json. Your own hooks are left untouched.":
    "Exatamente o que vai mudar no seu settings.json. Seus hooks serão preservados.",
  "This removes Coucou's entries only. Your own hooks are left untouched.":
    "Remove só as entradas do Coucou. Seus hooks serão preservados.",
  "Coucou is hooked into your Claude Code sessions. Tool calls, questions and permission requests show up in the island, and you can answer them there.":
    "Coucou ligado às suas sessões Claude Code. Chamadas, perguntas e permissões aparecem na ilha, e você responde por lá.",
  "Install the hooks to see your Claude Code sessions in the island and approve permissions without leaving what you are doing.":
    "Instale os hooks para ver suas sessões Claude Code na ilha e aprovar permissões sem sair do que está fazendo.",
  "Coucou is hooked into your Gemini CLI sessions (BeforeTool/AfterTool). Approvals stay in the terminal — activity shows in the island side by side with Claude.":
    "Coucou ligado às sessões Gemini CLI (BeforeTool/AfterTool). Aprovações ficam no terminal — a atividade aparece na ilha ao lado do Claude.",
  "Install the hooks to see your Gemini CLI sessions in the island next to Claude Code. Note: since June 2026 new installs use Antigravity (`agy`) instead — see below.":
    "Instale os hooks para ver as sessões Gemini CLI na ilha. Nota: desde junho/2026 instalações novas usam o Antigravity (`agy`) — veja abaixo.",
  "Gemini settings use timeouts in ms. Your own hooks are left untouched.":
    "O Gemini usa timeouts em ms. Seus hooks serão preservados.",
  "Coucou is hooked into your Antigravity sessions (Pre/PostToolUse, invocations, Stop). Approvals stay in the terminal — activity shows in the island as pink agy pills.":
    "Coucou ligado às sessões Antigravity (Pre/PostToolUse, invocações, Stop). Aprovações ficam no terminal — a atividade aparece em pílulas agy rosas.",
  "Install the hooks to see your `agy` sessions in the island. Writes to %USERPROFILE%\\.gemini\\config\\hooks.json under the \"coucou\" key.":
    "Instale os hooks para ver as sessões `agy` na ilha. Grava em %USERPROFILE%\\.gemini\\config\\hooks.json na chave \"coucou\".",
  "Antigravity timeouts are in seconds. Your other hooks are left untouched.":
    "Timeouts do Antigravity são em segundos. Seus outros hooks serão preservados.",
  "opencode has no settings.json hooks. Copy windows/opencode-plugin/coucou.ts to ~/.config/opencode/plugins/ (or .opencode/plugins/) — it forwards session/tool events to the same island pipe. Gemini + opencode appear as separate pills next to Claude.":
    "opencode não tem hooks de settings.json. Copie windows/opencode-plugin/coucou.ts para ~/.config/opencode/plugins/ (ou .opencode/plugins/) — ele encaminha eventos para a ilha. Gemini + opencode aparecem em pílulas separadas.",
  "coucou-hook.exe is not in place yet. Restart Coucou; if it still fails, build it with `cargo build -p coucou-hook`.":
    "coucou-hook.exe ainda não está no lugar. Reinicie o Coucou; se persistir, compile com `cargo build -p coucou-hook`.",
  "Details": "Detalhes",
  "No calls scheduled": "Sem chamadas agendadas",
  "Too many hits at once.": "Tapas demais de uma vez.",
  "Give me a sec — back to work in three seconds.": "Me dá um segundo — volto em três segundos.",
  "Sending by email isn't in this version.": "Envio por e-mail não existe nesta versão.",
  "Claude is searching…": "Claude pesquisando…",
};

export function t(key: string): string {
  if (State.settings.language === "pt-BR") return PT[key] ?? key;
  return key;
}

/** Short badge for the island header: BR / EN. */
export function langBadge(): string {
  return State.settings.language === "pt-BR" ? "BR" : "EN";
}
