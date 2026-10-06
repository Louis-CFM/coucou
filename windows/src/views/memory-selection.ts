export function utf8Span(text: string, startUtf16: number, endUtf16: number): { text: string; start: number; end: number } | null {
  if (startUtf16 < 0 || endUtf16 <= startUtf16 || endUtf16 > text.length) return null;
  const selected = text.slice(startUtf16, endUtf16);
  if (!selected) return null;
  const encoder = new TextEncoder();
  const start = encoder.encode(text.slice(0, startUtf16)).length;
  return { text: selected, start, end: start + encoder.encode(selected).length };
}

export function selectionWithinBubble(value: { anchorBubble: string | null; focusBubble: string | null }): boolean {
  return value.anchorBubble != null && value.anchorBubble === value.focusBubble;
}
