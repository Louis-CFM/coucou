import { describe, it, expect } from "vitest";
import { maskSecrets } from "../src/mask.js";

// Build test key patterns at runtime — writing them as source literals
// would trigger static secret scanners even when the values are intentionally fake.
const fake = {
  anthropic:    "sk-ant-api" + "03-" + "a".repeat(60),
  openai_proj:  "sk-proj-" + "a".repeat(48),
  openai_key:   "sk-" + "A".repeat(32),
  stripe_live:  "sk_" + "live_" + "x".repeat(24),
  stripe_test:  "sk_" + "test_" + "x".repeat(24),
  stripe_whsec: "whsec_" + "x".repeat(40),
  stripe_rk:    "rk_" + "live_" + "x".repeat(24),
  gh_pat:       "gh" + "p_" + "x".repeat(40),
  gh_fine:      "github_pat" + "_11" + "x".repeat(50),
  aws:          "AK" + "IA" + "IOSFODNN7EXAMPLE",
  google:       "AIza" + "SyD-9tSrke72I6e0DVwVl9A5JqlnL1234567",
  slack_bot:    "xox" + "b-" + "0".repeat(20),
  slack_user:   "xox" + "p-" + "0".repeat(20),
};

// Helper: mask and return text + detected types
function mask(input: string) {
  const result = maskSecrets(input);
  const types = result.masked.map((m) => m.type);
  return { text: result.text, types };
}

// ─── True positives ───────────────────────────────────────────────────────────

describe("Anthropic API key", () => {
  it("masks sk-ant- key", () => {
    const { text, types } = mask(`key: ${fake.anthropic}`);
    expect(text).toContain("[MASQUÉ:api-key-anthropic]");
    expect(types).toContain("api-key-anthropic");
    expect(text).not.toMatch(/sk-ant-api/);
  });
});

describe("OpenAI API keys", () => {
  it("masks sk-proj- key", () => {
    const { text, types } = mask(`OPENAI_API_KEY=${fake.openai_proj}`);
    expect(text).toContain("[MASQUÉ:api-key-openai-project]");
    expect(types).toContain("api-key-openai-project");
  });

  it("masks generic sk- key", () => {
    const { text, types } = mask(`token: ${fake.openai_key}`);
    expect(text).toContain("[MASQUÉ:api-key-openai]");
    expect(types).toContain("api-key-openai");
  });
});

describe("Stripe keys", () => {
  it("masks sk_live_ key", () => {
    const { text } = mask(`stripe_key=${fake.stripe_live}`);
    expect(text).toContain("[MASQUÉ:api-key-stripe-live]");
    expect(text).not.toMatch(/sk_live_/);
  });

  it("masks sk_test_ key", () => {
    const { text } = mask(`key=${fake.stripe_test}`);
    expect(text).toContain("[MASQUÉ:api-key-stripe-test]");
  });

  it("masks whsec_ webhook secret", () => {
    const { text } = mask(`WEBHOOK_SECRET=${fake.stripe_whsec}`);
    expect(text).toContain("[MASQUÉ:stripe-webhook-secret]");
  });

  it("masks rk_live_ restricted key", () => {
    const { text } = mask(fake.stripe_rk);
    expect(text).toContain("[MASQUÉ:api-key-stripe-restricted-live]");
  });
});

describe("GitHub tokens", () => {
  it("masks classic PAT (ghp_)", () => {
    const { text } = mask(`token: ${fake.gh_pat}`);
    expect(text).toContain("[MASQUÉ:github-pat-classic]");
  });

  it("masks fine-grained PAT (github_pat_)", () => {
    const { text } = mask(`GITHUB_TOKEN=${fake.gh_fine}`);
    expect(text).toContain("[MASQUÉ:github-pat-fine-grained]");
  });
});

describe("AWS keys", () => {
  it("masks AKIA access key", () => {
    const { text } = mask(`AWS_ACCESS_KEY_ID=${fake.aws}`);
    expect(text).toContain("[MASQUÉ:aws-access-key]");
  });
});

describe("Google API key", () => {
  it("masks AIza key", () => {
    const { text } = mask(`key: ${fake.google}`);
    expect(text).toContain("[MASQUÉ:api-key-google]");
  });
});

describe("Slack tokens", () => {
  it("masks xoxb- bot token", () => {
    const { text } = mask(`token=${fake.slack_bot}`);
    expect(text).toContain("[MASQUÉ:slack-token]");
  });

  it("masks xoxp- user token", () => {
    const { text } = mask(`SLACK_TOKEN=${fake.slack_user}`);
    expect(text).toContain("[MASQUÉ:slack-token]");
  });
});

describe("JWT", () => {
  it("masks 3-part JWT", () => {
    const jwt =
      "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c";
    const { text } = mask(`Authorization: Bearer ${jwt}`);
    expect(text).toContain("[MASQUÉ:jwt]");
    expect(text).not.toContain("eyJhbGci");
  });
});

