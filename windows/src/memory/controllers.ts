export interface BrowseRequest<F extends { state: string } = { state: string }> { filter: F; limit: number; offset: number }
export interface BulkScope<R extends BrowseRequest = BrowseRequest> { request: R; total: number; endpoint: string; tenant: string; bank: string; fingerprint: string }

function clone<T>(value: T): T { return JSON.parse(JSON.stringify(value)) as T; }
export function normalizeEndpoint(value: string): string {
  const url = new URL(value.trim());
  if (url.username || url.password || url.search || url.hash) throw new Error("Invalid Hindsight endpoint");
  if ((url.protocol === "https:" && url.port === "443") || (url.protocol === "http:" && url.port === "80")) url.port = "";
  url.pathname = url.pathname === "/" ? "" : url.pathname.replace(/\/+$/, "");
  return url.toString().replace(/\/$/, "");
}
export function scopeFingerprint<R extends BrowseRequest>(request: R, endpoint: string, tenant: string, bank: string): string {
  return `${normalizeEndpoint(endpoint)}\n${tenant}\n${bank}\n${JSON.stringify(request)}`;
}
export function snapshotBulkScope<R extends BrowseRequest>(request: R, total: number, endpoint: string, tenant: string, bank: string): BulkScope<R> {
  const frozen = clone(request); const normalized = normalizeEndpoint(endpoint);
  return { request: frozen, total, endpoint: normalized, tenant, bank, fingerprint: scopeFingerprint(frozen, normalized, tenant, bank) };
}
export function canBulkRetire(request: BrowseRequest | null): boolean { return request?.filter.state === "valid"; }
export function sameScope(scope: BulkScope, fingerprint: string): boolean { return scope.fingerprint === fingerprint; }
export function confirmedScopeArgs<R extends BrowseRequest>(scope: BulkScope<R>) { return { scope: { request: scope.request, endpoint: scope.endpoint, tenant: scope.tenant, bank: scope.bank, fingerprint: scope.fingerprint } }; }

export interface IndividualRetirement { id: string; text: string; updatedAt?: string; endpoint: string; tenant: string; bank: string }
export function snapshotIndividualRetirement(memory: { id: string; text: string; updatedAt?: string }, endpoint: string, tenant: string, bank: string): IndividualRetirement {
  return { id: memory.id, text: memory.text, updatedAt: memory.updatedAt, endpoint: normalizeEndpoint(endpoint), tenant, bank };
}
export function individualRetirementCopy(value: IndividualRetirement): string {
  return `Retire 1 memory\nID: ${value.id}\nExcerpt: ${value.text.slice(0, 160)}\nTenant: ${value.tenant}\nBank: ${value.bank}\nRetirement is reversible from the Retired view.`;
}

export interface MemoryPresentation { query?: string; documentIds: string[] }
export function normalizeMemoryPresentation(payload: { query?: string; documentIds?: string[] }): MemoryPresentation {
  const documentIds = [...new Set((payload.documentIds ?? []).map((value) => value.trim()).filter(Boolean))];
  return { query: documentIds.length ? undefined : payload.query?.trim() || undefined, documentIds };
}
export function mergeDocumentPages<T extends { id: string }>(pages: { items: T[] }[], limit: number, offset: number) {
  const seen = new Set<string>();
  const items = pages.flatMap((page) => page.items).filter((item) => !seen.has(item.id) && !!seen.add(item.id));
  return { items: items.slice(offset, offset + limit), total: items.length, limit, offset };
}

export async function loadCompleteDocumentUnion<T extends { id: string }>(
  documentIds: string[],
  pageSize: number,
  loadPage: (documentId: string, limit: number, offset: number) => Promise<{ items: T[]; offset: number }>,
  maxPages = 10_000,
): Promise<T[]> {
  const seen = new Set<string>();
  const items: T[] = [];
  for (const documentId of documentIds) {
    let offset = 0;
    for (let pageNumber = 0; ; pageNumber += 1) {
      if (pageNumber >= maxPages) throw new Error("Document pagination exceeded the maximum page count.");
      const page = await loadPage(documentId, pageSize, offset);
      for (const item of page.items) if (!seen.has(item.id)) { seen.add(item.id); items.push(item); }
      if (!page.items.length || page.items.length < pageSize) break;
      const next = page.offset + page.items.length;
      if (next <= offset) throw new Error("Document pagination did not advance.");
      offset = next;
    }
  }
  return items;
}

export function sliceDocumentUnion<T>(items: T[], limit: number, offset: number) {
  return { items: items.slice(offset, offset + limit), total: items.length, limit, offset };
}

