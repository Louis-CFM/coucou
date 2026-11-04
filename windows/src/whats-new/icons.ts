// The icons of the What's new card, as strokes on the 24×24 grid of
// views/icons.ts (drawn with svg(path, size, { stroke })). The Mac maps the
// same names to SF Symbols (WhatsNew.swift); scripts/test-whats-new.py lists them.

import type { IconName } from "./whats-new";

export const WHATS_NEW_ICONS: Record<IconName, string> = {
  // arrow.down.circle
  update: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 7.5v8M8.5 12.5 12 16l3.5-3.5",
  // globe
  languages: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM3 12h18M12 3c2.5 2.4 3.8 5.4 3.8 9s-1.3 6.6-3.8 9c-2.5-2.4-3.8-5.4-3.8-9S9.5 5.4 12 3z",
  // terminal
  terminal: "M4 5h16v14H4zM7.5 9.5 10 12l-2.5 2.5M12 15h4.5",
  // checklist
  checklist: "M4 6.5l1.5 1.5L8 5.5M4 12.5 5.5 14 8 11.5M4 18.5 5.5 20 8 17.5M11 7h9M11 13h9M11 19h9",
  // bell
  bell: "M6 16.5V11a6 6 0 0 1 12 0v5.5l1.5 1.5h-15L6 16.5zM10 20.5a2 2 0 0 0 4 0",
  // bubble.left.and.bubble.right
  chat: "M3.5 5h11v8h-6l-3.5 3v-3H3.5zM17.5 9h3v8h-1.5v3l-3.5-3H11",
  // mic
  mic: "M12 3.5a2.8 2.8 0 0 0-2.8 2.8V12a2.8 2.8 0 0 0 5.6 0V6.3A2.8 2.8 0 0 0 12 3.5zM6.5 11.5a5.5 5.5 0 0 0 11 0M12 17v3.5M9 20.5h6",
  // iphone
  phone: "M8 2.5h8a1.5 1.5 0 0 1 1.5 1.5v16a1.5 1.5 0 0 1-1.5 1.5H8A1.5 1.5 0 0 1 6.5 20V4A1.5 1.5 0 0 1 8 2.5zM10.5 18.5h3",
  // lock.shield
  shield: "M12 3 4.5 6v5.5c0 4.6 3.2 8.3 7.5 9.5 4.3-1.2 7.5-4.9 7.5-9.5V6L12 3zM9.5 12h5v4h-5zM10.5 12v-1.3a1.5 1.5 0 0 1 3 0V12",
  // sparkles
  sparkles: "M10 3.5l1.6 4.4L16 9.5l-4.4 1.6L10 15.5l-1.6-4.4L4 9.5l4.4-1.6zM17.5 14l.8 2.2 2.2.8-2.2.8-.8 2.2-.8-2.2-2.2-.8 2.2-.8z",
  // bolt
  bolt: "M13.5 2.5 5 13.5h6l-1 8 8.5-11h-6z",
  // puzzlepiece.extension
  puzzle: "M4 8h4a2 2 0 1 1 4 0h4v4a2 2 0 1 1 0 4v4H4v-4a2 2 0 1 0 0-4z",
  // paintpalette
  paint: "M12 3a9 9 0 0 0 0 18c1.2 0 1.8-.8 1.8-1.7 0-1.2-1-1.6-1-2.6 0-.9.7-1.4 1.7-1.4H17a4 4 0 0 0 4-4C21 6.6 17 3 12 3zM7.5 12h.01M9.5 7.5h.01M14.5 7.5h.01",
  // eye
  eye: "M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12zM12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6z",
  // keyboard
  keyboard: "M3 6.5h18v11H3zM6.5 10h.01M10 10h.01M14 10h.01M17.5 10h.01M8 14h8",
  // heart
  heart: "M12 20s-7.5-4.6-7.5-10A4.3 4.3 0 0 1 12 7.4 4.3 4.3 0 0 1 19.5 10c0 5.4-7.5 10-7.5 10z",
  // clock
  clock: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 7v5l3.5 2",
  // shippingbox
  download: "M12 3 20 7v10l-8 4-8-4V7l8-4zM4 7l8 4 8-4M12 11v10",
  // ladybug
  bug: "M8.5 8.5h7a2.5 2.5 0 0 1 2.5 2.5v3a6 6 0 0 1-12 0v-3a2.5 2.5 0 0 1 2.5-2.5zM9.5 8.5a2.5 2.5 0 0 1 5 0M12 8.5V20M4 12h2M18 12h2M4.5 17.5 6.5 16M19.5 17.5 17.5 16",
};

/** Small icons on the "Your Coucou so far" chips. */
export const STAT_ICONS = {
  agentSessions: WHATS_NEW_ICONS.terminal,
  agentTime: WHATS_NEW_ICONS.clock,
  linesAdded: "M8.5 7 4 12l4.5 5M15.5 7 20 12l-4.5 5",
  approvals: "M5 12.5 9.5 17 19 7.5",
  words: WHATS_NEW_ICONS.mic,
  saved: WHATS_NEW_ICONS.bolt,
  calls: "M5.5 3.5h3l1.5 4-2 1.3a10 10 0 0 0 7.2 7.2l1.3-2 4 1.5v3a1.5 1.5 0 0 1-1.6 1.5A16.5 16.5 0 0 1 4 5.1 1.5 1.5 0 0 1 5.5 3.5z",
} as const;
