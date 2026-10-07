import "./memory.css";
import { Bridge, onEvent, type BulkMutationResult, type MemoryBrowseRequest, type MemoryFilter, type MemoryPage, type MemoryRecord, type MemoryUpdate, type SafeMemoryDetail } from "../core/bridge";
import { h, clear } from "../views/dom";
import type { Settings } from "../core/state";
import { applyValidationResult, bootstrapMemorySearch, canBulkRetire, confirmedScopeArgs, DetailGuard, individualRetirementCopy, loadCompleteDocumentUnion, normalizeMemoryPresentation, partialFailureAfterRefresh, refreshThenReport, runDialogAction, scopeFingerprint, setDetailOutcome, sliceDocumentUnion, snapshotBulkScope, snapshotIndividualRetirement, validateMemoryEdit, type BulkScope, type DialogActionState } from "./controllers";

const root = document.getElementById("memory-root")!;
const PAGE_SIZE = 25;
let page: MemoryPage = { items: [], total: 0, limit: PAGE_SIZE, offset: 0 };
let current: MemoryRecord | null = null;
let safeDetail: SafeMemoryDetail | null = null;
let opened: MemoryRecord | null = null;
let requestGeneration = 0;
let appliedRequest: MemoryBrowseRequest | null = null;
let activeBulkScope: BulkScope<MemoryBrowseRequest> | null = null;
let endpoint = "";
let tenant = "default";
let bank = "hieu";
let scopedDocumentIds: string[] = [];
const detailGuard = new DetailGuard();

const query = input("memory-query", "Search text", "search");
const state = select("memory-state", "Status", [["valid", "Valid"], ["invalidated", "Retired"]]);
const factType = select("memory-fact-type", "Type", [["", "All types"], ["world", "World"], ["experience", "Experience"], ["observation", "Observation"]]);
const startDate = input("memory-start-date", "From", "date");
const endDate = input("memory-end-date", "To", "date");
const timeField = select("memory-time-field", "Date field", [["updated_at", "Updated"], ["created_at", "Created"], ["mentioned_at", "Mentioned"], ["occurred_start", "Occurred start"], ["occurred_end", "Occurred end"], ["edited_at", "Edited"]]);
const platform = select("memory-platform", "Platform", [["", "All platforms"], ["windows", "Windows"], ["macos", "macOS"]]);
const retention = select("memory-retention", "Retention", [["", "All retention"], ["explicit", "Explicit"], ["inferred", "Inferred"]]);
const source = select("memory-source", "Source", [["", "All sources"], ["chat", "Chat"], ["selected-text", "Selected text"]]);
const status = h("div", { class: "status", role: "status", "aria-live": "polite" });
const list = h("ul", { class: "memory-list", "aria-label": "Memories, newest first" });
const detail = h("section", { class: "panel", "aria-labelledby": "detail-heading" }, h("h2", { id: "detail-heading", text: "Memory detail" }), h("p", { class: "detail-empty", text: "Select a memory to inspect it." }));
const previous = h("button", { text: "Previous" }) as HTMLButtonElement;
const next = h("button", { text: "Next" }) as HTMLButtonElement;
const pageLabel = h("span");
const search = h("button", { class: "primary", text: "Search" }) as HTMLButtonElement;
const bulk = h("button", { class: "danger", text: "Retire all matches…" }) as HTMLButtonElement;
const exportJson = h("button", { text: "Export page JSON" }) as HTMLButtonElement;
const exportMarkdown = h("button", { text: "Export page Markdown" }) as HTMLButtonElement;

