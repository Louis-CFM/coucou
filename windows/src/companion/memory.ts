// CouCou Dynamic AI Companion — Bounded Diary & Anti-Repetition Engine (Phase 6)
// Maintains an in-memory 50-entry LRU ring buffer mirrored to bounded localStorage (<25KB),
// uses FNV-1a for exact duplicate matching, and applies deterministic Jaccard stem similarity (no extra LLM calls).

import type { DiaryEntry } from "./types";

export class CompanionMemory {
  public static readonly MAX_ENTRIES = 50;
  public static readonly RETENTION_MS = 7 * 24 * 60 * 60 * 1000; // 7 days
  public static readonly SIMILARITY_WINDOW_MS = 4 * 60 * 60 * 1000; // 4 hours
  public static readonly JACCARD_THRESHOLD = 0.50;
  public static readonly STORAGE_KEY = "coucou_companion_diary_v2";

  private static diary: DiaryEntry[] = [];
  private static recentTexts: string[] = [];

  static {
    this.hydrate();
  }

  /**
   * Computes a 32-bit FNV-1a hash of normalized text.
   */
  public static fnv1a(text: string): number {
    let hash = 0x811c9dc5;
    const clean = text.toLowerCase().replace(/[^\w]/g, "");
    for (let i = 0; i < clean.length; i++) {
      hash ^= clean.charCodeAt(i);
      hash = Math.imul(hash, 0x01000193);
    }
    return hash >>> 0;
  }

  /**
   * Extracts normalized word-stems, stripping common suffixes and stop words.
   */
  public static extractStems(text: string): string[] {
    const stopWords = new Set([
      "the", "a", "an", "and", "or", "to", "in", "is", "it", "you", "your",
      "for", "with", "this", "that", "some", "please", "just", "very", "now",
      "so", "but", "have", "had", "are", "was", "were", "been"
    ]);
    const words = text
      .toLowerCase()
      .replace(/[^\w\s]/g, " ")
      .split(/\s+/)
      .filter(w => w.length > 2 && !stopWords.has(w));

    return words.map(w => {
      if (w.endsWith("ing") && w.length > 5) return w.slice(0, -3);
      if (w.endsWith("ed") && w.length > 4) return w.slice(0, -2);
      if (w.endsWith("s") && w.length > 3) return w.slice(0, -1);
      return w;
    });
  }

  /**
   * Computes the Jaccard similarity index between two stem lists.
   */
  public static jaccardSimilarity(stemsA: string[], stemsB: string[]): number {
    const setA = new Set(stemsA);
    const setB = new Set(stemsB);

    if (setA.size === 0 || setB.size === 0) return 0;

    let intersection = 0;
    for (const s of setA) {
      if (setB.has(s)) intersection++;
    }

    const union = new Set([...setA, ...setB]).size;
    return union === 0 ? 0 : intersection / union;
  }

  /**
   * Checks if candidate text is an exact duplicate or lexically too similar to recent messages.
   */
  public static isDuplicateOrSimilar(candidateText: string, nowMs: number = Date.now()): boolean {
    const candidateHash = this.fnv1a(candidateText);
    const candidateStems = this.extractStems(candidateText);

    for (const entry of this.diary) {
      // Check 1: Exact FNV-1a hash duplicate
      if (entry.textFingerprint === candidateHash) {
        return true;
      }

      // Check 2: Jaccard stem similarity within 4-hour window
      if (nowMs - entry.deliveredAt <= this.SIMILARITY_WINDOW_MS) {
        const sim = this.jaccardSimilarity(candidateStems, entry.significantTokens);
        if (sim >= this.JACCARD_THRESHOLD) {
          return true;
        }
      }
    }

    return false;
  }

  /**
   * Records a delivered message into the diary and synchronizes to localStorage.
   */
  public static record(
    text: string,
    category: string,
    provider: string,
    deliveredAt: number = Date.now(),
  ): void {
    const entry: DiaryEntry = {
      id: `entry_${Date.now()}_${Math.random().toString(36).slice(2, 6)}`,
      textFingerprint: this.fnv1a(text),
      significantTokens: this.extractStems(text),
      category,
      provider,
      deliveredAt,
    };

    this.diary.unshift(entry);
    if (this.diary.length > this.MAX_ENTRIES) {
      this.diary.pop();
    }

    this.recentTexts.unshift(text);
    if (this.recentTexts.length > 5) {
      this.recentTexts.pop();
    }

    this.persist();
  }

  /** Returns recent message texts for prompt negative exclusion. */
  public static getRecentExclusions(limit = 5): string[] {
    return this.recentTexts.slice(0, limit);
  }

  /** Gets total count of entries in memory. */
  public static get count(): number {
    return this.diary.length;
  }

  /** Clears memory completely (both in-memory and disk mirror). */
  public static clear(): void {
    this.diary = [];
    this.recentTexts = [];
    if (typeof localStorage !== "undefined") {
      try {
        localStorage.removeItem(this.STORAGE_KEY);
      } catch {}
    }
  }

  /** Hydrates diary from localStorage on startup with 7-day pruning. */
  public static hydrate(): void {
    if (typeof localStorage === "undefined") return;
    try {
      const raw = localStorage.getItem(this.STORAGE_KEY);
      if (!raw) return;
      const parsed = JSON.parse(raw);
      if (Array.isArray(parsed)) {
        const now = Date.now();
        this.diary = parsed
          .filter((e: any) => e && typeof e.deliveredAt === "number" && now - e.deliveredAt <= this.RETENTION_MS)
          .slice(0, this.MAX_ENTRIES);
      }
    } catch {
      this.diary = [];
    }
  }

  /** Persists diary to localStorage with size guard (<25KB). */
  private static persist(): void {
    if (typeof localStorage === "undefined") return;
    try {
      const payload = JSON.stringify(this.diary);
      if (payload.length < 25000) {
        localStorage.setItem(this.STORAGE_KEY, payload);
      }
    } catch {}
  }
}
