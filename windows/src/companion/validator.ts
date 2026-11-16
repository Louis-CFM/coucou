// CouCou Dynamic AI Companion — Multi-Stage Message Validation Pipeline (Phase 6)
// Strips reasoning tags, neutralizes markdown/quotes, clamps grapheme clusters (<= 52),
// and verifies physical pixel width against Dynamic Island constraints (<= 344px).

export class MessageValidator {
  public static readonly MAX_GRAPHEMES = 52;
  public static readonly MAX_PIXEL_WIDTH = 344; // 420px max pill - 44px padding - 32px mascot

  private static segmenter =
    typeof Intl !== "undefined" && typeof Intl.Segmenter !== "undefined"
      ? new Intl.Segmenter("en", { granularity: "grapheme" })
      : null;

  /**
   * Sanitizes, validates, and fits raw model text for the Dynamic Island.
   * Returns clean, single-line text or null if the message is invalid/unfit.
   */
  public static sanitizeAndValidate(raw: string | null | undefined): string | null {
    if (!raw || typeof raw !== "string") return null;

    // Stage 1: Strip <think> tags and XML-like wrappers
    let text = raw.replace(/<think>[\s\S]*?<\/think>/gi, "");
    text = text.replace(/\[thought\][\s\S]*?\[\/thought\]/gi, "");
    text = text.replace(/<[^>]+>/g, "");

    // Stage 2: Strip conversational preambles and surrounding quotes
    text = text.replace(/^(here is(\s+a)?|mochi says|greeting|message|mochi)\s*[:\-]?\s*/i, "");
    text = text.replace(/^["'“](.*)["'”]$/, "$1").trim();

    // Stage 3: Strip Markdown formatting (**, __, `, #)
    text = text.replace(/[*_`#]/g, "");
    text = text.replace(/^["'“](.*)["'”]$/, "$1").trim();

    // Stage 4: Normalize whitespace to single line
    text = text.replace(/[\r\n\t]+/g, " ").trim();
    if (text.length < 5) return null; // Reject overly short or empty strings

    // Stage 5: Grapheme cluster boundary measurement & truncation
    if (this.segmenter) {
      const graphemes = Array.from(this.segmenter.segment(text), s => s.segment);
      if (graphemes.length > this.MAX_GRAPHEMES) {
        // Truncate at last space boundary before 50 graphemes
        const candidateSlice = graphemes.slice(0, 48).join("");
        const lastSpace = candidateSlice.lastIndexOf(" ");
        if (lastSpace > 20) {
          text = candidateSlice.slice(0, lastSpace).trim() + "…";
        } else {
          text = candidateSlice.trim() + "…";
        }
      }
    } else {
      if (text.length > this.MAX_GRAPHEMES) {
        text = text.slice(0, 48).trim() + "…";
      }
    }

    // Stage 6: Canvas Pixel Width Fit
    if (!this.checkPhysicalWidth(text)) {
      return null;
    }

    return text;
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

    // Headless / fallback heuristic: average 6.5px per grapheme at 12px font size
    const estimatedWidth = text.length * 6.5;
    return estimatedWidth <= this.MAX_PIXEL_WIDTH;
  }
}