function input(id: string, label: string, type: string) {
  const control = h("input", { id, type, autocomplete: "off" }) as HTMLInputElement;
  return { control, field: h("div", { class: id === "memory-query" ? "field search" : "field" }, h("label", { for: id, text: label }), control) };
}
function select(id: string, label: string, values: [string, string][]) {
  const control = h("select", { id }) as HTMLSelectElement;
  for (const [value, text] of values) control.append(h("option", { value, text }));
  return { control, field: h("div", { class: "field" }, h("label", { for: id, text: label }), control) };
}
function optional(value: string): string | undefined { return value || undefined; }
function filter(): MemoryFilter {
  return {
    query: scopedDocumentIds.length ? undefined : optional(query.control.value.trim()), state: state.control.value as MemoryFilter["state"],
    factType: optional(factType.control.value) as MemoryFilter["factType"], startDate: optional(startDate.control.value),
    endDate: optional(endDate.control.value), timeField: optional(timeField.control.value) as MemoryFilter["timeField"],
    platform: optional(platform.control.value) as MemoryFilter["platform"], retentionKind: optional(retention.control.value) as MemoryFilter["retentionKind"],
    sourceKind: optional(source.control.value) as MemoryFilter["sourceKind"],
  };
}
function request(offset = page.offset): MemoryBrowseRequest { return { filter: filter(), limit: PAGE_SIZE, offset }; }
function setStatus(message: string, error = false) { status.textContent = message; status.classList.toggle("error", error); }
function memoryError(error: unknown): { kind?: string; message: string } {
  if (error && typeof error === "object") {
    const value = error as { kind?: unknown; message?: unknown };
    if (typeof value.message === "string") return { kind: typeof value.kind === "string" ? value.kind : undefined, message: value.message };
  }
  return { message: String(error).replace(/^Error:\s*/, "") };
}
function errorText(error: unknown) { return memoryError(error).message; }
function setBusy(busy: boolean) {
  search.disabled = busy; search.setAttribute("aria-busy", String(busy));
  if (busy) setStatus("Loading memories…");
}

async function load(offset = 0) {
  const generation = ++requestGeneration;
  setBusy(true);
  try {
    const sent = request(offset);
    const result = scopedDocumentIds.length
      ? sliceDocumentUnion(await loadCompleteDocumentUnion(scopedDocumentIds, PAGE_SIZE, (documentId, limit, pageOffset) => Bridge.memoryList({ ...sent, filter: { ...sent.filter, query: undefined, documentId }, offset: pageOffset, limit })), PAGE_SIZE, offset)
      : await Bridge.memoryList(sent);
    if (generation !== requestGeneration) return;
    page = result;
    appliedRequest = structuredClone(sent);
    invalidateBulkScope();
    renderList();
    setStatus(`${result.total} ${sent.filter.state === "invalidated" ? "retired" : "valid"} memories. Showing ${result.items.length}.`);
  } catch (error: unknown) {
    if (generation !== requestGeneration || memoryError(error).kind === "cancelled") return;
    setStatus(errorText(error), true);
  } finally {
    if (generation === requestGeneration) setBusy(false);
  }
}

function renderList() {
  clear(list);
  for (const memory of page.items) {
    const button = h("button", { type: "button" }, h("strong", { text: memory.text.slice(0, 120) || "(empty memory)" }), h("small", { text: `${memory.factType} · ${memory.updatedAt ?? memory.createdAt ?? "unknown date"}` }));
    button.addEventListener("click", () => void openDetail(memory.id));
    list.append(h("li", {}, button));
  }
  if (!page.items.length) list.append(h("li", { class: "detail-empty", text: "No memories match these filters." }));
  previous.disabled = page.offset === 0;
  next.disabled = page.offset + page.items.length >= page.total || page.items.length === 0;
  pageLabel.textContent = page.total ? `${page.offset + 1}–${page.offset + page.items.length} of ${page.total}` : "0 results";
  bulk.hidden = !canBulkRetire(appliedRequest);
  bulk.disabled = !canBulkRetire(appliedRequest);
}

async function openDetail(id: string) {
  const generation = detailGuard.begin(id);
  setStatus("Loading memory detail…");
  try {
    const [loaded, safe] = await Promise.all([Bridge.memoryGet(id), Bridge.memorySafeDetail(id)]);
    setDetailOutcome(detailGuard, generation, id, () => {
      current = loaded; safeDetail = safe; opened = structuredClone(current); renderDetail(); setStatus("Memory detail loaded.");
    });
  } catch (error) { setDetailOutcome(detailGuard, generation, id, () => setStatus(errorText(error), true)); }
}

