import "./tauri-mock.ts";
import { State } from "../src/core/state";
import { WhatsApp, WHATSAPP_ID, type WaConversation } from "../src/core/whatsapp";
import type { Island } from "../src/island/island";

const now = Date.now();

const conversations: WaConversation[] = [
  {
    id: "vsc@g.us",
    name: "VSC Tech Club",
    isGroup: true,
    unread: 2,
    lastActivity: now - 4 * 60_000,
    messages: [
      {
        id: "m1",
        chat: "vsc@g.us",
        sender: "gk@s.whatsapp.net",
        senderName: "GK",
        text: "Karthigai Deepam Banner_20261120_205147_0000.pdf",
        media: { kind: "document", name: "Karthigai Deepam Banner_20261120_205147_0000.pdf" },
        date: now - 4 * 60_000,
        fromMe: false,
        mentionsMe: false,
      },
    ],
  },
  {
    id: "prakash@s.whatsapp.net",
    name: "Prakash",
    isGroup: false,
    unread: 1,
    lastActivity: now - 30 * 60_000,
    messages: [
      {
        id: "m2a",
        chat: "prakash@s.whatsapp.net",
        sender: "prakash@s.whatsapp.net",
        senderName: "Prakash",
        text: "Design revisions sent for review",
        media: { kind: "image" },
        date: now - 35 * 60_000,
        fromMe: false,
        mentionsMe: false,
      },
      {
        id: "m2b",
        chat: "prakash@s.whatsapp.net",
        sender: "prakash@s.whatsapp.net",
        senderName: "Prakash",
        text: "Incoming call",
        media: { kind: "voice", seconds: 45 },
        date: now - 30 * 60_000,
        fromMe: false,
        mentionsMe: false,
      },
    ],
  },
  {
    id: "vm2027@g.us",
    name: "VM 2027 Placement",
    isGroup: true,
    unread: 4,
    lastActivity: now - 34 * 60_000,
    messages: [
      {
        id: "m3",
        chat: "vm2027@g.us",
        sender: "vinod@s.whatsapp.net",
        senderName: "Vinod Sir",
        text: "Campus recruitment schedule update",
        media: { kind: "image" },
        date: now - 34 * 60_000,
        fromMe: false,
        mentionsMe: false,
      },
    ],
  },
  {
    id: "tgd@g.us",
    name: "Tamil Graphic Designers",
    isGroup: true,
    unread: 0,
    lastActivity: now - 2 * 3600_000,
    messages: [
      {
        id: "m4",
        chat: "tgd@g.us",
        sender: "arun@s.whatsapp.net",
        senderName: "Arun",
        text: "New typography showcase is live 🔥",
        media: { kind: "none" },
        date: now - 2 * 3600_000,
        fromMe: false,
        mentionsMe: false,
      },
    ],
  },
  {
    id: "marie@s.whatsapp.net",
    name: "Marie Curie",
    isGroup: false,
    unread: 0,
    lastActivity: now - 5 * 3600_000,
    messages: [
      {
        id: "m5",
        chat: "marie@s.whatsapp.net",
        sender: "marie@s.whatsapp.net",
        senderName: "Marie Curie",
        text: "See you at the laboratory tomorrow at 9 AM",
        media: { kind: "none" },
        date: now - 5 * 3600_000,
        fromMe: false,
        mentionsMe: false,
      },
    ],
  },
  {
    id: "sarah@s.whatsapp.net",
    name: "Sarah Jenkins",
    isGroup: false,
    unread: 0,
    lastActivity: now - 24 * 3600_000,
    messages: [
      {
        id: "m6",
        chat: "sarah@s.whatsapp.net",
        sender: "sarah@s.whatsapp.net",
        senderName: "Sarah Jenkins",
        text: "Thanks for reviewing the slide deck!",
        media: { kind: "none" },
        date: now - 24 * 3600_000,
        fromMe: false,
        mentionsMe: false,
      },
    ],
  },
];

WhatsApp.view = {
  on: true,
  link: { state: "connected" },
  conversations,
  unread: 7,
  sending: false,
  sendError: null,
  down: false,
};

State.tasks = [
  {
    id: WHATSAPP_ID,
    name: "WhatsApp",
    color: "#25D366",
    state: "idle",
    steps: [],
  },
];
State.focusId = WHATSAPP_ID;

await import("../src/main.ts");

const island: Island = (window as any).__island;
const params = new URLSearchParams(window.location.search);
const state = params.get("state") || "inbox";

setTimeout(() => {
  island.setMode("expanded");
  island.setView("overview");
  State.setFocus(WHATSAPP_ID);

  if (state === "convo") {
    setTimeout(() => {
      const rows = document.querySelectorAll(".wa-row");
      const prakashRow = Array.from(rows).find((r) => r.textContent?.includes("Prakash")) as HTMLElement;
      if (prakashRow) prakashRow.click();
      else if (rows[1]) (rows[1] as HTMLElement).click();
    }, 300);
  }
}, 300);
