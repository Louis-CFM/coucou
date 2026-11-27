/**
 * Secret masking — applied before any LLM call and before writing to disk.
 * Patterns are ordered from most specific to most generic to avoid false positives.
 */

export interface MaskResult {
  text: string;
  masked: MaskedItem[];
}

export interface MaskedItem {
  type: string;
  count: number;
}

interface Pattern {
  type: string;
  regex: RegExp;
}

// Minimum lengths to avoid false positives (e.g. "sk-learn")
const MIN_KEY_LENGTH = 20;

const PATTERNS: Pattern[] = [
  // ── Private key blocks ────────────────────────────────────────────────────
  {
    type: "private-key",
    regex: /-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----[\s\S]*?-----END (?:[A-Z ]+ )?PRIVATE KEY-----/g,
  },

  // ── Anthropic ─────────────────────────────────────────────────────────────
  {
    type: "api-key-anthropic",
    regex: /\bsk-ant-[a-zA-Z0-9\-_]{20,}/g,
  },
  {
    type: "api-key-openai-project",
    regex: /\bsk-proj-[a-zA-Z0-9\-_]{20,}/g,
  },

  // ── Stripe ────────────────────────────────────────────────────────────────
  {
    type: "api-key-stripe-live",
    regex: /\bsk_live_[a-zA-Z0-9]{20,}/g,
  },
  {
    type: "api-key-stripe-test",
    regex: /\bsk_test_[a-zA-Z0-9]{20,}/g,
  },
  {
    type: "api-key-stripe-restricted-live",
    regex: /\brk_live_[a-zA-Z0-9]{20,}/g,
  },
  {
    type: "api-key-stripe-restricted-test",
    regex: /\brk_test_[a-zA-Z0-9]{20,}/g,
  },
  {
    type: "stripe-webhook-secret",
    regex: /\bwhsec_[a-zA-Z0-9]{20,}/g,
  },

  // ── Generic OpenAI-style sk- (after specific sk-ant- and sk-proj-) ─────────
  {
    type: "api-key-openai",
    regex: /\bsk-[a-zA-Z0-9]{20,}/g,
  },

  // ── GitHub ────────────────────────────────────────────────────────────────
  {
    type: "github-pat-fine-grained",
    regex: /\bgithub_pat_[a-zA-Z0-9_]{36,}/g,
  },
  {
    type: "github-pat-classic",
    regex: /\bghp_[a-zA-Z0-9]{36,}/g,
  },

  // ── AWS ───────────────────────────────────────────────────────────────────
  {
    type: "aws-access-key",
    regex: /\bAKIA[A-Z0-9]{16}\b/g,
  },

  // ── Google ────────────────────────────────────────────────────────────────
  {
    type: "api-key-google",
    // Google keys are AIza + 35 chars, but be lenient (30+) to handle variations
    regex: /\bAIza[0-9A-Za-z\-_]{30,}/g,
  },

  // ── Slack ─────────────────────────────────────────────────────────────────
  {
    type: "slack-token",
    regex: /\bxox[bporas]-[a-zA-Z0-9\-]{20,}/g,
  },

  // ── Twilio ────────────────────────────────────────────────────────────────
  {
    type: "twilio-sid",
    regex: /\bAC[a-f0-9]{32}\b/g,
  },
  {
    type: "twilio-auth-token",
    regex: /\b[a-f0-9]{32}\b(?=.*twilio)/gi,
  },

  // ── JWT (3-part base64url) ────────────────────────────────────────────────
  {
    type: "jwt",
    regex: /\beyJ[a-zA-Z0-9_\-]{20,}\.[a-zA-Z0-9_\-]{20,}\.[a-zA-Z0-9_\-]{20,}/g,
  },

  // ── Bearer tokens ─────────────────────────────────────────────────────────
  {
    type: "bearer-token",
    regex: /\bBearer\s+([a-zA-Z0-9_\-\.]{20,})/g,
  },

  // ── URLs with embedded credentials ───────────────────────────────────────
  {
    type: "url-with-credentials",
    regex: /\b(?:postgres|postgresql|mysql|mongodb|redis):\/\/[^:]+:[^@\s]{3,}@[^\s"']*/g,
  },

  // ── .env lines (only sensitive key names) ────────────────────────────────
  {
    type: "env-var",
    // Exclude '[' so already-masked values ([MASQUÉ:...]) are not re-processed
    regex: /^([A-Z][A-Z0-9_]*(?:KEY|SECRET|TOKEN|PASSWORD|PASSWD|PASS|PRIVATE|AUTH|CREDENTIAL|CERT|SIGNING)[A-Z0-9_]*)=([^\s#\n\[]{3,})$/gm,
  },

  // ── IBAN ──────────────────────────────────────────────────────────────────
  // Requires non-alphanumeric on both sides to avoid false positives from
  // base64-encoded binary content in JSONL files.
  // Allows a trailing group of 1-4 chars to handle French IBAN (last group = 3).
  {
    type: "iban",
    regex: /(?<![A-Za-z0-9])[A-Z]{2}\d{2}(?:\s?[A-Z0-9]{4}){3,6}(?:\s?[A-Z0-9]{1,4})?(?![A-Za-z0-9])/g,
  },

  // ── Credit/debit card numbers ─────────────────────────────────────────────
  // Only match space-separated 4×4 format (e.g. "4242 4242 4242 4242").
  // Dash-separated excluded: UUID segments in JSONL cause false positives.
  // Compact 16-digit excluded: social media IDs (FB/IG) are 16-digit integers.
  {
    type: "card-number",
    regex: /\b(?:\d{4} ){3}\d{4}\b/g,
  },
];

// Replacement builder
function replacement(type: string): string {
  return `[MASQUÉ:${type}]`;
}

export function maskSecrets(input: string): MaskResult {
  const counts: Record<string, number> = {};
  let text = input;

  for (const pattern of PATTERNS) {
    // Reset lastIndex for global regexes
    pattern.regex.lastIndex = 0;

    const newText = text.replace(pattern.regex, (match) => {
      // For Bearer token, the actual secret is capture group 1
      // but replace() with a function gets the full match — keep type annotation
      counts[pattern.type] = (counts[pattern.type] ?? 0) + 1;
      // For Bearer, preserve the word "Bearer " prefix
      if (pattern.type === "bearer-token") {
        return `Bearer ${replacement(pattern.type)}`;
      }
      // For .env lines, preserve the key name
      if (pattern.type === "env-var") {
        const eqIdx = match.indexOf("=");
        return eqIdx >= 0
          ? `${match.slice(0, eqIdx + 1)}${replacement(pattern.type)}`
          : replacement(pattern.type);
      }
      return replacement(pattern.type);
    });

    // Reset again after replace (some engines don't reset between uses)
    pattern.regex.lastIndex = 0;
    text = newText;
  }

  const masked: MaskedItem[] = Object.entries(counts).map(([type, count]) => ({
    type,
    count,
  }));

  return { text, masked };
}

/**
 * Mask secrets in an object by serializing, masking, deserializing.
 * Use only for small objects — large ones should be handled as strings.
 */
export function maskSecretsInObject<T>(obj: T): { value: T; masked: MaskedItem[] } {
  const { text, masked } = maskSecrets(JSON.stringify(obj));
  return { value: JSON.parse(text) as T, masked };
}
