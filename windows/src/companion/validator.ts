// CouCou Dynamic AI Companion — Multi-Stage Message Validation Pipeline (Phase 6)
// Strips reasoning tags, neutralizes markdown/quotes, enforces max 2 sentences,
// rejects generic ungrounded filler, clamps grapheme clusters (<= 72),
// and verifies physical pixel width against Dynamic Island constraints (<= 380px).

import { companionName as getActiveCompanionName } from "../core/state";
import { escapeRegExp, sanitizeCompanionName } from "../core/companion-identity";

export class MessageValidator {
  public static readonly MAX_GRAPHEMES = 72;
  public static readonly MAX_PIXEL_WIDTH = 380; // Fits within 420px Dynamic Island pill

  private static segmenter =
    typeof Intl !== "undefined" && typeof Intl.Segmenter !== "undefined"
      ? new Intl.Segmenter("en", { granularity: "grapheme" })
      : null;

  private static readonly PURE_GENERIC_PATTERNS = [
    /^(you got this|believe in yourself|keep pushing|you can do it|stay positive|never give up|reach for the stars)[!. ]*$/i,
    /^(you got this[!.]*\s*(keep pushing|believe in yourself|you can do it)[!. ]*)$/i,
    /^(believe in yourself[!.]*\s*(you got this|keep pushing)[!. ]*)$/i,
  ];

  /**
   * Sanitizes, validates, and fits raw model text for the Dynamic Island.
   * Returns clean, single-line text or null if the message is invalid/unfit.
   */
  public static sanitizeAndValidate(
    raw: string | null | undefined,
    companionName?: string,
  ): string | null {
    if (!raw || typeof raw !== "string") return null;

    // Stage 1: Detect and reject unclosed reasoning traces or leaked thinking headers
    if (/<think/i.test(raw) && !/<\/think>/i.test(raw)) {
      return null; // Unclosed <think> tag indicates truncated/leaked reasoning
    }
    if (/\[thought/i.test(raw) && !/\[\/thought\]/i.test(raw)) {
      return null;
    }

    // Strip paired <think> tags and XML-like wrappers
    let text = raw.replace(/<think>[\s\S]*?<\/think>/gi, "");
    text = text.replace(/\[thought\][\s\S]*?\[\/thought\]/gi, "");
    text = text.replace(/<[^>]+>/g, "");

    // Reject if reasoning markers or leaked deliberation headers remain
    if (
      /\b(thinking process|internal deliberation|reasoning):/i.test(text) ||
      /<think>|<\/think>|\[thought\]|\[\/thought\]/i.test(text)
    ) {
      return null;
    }

    // Stage 2: Strip conversational preambles, bullet markers, and surrounding quotes
    const configuredName = sanitizeCompanionName(companionName ?? getActiveCompanionName());
    const nameTokens = configuredName && configuredName.toLowerCase() !== "mochi"
      ? [escapeRegExp(`${configuredName} says`), escapeRegExp(configuredName)]
      : [];
    const preamblePattern = new RegExp(
      `^(here is(\\s+a)?|mochi says|greeting|message|mochi${nameTokens.length ? `|${nameTokens.join("|")}` : ""})\\s*[:\\-]?\\s*`,
      "i",
    );
    text = text.replace(preamblePattern, "");
    text = text.replace(/^[-*•]\s+/, "");
    text = text.replace(/^["'“](.*)["'”]$/, "$1").trim();

    // Stage 3: Strip Markdown formatting (**, __, `, #)
    text = text.replace(/[*_`#]/g, "");
    text = text.replace(/^["'“](.*)["'”]$/, "$1").trim();

    // Stage 4: Normalize whitespace to single line
    text = text.replace(/[\r\n\t]+/g, " ").trim();
    if (text.length < 5) return null; // Reject overly short or empty strings

    // Stage 5: Enforce length constraint: maximum 2 sentences
    text = this.extractMaxSentences(text, 2);

    // Stage 6: Discard pure generic motivational filler with no activity grounding
    if (this.isPureGenericMotivational(text)) {
      return null;
    }

    // Stage 7: Grapheme cluster boundary measurement & truncation
    if (this.segmenter) {
      const graphemes = Array.from(this.segmenter.segment(text), s => s.segment);
      if (graphemes.length > this.MAX_GRAPHEMES) {
        const candidateSlice = graphemes.slice(0, this.MAX_GRAPHEMES - 2).join("");
        const lastSpace = candidateSlice.lastIndexOf(" ");
        if (lastSpace > 20) {
          text = candidateSlice.slice(0, lastSpace).trim() + "…";
        } else {
          text = candidateSlice.trim() + "…";
        }
      }
    } else {
      if (text.length > this.MAX_GRAPHEMES) {
        const candidateSlice = text.slice(0, this.MAX_GRAPHEMES - 2);
        const lastSpace = candidateSlice.lastIndexOf(" ");
        if (lastSpace > 20) {
          text = candidateSlice.slice(0, lastSpace).trim() + "…";
        } else {
          text = candidateSlice.trim() + "…";
        }
      }
    }

    // Stage 8: Canvas Pixel Width Fit
    if (!this.checkPhysicalWidth(text)) {
      return null;
    }

    return text;
  }

  /**
   * Extracts up to `max` complete sentences from the text.
   */
  public static extractMaxSentences(text: string, max = 2): string {
    const sentenceMatches = text.match(/[^.!?]+[.!?]+(\s+|$)|[^.!?]+$/g);
    if (!sentenceMatches || sentenceMatches.length <= max) {
      return text;
    }
    return sentenceMatches.slice(0, max).join("").trim();
  }

  /**
   * Checks whether the message consists purely of generic motivational clichés.
   */
  public static isPureGenericMotivational(text: string): boolean {
    const trimmed = text.trim();
    for (const pattern of this.PURE_GENERIC_PATTERNS) {
      if (pattern.test(trimmed)) return true;
    }
    return false;
  }

  /**
   * Measures text width in WebView DOM or estimates in headless environment.
   */
  public static checkPhysicalWidth(text: string): boolean {
    if (typeof document !== "undefined") {
      try {
        const canvas = document.createElement("canvas");
        const ctx = canvas.getContext("2d");
        if (ctx) {
          ctx.font = "600 12px 'Bricolage Grotesque', system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif";
          const metrics = ctx.measureText(text);
          return (Math.ceil(metrics.width) + 8) <= this.MAX_PIXEL_WIDTH;
        }
      } catch {}
    }

    // Headless / fallback heuristic: average 5.0px per grapheme at 12px font size
    const estimatedWidth = text.length * 5.0;
    return estimatedWidth <= this.MAX_PIXEL_WIDTH;
  }
}
