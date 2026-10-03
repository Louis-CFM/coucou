// SVG paths standing in for the SF Symbols used by the macOS island.
// Drawn on a 24×24 grid so they read at the same optical size.

export const ICONS = {
  // house.fill
  house: "M12 3.2 2.8 10.6V21h6.6v-5.4h5.2V21h6.6V10.6L12 3.2z",
  // bubble.left.fill
  bubble: "M12 3.6c-5 0-9 3.3-9 7.4 0 2.3 1.3 4.4 3.3 5.7-.2 1.2-.8 2.4-1.7 3.4 1.9-.2 3.6-.9 4.9-1.9 .8.2 1.6.3 2.5.3 5 0 9-3.3 9-7.5s-4-7.4-9-7.4z",
  // plus
  plus: "M11 4h2v7h7v2h-7v7h-2v-7H4v-2h7V4z",
  // gearshape
  gear: "M12 8.6a3.4 3.4 0 1 0 0 6.8 3.4 3.4 0 0 0 0-6.8zm0 1.8a1.6 1.6 0 1 1 0 3.2 1.6 1.6 0 0 1 0-3.2zM10.9 2h2.2l.35 2.1c.6.17 1.16.4 1.67.71l1.9-1 1.55 1.55-1 1.9c.3.5.54 1.07.7 1.67l2.13.35v2.2l-2.12.35c-.17.6-.4 1.16-.71 1.67l1 1.9-1.55 1.55-1.9-1c-.5.3-1.07.54-1.67.7L13.1 22h-2.2l-.35-2.12c-.6-.17-1.16-.4-1.67-.71l-1.9 1L5.43 18.6l1-1.9c-.3-.5-.54-1.07-.7-1.67L3.6 14.7v-2.2l2.12-.35c.17-.6.4-1.16.71-1.67l-1-1.9 1.55-1.55 1.9 1c.5-.3 1.07-.54 1.67-.7L10.9 2z",
  gearFill: "M10.9 2h2.2l.35 2.1c.6.17 1.16.4 1.67.71l1.9-1 1.55 1.55-1 1.9c.3.5.54 1.07.7 1.67l2.13.35v2.2l-2.12.35c-.17.6-.4 1.16-.71 1.67l1 1.9-1.55 1.55-1.9-1c-.5.3-1.07.54-1.67.7L13.1 22h-2.2l-.35-2.12c-.6-.17-1.16-.4-1.67-.71l-1.9 1L5.43 18.6l1-1.9c-.3-.5-.54-1.07-.7-1.67L3.6 14.7v-2.2l2.12-.35c.17-.6.4-1.16.71-1.67l-1-1.9 1.55-1.55 1.9 1c.5-.3 1.07-.54 1.67-.7L10.9 2zM12 8.2a3.8 3.8 0 1 0 0 7.6 3.8 3.8 0 0 0 0-7.6z",
  // speaker.wave.2
  speakerOn: "M11 4.5 6.5 8.2H3.4v7.6h3.1L11 19.5v-15zm3.2 3a5.3 5.3 0 0 1 0 9 .9.9 0 0 0 .9 1.55 7.1 7.1 0 0 0 0-12.1.9.9 0 0 0-.9 1.55zm2.6-3.1a8.9 8.9 0 0 1 0 15.2.9.9 0 0 0 .92 1.55 10.7 10.7 0 0 0 0-18.3.9.9 0 0 0-.92 1.55z",
  // speaker.slash
  speakerOff: "M11 4.5 6.5 8.2H3.4v7.6h3.1L11 19.5v-15zm3.6 4.1 1.27-1.27 2.33 2.33 2.33-2.33 1.27 1.27L19.47 11l2.33 2.33-1.27 1.27-2.33-2.33-2.33 2.33-1.27-1.27L16.93 11 14.6 8.6z",
  // arrow.up.right
  arrowUpRight: "M8.5 7h8.5v8.5h-2V10.4l-7.1 7.1-1.4-1.4 7.1-7.1H8.5V7z",
  // chevron.right
  chevronRight: "M9 5.5 15.5 12 9 18.5",
  chevronLeft: "M15 5.5 8.5 12 15 18.5",
  // checkmark
  check: "M5 12.5 9.5 17 19 7.5",
  // arrow.up (send)
  arrowUp: "M12 4.5 5.5 11l1.5 1.5 4-4V19.5h2V8.5l4 4L18.5 11 12 4.5z",
  // exclamationmark
  bang: "M11 4h2v10h-2V4zm0 12.2h2v2.2h-2v-2.2z",
  // xmark
  xmark: "M6.4 5 12 10.6 17.6 5 19 6.4 13.4 12 19 17.6 17.6 19 12 13.4 6.4 19 5 17.6 10.6 12 5 6.4 6.4 5z",
  // timer
  timer: "M12 4.2a7.8 7.8 0 1 0 0 15.6 7.8 7.8 0 0 0 0-15.6zm0 1.9a5.9 5.9 0 1 1 0 11.8 5.9 5.9 0 0 1 0-11.8zm-.95 2.3v4.2l3.3 2 .95-1.55-2.4-1.45V8.4h-1.85zM9.2 2h5.6v1.7H9.2V2z",
  // ellipsis
  ellipsis: "M6 10.4a1.6 1.6 0 1 0 0 3.2 1.6 1.6 0 0 0 0-3.2zm6 0a1.6 1.6 0 1 0 0 3.2 1.6 1.6 0 0 0 0-3.2zm6 0a1.6 1.6 0 1 0 0 3.2 1.6 1.6 0 0 0 0-3.2z",
  // star.fill
  star: "M12 3.2l2.6 5.55 5.9.82-4.3 4.3 1.05 6.13L12 17.1l-5.25 2.9L7.8 13.87 3.5 9.57l5.9-.82L12 3.2z",
  // square.stack.fill
  stack: "M5 8h14v11.5H5V8zm1.8-3h10.4v1.6H6.8V5zm1.6-2.6h7.2V4H8.4V2.4z",
  // doc.text
  doc: "M6.5 2.6h7l4 4v14.8h-11V2.6zm6.6 1.6v3.3h3.3l-3.3-3.3zM8.6 11h6.8v1.5H8.6V11zm0 3.4h6.8v1.5H8.6v-1.5z",

  // GitHub panel — no SF Symbol to mirror, so these are drawn for stroke
  // rendering: pass `{ stroke: 2 }` to svg().
  // arrow.clockwise
  refresh: "M19.5 12a7.5 7.5 0 1 1-2.2-5.3M19.5 4.5v4.5H15",
  // a commit: a node on a line
  commit: "M12 9a3 3 0 1 1 0 6 3 3 0 1 1 0-6M3 12h6M15 12h6",
  // pull request: two branches, the right one pointing back
  pullRequest: "M6 4a2 2 0 1 1 0 4 2 2 0 1 1 0-4M6 16a2 2 0 1 1 0 4 2 2 0 1 1 0-4M6 8v8M18 16a2 2 0 1 1 0 4 2 2 0 1 1 0-4M18 16V9a3 3 0 0 0-3-3h-3M14 3.5 11.5 6 14 8.5",
  // merge: a branch folding back in
  merge: "M6 4a2 2 0 1 1 0 4 2 2 0 1 1 0-4M6 16a2 2 0 1 1 0 4 2 2 0 1 1 0-4M18 10a2 2 0 1 1 0 4 2 2 0 1 1 0-4M6 8v8M6 8c0 2.5 2.5 4 10 4",
  // issue: a ring with a dot
  issue: "M12 4a8 8 0 1 1 0 16 8 8 0 1 1 0-16M12 11.2a.8.8 0 1 1 0 1.6.8.8 0 1 1 0-1.6",
  // tag
  tag: "M3.5 12.5V4.5a1 1 0 0 1 1-1h8l8 8-9 9zM8 7.5h.01",
  // plus, stroked
  add: "M12 5v14M5 12h14",
  // lock, stroked
  lock: "M8 11V8a4 4 0 0 1 8 0v3M6 11h12v9H6z",
  // minus, stroked
  dash: "M7 12h10",
  // a rocket, for deployments, stroked
  rocket: "M12 3c3 2.2 4.5 5.2 4.5 9l-1.8 3h-5.4l-1.8-3c0-3.8 1.5-6.8 4.5-9zM12 9.2a1.6 1.6 0 1 1 0 3.2 1.6 1.6 0 1 1 0-3.2M9.3 15l-1.8 4.5 2.8-1.6M14.7 15l1.8 4.5-2.8-1.6",
  // a pulse, for activity, stroked
  pulse: "M3 12h4l2.5-6 5 12 2.5-6H21",
  // What was said: a speech bubble, drawn as a line like the other GitHub marks.
  comment: "M4 5.5h16v10.5h-8.5L7 20v-4H4z",

  // A bell, and a bell struck through, stroked: a project that speaks up, one that keeps quiet.
  bell: "M6.5 16.5V11a5.5 5.5 0 0 1 11 0v5.5l1.5 2h-14zM10 20.5a2 2 0 0 0 4 0",
  bellOff: "M6.5 16.5V11a5.5 5.5 0 0 1 9-4.2M17.5 11.5v5l1.5 2H8M10 20.5a2 2 0 0 0 4 0M4.5 4.5l15 15",

  // A player's keys, filled: back, play, pause, on.
  previous: "M18.5 5.5 9 12l9.5 6.5zM5.5 5.5H8v13H5.5z",
  play: "M8 5v14l11-7z",
  pause: "M7 5.5h3.6v13H7zM13.4 5.5H17v13h-3.6z",
  next: "M5.5 5.5 15 12l-9.5 6.5zM16 5.5h2.5v13H16z",

  // A session's steps, stroked: an edit, a command, a search.
  pencil: "M4.5 19.5l1-4.2L16.6 4.2l3.2 3.2L8.7 18.5l-4.2 1zM14.4 6.4l3.2 3.2",
  terminal: "M5 7.5 9.5 12 5 16.5M12.5 17H19",
  search: "M10.5 4.5a6 6 0 1 1 0 12 6 6 0 0 1 0-12M15 15l4.5 4.5",
} as const;
