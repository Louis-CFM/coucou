import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import fs from "node:fs";

export function expandHome(p: string): string {
  if (p.startsWith("~/")) return path.join(os.homedir(), p.slice(2));
  if (p === "~") return os.homedir();
  return p;
}

export function sha256File(filePath: string): string {
  const data = fs.readFileSync(filePath);
  return crypto.createHash("sha256").update(data).digest("hex");
}

export function toSlug(name: string): string {
  return name
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "") // strip accents
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");
}

/** Decode a Claude projects dir name back to its filesystem path.
 *  e.g. "-Users-louis-Developer-coucou" → "/Users/louis/Developer/coucou"
 *  This is a heuristic: Claude encodes path separators as "-", so ambiguity
 *  exists when folder names contain dashes. We try to find the longest
 *  existing prefix. Falls back to the last segment.
 */
export function decodeClaudeProjectPath(encoded: string): string | null {
  // Strip leading "-" and replace with "/"
  const candidate = ("/" + encoded.slice(1)).replace(/-/g, "/");

  // Walk from full path down to find something that exists
  let p = candidate;
  while (p.length > 1) {
    if (fs.existsSync(p)) return p;
    const parent = path.dirname(p);
    if (parent === p) break;
    p = parent;
  }
  return null;
}

/** Extract the last meaningful segment from a Claude projects dir name.
 *  "-Users-louis-Developer-coucou" → "coucou"
 *  "-Users-louis-Documents-Projets-Content-web" → "Content-web" (best-effort)
 */
export function projectNameFromClaudePath(encoded: string): string {
  // Try to decode and use actual folder name
  const decoded = decodeClaudeProjectPath(encoded);
  if (decoded) return path.basename(decoded);

  // Fallback: strip common prefixes and take last 1-2 segments
  const withoutUser = encoded.replace(/^-Users-[^-]+-/, "-");
  const parts = withoutUser.replace(/^-/, "").split("-").filter(Boolean);
  if (parts.length === 0) return "unknown";

  // Try to find where home dirs end (Developer, Documents, Desktop, etc.)
  const homeSegments = new Set(["Developer", "Documents", "Desktop", "Downloads", "Library"]);
  let start = 0;
  for (let i = 0; i < parts.length; i++) {
    if (homeSegments.has(parts[i]!)) {
      start = i + 1;
      break;
    }
  }

  // Skip "Projets" if present
  if (parts[start] === "Projets") start++;

  return parts.slice(start).join("-") || parts[parts.length - 1] || "unknown";
}

/** Estimate token count from text (1 token ≈ 4 chars) */
export function estimateTokens(text: string): number {
  return Math.ceil(text.length / 4);
}

/** Format a date as YYYY-MM-DD */
export function formatDate(d: Date): string {
  return d.toISOString().slice(0, 10);
}

/** Today as YYYY-MM-DD */
export function today(): string {
  return formatDate(new Date());
}

/** Slugify a session ID: take first 8 chars of UUID */
export function shortId(uuid: string): string {
  return uuid.replace(/-/g, "").slice(0, 8);
}