function renderDetail() {
  clear(detail);
  detail.append(h("h2", { id: "detail-heading", text: "Memory detail" }));
  if (!current || !opened || !safeDetail) { detail.append(h("p", { class: "detail-empty", text: "Select a memory to inspect it." })); return; }
  const text = h("textarea", { id: "detail-text" }) as HTMLTextAreaElement; text.value = current.text;
  const context = h("textarea", { id: "detail-context" }) as HTMLTextAreaElement; context.value = current.context ?? "";
  const type = h("select", { id: "detail-type" }) as HTMLSelectElement;
  for (const value of ["world", "experience", "observation"]) type.append(h("option", { value, text: value }));
  type.value = current.factType;
  const entities = h("input", { id: "detail-entities", type: "text", value: current.entities.join(", ") }) as HTMLInputElement;
  const start = h("input", { id: "detail-occurred-start", type: "text", value: current.occurredStart ?? "" }) as HTMLInputElement;
  const end = h("input", { id: "detail-occurred-end", type: "text", value: current.occurredEnd ?? "" }) as HTMLInputElement;
  const editError = h("p", { class: "status error", role: "alert", "aria-live": "polite" });
  const controls = { text, occurredStart: start, occurredEnd: end };
  const save = h("button", { class: "primary", text: "Save changes" }) as HTMLButtonElement;
  save.disabled = current.factType === "observation";
  save.addEventListener("click", () => {
    const values = { text: text.value, context: context.value || undefined, factType: type.value as MemoryRecord["factType"], entities: entities.value.split(",").map((v) => v.trim()).filter(Boolean), occurredStart: start.value || undefined, occurredEnd: end.value || undefined, expectedUpdatedAt: opened?.updatedAt };
    const invalid = validateMemoryEdit(values);
    for (const control of Object.values(controls)) { control.removeAttribute("aria-invalid"); control.removeAttribute("aria-describedby"); }
    const validity = { invalid: false, described: false, message: editError.textContent ?? "" };
    applyValidationResult(validity, invalid);
    editError.textContent = validity.message;
    if (invalid) { const control = controls[invalid.field]; control.setAttribute("aria-invalid", "true"); control.setAttribute("aria-describedby", "detail-edit-error"); control.focus(); return; }
    void saveEdit(values).catch((error) => setStatus(errorText(error), true));
  });
  const mutate = h("button", { class: current.state === "valid" ? "danger" : "", text: current.state === "valid" ? "Retire…" : "Restore" });
  mutate.addEventListener("click", () => current?.state === "valid" ? confirmOne() : void restore());
  const evidence = h("div", { class: "detail-meta" },
    h("p", { text: `Tenant ${safeDetail.tenant} · Bank ${safeDetail.bank}` }),
    h("p", { text: `Document ${safeDetail.documentId ?? "none"} · Chunk ${safeDetail.chunkId ?? "none"}` }),
    h("p", { text: `Source facts ${safeDetail.sourceFactIds.join(", ") || "none"}` }),
    ...Object.entries(safeDetail.metadata).map(([key, value]) => h("p", { text: `${key}: ${value}` })),
  );
  detail.append(h("div", { class: "detail-form" },
    h("p", { class: "detail-meta", text: `ID ${safeDetail.id} · ${safeDetail.state} · updated ${safeDetail.updatedAt ?? "unknown"}` }), evidence,
    field("detail-text", "Text", text), field("detail-context", "Context", context), field("detail-type", "Type", type),
    field("detail-entities", "Entities (comma separated)", entities), field("detail-occurred-start", "Occurred start", start), field("detail-occurred-end", "Occurred end", end),
    current.factType === "observation" ? h("p", { class: "status", text: "Observation memories are generated and cannot be edited." }) : null,
    Object.assign(editError, { id: "detail-edit-error" }),
    h("div", { class: "detail-actions" }, save, mutate),
  ));
}
function field(id: string, label: string, control: HTMLElement) { return h("div", { class: "field" }, h("label", { for: id, text: label }), control); }

