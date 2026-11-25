/**
 * Centralized companion identity configuration, validation, and formatting.
 *
 * Companion identity lives inside `Settings` (`companionName` + `companionSetupCompleted`)
 * and syncs across all Tauri webviews via `Bridge.saveSettings` and `settings-changed`.
 * When `companionName` is unset or empty, user-facing surfaces resolve safely to
 * `DEFAULT_COMPANION_NAME` ("Mochi") without affecting Coucou's technical app identity.
 */

export const DEFAULT_COMPANION_NAME = "Mochi";
export const COMPANION_NAME_MAX_LENGTH = 24;

export interface CompanionIdentitySource {
  companionName?: string | null;
  companionSetupCompleted?: boolean | null;
}

export interface CompanionNameValidation {
  valid: boolean;
  normalized: string;
  length: number;
  error?: string;
}

const CONTROL_CHAR_REGEX = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F]/g;

const GRAPHEME_SEGMENTER =
  typeof Intl !== "undefined" && typeof Intl.Segmenter !== "undefined"
    ? new Intl.Segmenter("en", { granularity: "grapheme" })
    : null;

/** Counts user-perceived grapheme clusters so multi-codepoint emojis and combining accents count fairly. */
export function countCompanionGraphemes(text: string): number {
  if (!text) return 0;
  if (GRAPHEME_SEGMENTER) {
    let count = 0;
    for (const _ of GRAPHEME_SEGMENTER.segment(text)) count++;
    return count;
  }
  return Array.from(text).length;
}

/** Slices `text` cleanly at a grapheme cluster boundary without splitting multi-codepoint emojis. */
export function sliceCompanionGraphemes(text: string, max: number): string {
  if (!text || max <= 0) return "";
  if (GRAPHEME_SEGMENTER) {
    const out: string[] = [];
    for (const seg of GRAPHEME_SEGMENTER.segment(text)) {
      if (out.length >= max) break;
      out.push(seg.segment);
    }
    return out.join("").trimEnd();
  }
  return Array.from(text).slice(0, max).join("").trimEnd();
}

/**
 * Normalizes raw user or config input:
 * - replaces CR/LF/tabs with spaces
 * - strips unsafe control characters (preserving ZWJ and variation selectors for compound emojis)
 * - collapses repeated whitespace to a single space and trims ends
 */
export function normalizeCompanionName(raw: string | null | undefined): string {
  if (typeof raw !== "string") return "";
  const cleaned = raw
    .replace(/[\r\n\t]+/g, " ")
    .replace(CONTROL_CHAR_REGEX, "")
    .replace(/\s+/g, " ")
    .trim();
  return cleaned;
}

/** Sanitizes persisted or external names, clamping cleanly to the max grapheme cap. */
export function sanitizeCompanionName(raw: string | null | undefined): string {
  const normalized = normalizeCompanionName(raw);
  if (!normalized) return "";
  if (countCompanionGraphemes(normalized) <= COMPANION_NAME_MAX_LENGTH) {
    return normalized;
  }
  return sliceCompanionGraphemes(normalized, COMPANION_NAME_MAX_LENGTH);
}

/** Validates user-entered companion name for onboarding and Settings forms. */
export function validateCompanionName(
  raw: string | null | undefined,
  translate: (key: string, vars?: Record<string, string | number>) => string = (k, vars) =>
    vars ? k.replace(/\{(\w+)\}/g, (_, name) => String(vars[name] ?? `{${name}}`)) : k,
): CompanionNameValidation {
  const normalized = normalizeCompanionName(raw);
  const length = countCompanionGraphemes(normalized);
  if (!normalized || length === 0) {
    return {
      valid: false,
      normalized: "",
      length: 0,
      error: translate("Please enter a name for your companion."),
    };
  }
  if (length > COMPANION_NAME_MAX_LENGTH) {
    return {
      valid: false,
      normalized,
      length,
      error: translate("Companion name must be {max} characters or fewer.", {
        max: COMPANION_NAME_MAX_LENGTH,
      }),
    };
  }
  return { valid: true, normalized, length };
}

/** Returns the displayable companion name, falling back cleanly to `DEFAULT_COMPANION_NAME`. */
export function resolveCompanionName(source?: CompanionIdentitySource | null): string {
  const clean = sanitizeCompanionName(source?.companionName);
  return clean || DEFAULT_COMPANION_NAME;
}

/** True only when first-run companion setup has neither been completed nor configured. */
export function needsCompanionOnboarding(source?: CompanionIdentitySource | null): boolean {
  if (!source) return true;
  if (source.companionSetupCompleted === true) return false;
  return sanitizeCompanionName(source.companionName).length === 0;
}

/** Formats natural English possessive form without mangling names ending in 's' or emojis. */
export function companionPossessive(name: string): string {
  const resolved = sanitizeCompanionName(name) || DEFAULT_COMPANION_NAME;
  return /s$/i.test(resolved) ? `${resolved}'` : `${resolved}'s`;
}

/** Escapes arbitrary user strings (including Unicode/emojis/punctuation) for safe RegExp construction. */
export function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