export async function bootstrapMemorySearch(
  listen: (handler: (payload: { query?: string; documentIds?: string[] }) => void) => Promise<() => void>,
  ready: () => Promise<void>,
  handler: (payload: { query?: string; documentIds?: string[] }) => void = () => {},
): Promise<() => void> {
  const unlisten = await listen(handler);
  await ready();
  return unlisten;
}

export interface ForgetConfirmation {
  turnId: string;
  generation: number;
  endpoint: string;
  tenant: string;
  bank: string;
  knownIds: string[];
  documentIds: string[];
  artifactFingerprint: string;
}
export function snapshotForgetConfirmation(value: ForgetConfirmation): ForgetConfirmation {
  return { ...value, knownIds: [...new Set(value.knownIds)], documentIds: [...new Set(value.documentIds)] };
}
export function forgetTurnArgs(value: ForgetConfirmation) { return { confirmation: clone(value) }; }
export function forgetConfirmationCopy(value: ForgetConfirmation): string {
  return `Retire memories from this turn?\nTurn ID: ${value.turnId}\nEndpoint: ${value.endpoint}\nTenant: ${value.tenant}\nBank: ${value.bank}\nKnown remote IDs: ${value.knownIds.length}\nDocument IDs: ${value.documentIds.join(", ") || "none"}\nRetirement is reversible.`;
}

export function chatRenderKey(messages: readonly { id: number; memoryStatus?: string }[]): string {
  return messages.map((message) => `${message.id}:${message.memoryStatus ?? ""}`).join("|");
}
export function memoryStatusText(status?: "saving" | "saved" | "notSaved"): string {
  return status === "saving" ? "Saving memory…" : status === "saved" ? "Memory saved" : status === "notSaved" ? "Memory not saved" : "";
}

export class DetailGuard {
  private generation = 0;
  private selectedId: string | null = null;
  begin(id: string): number { this.selectedId = id; return ++this.generation; }
  accept(generation: number, id: string): boolean { return generation === this.generation && id === this.selectedId; }
}
export function setDetailOutcome(guard: DetailGuard, generation: number, id: string, apply: () => void): boolean {
  if (!guard.accept(generation, id)) return false;
  apply(); return true;
}

export interface DialogActionState { busy: boolean; open: boolean; error: string }
export function dialogActionState(): DialogActionState { return { busy: false, open: true, error: "" }; }
export async function runDialogAction(state: DialogActionState, action: () => Promise<void>): Promise<void> {
  state.busy = true; state.error = "";
  try { await action(); state.open = false; }
  catch (error) { state.error = String(error).replace(/^Error:\s*/, ""); throw error; }
  finally { state.busy = false; }
}

function validIsoTimestamp(raw: string): boolean {
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?(Z|([+-])(\d{2}):(\d{2}))$/.exec(raw);
  if (!match) return false;
  const [, year, month, day, hour, minute, second, fraction = "", zone, sign, zoneHour = "0", zoneMinute = "0"] = match;
  const parts = [year, month, day, hour, minute, second].map(Number);
  if (+month < 1 || +month > 12 || +hour > 23 || +minute > 59 || +second > 59 || +zoneHour > 23 || +zoneMinute > 59) return false;
  const days = new Date(Date.UTC(+year, +month, 0)).getUTCDate();
  if (+day < 1 || +day > days) return false;
  const milliseconds = +(fraction + "000").slice(0, 3);
  let utc = Date.UTC(...parts.slice(0, 3).map((value, index) => index === 1 ? value - 1 : value) as [number, number, number], +hour, +minute, +second, milliseconds);
  if (zone !== "Z") utc -= (sign === "+" ? 1 : -1) * (+zoneHour * 60 + +zoneMinute) * 60_000;
  return Number.isFinite(utc);
}

export function validateMemoryEdit(value: { text: string; occurredStart?: string; occurredEnd?: string }): { field: "text" | "occurredStart" | "occurredEnd"; message: string } | null {
  if (!value.text.trim()) return { field: "text", message: "Memory text is required." };
  for (const [field, raw] of [["occurredStart", value.occurredStart], ["occurredEnd", value.occurredEnd]] as const) {
    if (raw && !validIsoTimestamp(raw)) return { field, message: "Use a real ISO date/time with timezone, for example 2026-10-02T10:00:00Z." };
  }
  return null;
}

export function applyValidationResult(state: { invalid: boolean; described: boolean; message: string }, result: { message: string } | null) {
  state.invalid = !!result; state.described = !!result; state.message = result?.message ?? "";
}

export interface PartialResult { requested: number; succeeded: string[]; failed: { id: string; message: string }[] }
export function partialFailureAfterRefresh<T extends PartialResult>(result: T): T { return clone(result); }
export async function refreshThenReport<T extends PartialResult>(refresh: () => Promise<void>, report: (result: T) => void, result: T): Promise<void> {
  await refresh(); report(result);
}