async function saveEdit(update: MemoryUpdate, overwrite = false): Promise<void> {
  if (!current || !opened) throw new Error("No memory is selected.");
  setStatus(overwrite ? "Overwriting changed memory…" : "Checking for remote changes…");
  const result = await Bridge.memoryUpdate(current.id, opened, update, overwrite);
  if (result.kind === "conflict") { current = result.current; showConflict(update); return; }
  current = result.memory; opened = structuredClone(result.memory); renderDetail(); await load(page.offset); setStatus("Memory updated.");
}
function showConflict(update: MemoryUpdate) {
  const dialog = confirmation("conflict-heading", "Memory changed", "This memory changed after you opened it. Review the latest version before overwriting.", "Overwrite latest", () => saveEdit(update, true));
  dialog.querySelector(".dialog-copy")?.append(h("pre", { text: current?.text ?? "" }));
  document.body.append(dialog); dialog.showModal();
}
function confirmOne() {
  if (!current) return;
  const confirmationSnapshot = snapshotIndividualRetirement(current, endpoint, tenant, bank);
  const dialog = confirmation("retire-heading", "Retire 1 memory?", individualRetirementCopy(confirmationSnapshot), "Retire 1 memory", async () => {
    await Bridge.memoryRetire(confirmationSnapshot); current = null; opened = null; renderDetail(); await load(page.offset); setStatus("Memory retired.");
  });
  document.body.append(dialog); dialog.showModal();
}
async function restore() { if (!current) return; try { await Bridge.memoryRestore(current.id); await load(page.offset); current = null; opened = null; renderDetail(); setStatus("Memory restored."); } catch (error) { setStatus(errorText(error), true); } }

function confirmation(id: string, heading: string, copy: string, action: string, run: () => void | Promise<void>) {
  const dialog = h("dialog", { "aria-labelledby": id, "aria-describedby": `${id}-description` }) as HTMLDialogElement;
  const cancel = h("button", { text: "Cancel" }) as HTMLButtonElement;
  const confirm = h("button", { class: "danger", text: action }) as HTMLButtonElement;
  const error = h("p", { class: "status error", role: "alert", "aria-live": "assertive" });
  const actionState: DialogActionState = { busy: false, open: true, error: "" };
  cancel.addEventListener("click", () => dialog.close());
  confirm.addEventListener("click", async () => {
    confirm.disabled = true;
    try { await runDialogAction(actionState, async () => { await run(); }); }
    catch { error.textContent = actionState.error; }
    finally { confirm.disabled = actionState.busy; if (!actionState.open) dialog.close(); }
  });
  dialog.addEventListener("close", () => { if (dialog === activeBulkDialog) { activeBulkDialog = null; activeBulkScope = null; } dialog.remove(); });
  dialog.append(h("h2", { id, text: heading }), h("div", { id: `${id}-description`, class: "dialog-copy" }, h("p", { text: copy })), error, h("div", { class: "dialog-actions" }, cancel, confirm));
  dialog.addEventListener("cancel", () => dialog.close());
  queueMicrotask(() => cancel.focus());
  return dialog;
}

