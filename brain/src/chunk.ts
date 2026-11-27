/**
 * Splits a session condensed text into token-bounded chunks.
 * Chunks are split at message boundaries ("Louis:" / "Claude:" lines).
 */
import { estimateTokens } from "./utils.js";
import type { CondensedMessage } from "./collect.js";

export interface Chunk {
  index: number;
  total: number;
  text: string;
  estimatedTokens: number;
}

/** Format messages as text for LLM input */
export function messagesToText(messages: CondensedMessage[]): string {
  return messages
    .map((m) => `${m.role === "human" ? "Louis" : "Claude"}: ${m.text}`)
    .join("\n\n---\n\n");
}

/**
 * Split messages into chunks of at most maxTokens.
 * Returns one chunk if the session fits; multiple otherwise.
 */
export function chunkMessages(messages: CondensedMessage[], maxTokens: number): Chunk[] {
  const fullText = messagesToText(messages);
  const totalTokens = estimateTokens(fullText);

  if (totalTokens <= maxTokens) {
    return [{ index: 0, total: 1, text: fullText, estimatedTokens: totalTokens }];
  }

  // Split greedily at message boundaries
  const chunks: Chunk[] = [];
  let current: CondensedMessage[] = [];
  let currentTokens = 0;

  for (const msg of messages) {
    const msgText = `${msg.role === "human" ? "Louis" : "Claude"}: ${msg.text}`;
    const msgTokens = estimateTokens(msgText);

    if (currentTokens + msgTokens > maxTokens && current.length > 0) {
      const text = messagesToText(current);
      chunks.push({
        index: chunks.length,
        total: 0, // will be filled after
        text,
        estimatedTokens: estimateTokens(text),
      });
      current = [msg];
      currentTokens = msgTokens;
    } else {
      current.push(msg);
      currentTokens += msgTokens;
    }
  }

  if (current.length > 0) {
    const text = messagesToText(current);
    chunks.push({
      index: chunks.length,
      total: 0,
      text,
      estimatedTokens: estimateTokens(text),
    });
  }

  // Fill total
  for (const chunk of chunks) {
    chunk.total = chunks.length;
  }

  return chunks;
}