describe("Bearer token", () => {
  it("preserves 'Bearer ' prefix, masks token", () => {
    const { text } = mask("Authorization: Bearer abcdefghijklmnopqrstuvwxyz1234567890AB");
    expect(text).toContain("Bearer [MASQUÉ:bearer-token]");
  });

  it("does not mask short tokens (< 20 chars)", () => {
    const { text } = mask("Authorization: Bearer short");
    // "short" is 5 chars — should NOT be masked
    expect(text).toContain("Bearer short");
  });
});

describe("URL with credentials", () => {
  it("masks postgres:// URL", () => {
    const { text } = mask("DATABASE_URL=postgres://myuser:supersecretpassword@db.example.com:5432/mydb");
    expect(text).toContain("[MASQUÉ:url-with-credentials]");
    expect(text).not.toContain("supersecretpassword");
  });

  it("masks mongodb:// URL", () => {
    const { text } = mask("mongodb://admin:hunter2@cluster.mongodb.net/mydb");
    expect(text).toContain("[MASQUÉ:url-with-credentials]");
  });
});

describe(".env sensitive variables", () => {
  it("masks SECRET_KEY=value", () => {
    const { text } = mask("SECRET_KEY=mysupersecretvalue123");
    expect(text).toContain("[MASQUÉ:env-var]");
    expect(text).not.toContain("mysupersecretvalue123");
    // Preserves key name
    expect(text).toContain("SECRET_KEY=");
  });

  it("masks API_TOKEN=value", () => {
    const { text } = mask("API_TOKEN=tok_live_abcdefghijklmnop");
    expect(text).toContain("[MASQUÉ:env-var]");
  });

  it("masks PASSWORD=value", () => {
    const { text } = mask("DATABASE_PASSWORD=hunter2withextrastuff");
    expect(text).toContain("[MASQUÉ:env-var]");
  });
});

describe("Private key block", () => {
  it("masks PEM private key", () => {
    const pem = `-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEA2a2rwplBQLF29amygykEMmYz0+Kcj3bKBp29fNnmN2bFBcph
-----END RSA PRIVATE KEY-----`;
    const { text } = mask(pem);
    expect(text).toContain("[MASQUÉ:private-key]");
    expect(text).not.toContain("MIIEowIBAAK");
  });
});

describe("IBAN", () => {
  it("masks French IBAN", () => {
    const { text } = mask("IBAN: FR76 3000 6000 0112 3456 7890 189");
    expect(text).toContain("[MASQUÉ:iban]");
  });
});

// ─── False positives ──────────────────────────────────────────────────────────

describe("False positives — should NOT be masked", () => {
  it("does not mask 'sk-learn' (Python package)", () => {
    const { text } = mask("import sklearn  # sk-learn is not a secret");
    expect(text).toBe("import sklearn  # sk-learn is not a secret");
  });

  it("does not mask short sk- strings", () => {
    // Less than 20 chars after sk-
    const { text } = mask("key: sk-short");
    expect(text).toContain("sk-short");
  });

  it("does not mask regular .env variable without sensitive name", () => {
    const { text } = mask("APP_NAME=MyCoolApp\nPORT=3000\nNODE_ENV=production");
    expect(text).toBe("APP_NAME=MyCoolApp\nPORT=3000\nNODE_ENV=production");
  });

  it("does not mask regular Base64 string that isn't a JWT", () => {
    // 2-part base64 is not a JWT
    const { text } = mask("data: eyJhbGci.eyJzdWIi");
    expect(text).toBe("data: eyJhbGci.eyJzdWIi");
  });

  it("does not mask short Bearer token", () => {
    const { text } = mask("Authorization: Bearer abc");
    expect(text).toContain("Bearer abc");
  });

  it("does not mask github.com URL", () => {
    const { text } = mask("See https://github.com/anthropics/claude-code for more info");
    expect(text).toBe("See https://github.com/anthropics/claude-code for more info");
  });

  it("does not mask postgres URL without password", () => {
    const { text } = mask("postgres://localhost:5432/mydb");
    expect(text).toContain("postgres://localhost:5432/mydb");
  });
});

// ─── Multiple secrets in one string ──────────────────────────────────────────

describe("Multiple secrets in one block", () => {
  it("masks all secrets in a multi-line config", () => {
    const config = [
      `ANTHROPIC_API_KEY=${fake.anthropic}`,
      `STRIPE_SECRET_KEY=${fake.stripe_live}`,
      `GITHUB_TOKEN=${fake.gh_pat}`,
      "DATABASE_PASSWORD=supersecret",
      "PORT=3000",
    ].join("\n");

    const { text, masked } = maskSecrets(config);
    expect(text).not.toMatch(/sk-ant-api/);
    expect(text).not.toMatch(/sk_live_/);
    expect(text).not.toMatch(/ghp_/);
    expect(text).not.toMatch(/supersecret/);
    expect(text).toContain("PORT=3000"); // non-sensitive preserved
    expect(masked.length).toBeGreaterThanOrEqual(3);
  });
});