let activeBulkDialog: HTMLDialogElement | null = null;
function invalidateBulkScope() {
  if (!activeBulkScope || !activeBulkDialog) return;
  activeBulkScope = null;
  const error = activeBulkDialog.querySelector<HTMLElement>("[role=alert]");
  if (error) error.textContent = "The applied memory scope changed. Cancel and review a new confirmation.";
  activeBulkDialog.querySelector<HTMLButtonElement>("button.danger")?.setAttribute("disabled", "");
}
function summaryOf(request: MemoryBrowseRequest) {
  const parts = Object.entries(request.filter).filter(([, value]) => value).map(([key, value]) => `${key}: ${value}`);
  return parts.join(", ");
}
async function bulkRetire() {
  if (!appliedRequest || !canBulkRetire(appliedRequest)) return;
  const scope = snapshotBulkScope(appliedRequest, page.total, endpoint, tenant, bank);
  activeBulkScope = scope;
  const dialog = confirmation("bulk-confirm-heading", "Retire all matching valid memories?", `${scope.total} valid memories match “${summaryOf(scope.request)}” at ${scope.endpoint}, tenant ${scope.tenant}, bank ${scope.bank}.`, "Retire matches", async () => {
    if (!activeBulkScope || activeBulkScope.fingerprint !== scope.fingerprint || scopeFingerprint(scope.request, scope.endpoint, scope.tenant, scope.bank) !== scope.fingerprint) throw new Error("The applied memory scope changed. Review a new confirmation.");
    const result = partialFailureAfterRefresh(await Bridge.memoryBulkRetire(confirmedScopeArgs(scope).scope));
    await refreshThenReport(() => load(0), showBulkResult, result);
  });
  activeBulkDialog = dialog;
  document.body.append(dialog); dialog.showModal();
}
function showBulkResult(result: BulkMutationResult) {
  if (!result.failed.length) { setStatus(`Retired ${result.succeeded.length} memories.`); return; }
  setStatus(`Retired ${result.succeeded.length} of ${result.requested}. Failed IDs: ${result.failed.map((failure) => `${failure.id}: ${failure.message}`).join("; ")}`, true);
}
async function saveExport(format: "json" | "markdown") {
  try { const exported = await Bridge.memoryExport(page.items, format); const saved = await Bridge.memorySaveExport(exported); setStatus(saved ? `Saved ${exported.filename}.` : "Export cancelled."); } catch (error) { setStatus(errorText(error), true); }
}

search.addEventListener("click", () => { scopedDocumentIds = []; void load(0); });
query.control.addEventListener("keydown", (event) => { if (event.key === "Enter" && !event.isComposing) { event.preventDefault(); void load(0); } });
previous.addEventListener("click", () => void load(Math.max(0, page.offset - PAGE_SIZE)));
next.addEventListener("click", () => void load(page.offset + PAGE_SIZE));
bulk.addEventListener("click", () => void bulkRetire());
exportJson.addEventListener("click", () => void saveExport("json"));
exportMarkdown.addEventListener("click", () => void saveExport("markdown"));

root.replaceChildren(
  h("header", {}, h("div", {}, h("h1", { text: "Memory Manager" }), h("p", { text: "Browse newest-first, edit, export, retire, and restore Hindsight memories." }))),
  h("form", { class: "filters", "aria-label": "Memory filters", onsubmit: (event: Event) => { event.preventDefault(); void load(0); } }, query.field, state.field, factType.field, startDate.field, endDate.field, timeField.field, platform.field, retention.field, source.field, h("div", { class: "actions" }, search, bulk, exportJson, exportMarkdown)),
  status,
  h("div", { class: "layout" }, h("section", { class: "panel", "aria-labelledby": "results-heading" }, h("h2", { id: "results-heading", text: "Memories" }), list, h("nav", { class: "pagination", "aria-label": "Memory pages" }, previous, pageLabel, next)), detail),
);

async function bootstrap() {
  const boot = await Bridge.boot();
  if (boot) { endpoint = boot.settings.hindsight.baseUrl; tenant = boot.settings.hindsight.tenant; bank = boot.settings.hindsight.bank; }
  await bootstrapMemorySearch(
    (handler) => onEvent<{ query?: string; documentIds?: string[] }>("memory-search", handler),
    () => Bridge.memoryWindowReady(),
    (payload) => {
      const presentation = normalizeMemoryPresentation(payload);
      scopedDocumentIds = presentation.documentIds;
      query.control.value = presentation.query ?? "";
      setStatus(scopedDocumentIds.length ? `Loading ${scopedDocumentIds.length} document scopes…` : "Loading text fallback…");
      void load(0);
    },
  );
  await onEvent<Settings>("settings-changed", (nextSettings) => {
    if (endpoint !== nextSettings.hindsight.baseUrl || tenant !== nextSettings.hindsight.tenant || bank !== nextSettings.hindsight.bank) invalidateBulkScope();
    endpoint = nextSettings.hindsight.baseUrl; tenant = nextSettings.hindsight.tenant; bank = nextSettings.hindsight.bank;
  });
  await load(0);
}
void bootstrap();
