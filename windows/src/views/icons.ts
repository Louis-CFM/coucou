// SVG paths standing in for the SF Symbols used by the macOS island.
// Drawn on a 24×24 grid so they read at the same optical size.

export const ICONS = {
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
} as const;
