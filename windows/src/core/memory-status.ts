export type MemorySaveStatus = "saving" | "saved" | "notSaved";

export interface MemoryStatusMessage {
  turnId?: string;
  memoryStatus?: MemorySaveStatus;
}

export class PendingMemoryStatuses {
  private readonly values = new Map<string, MemorySaveStatus>();

  constructor(private readonly limit = 128) {}

  set(turnId: string, status: MemorySaveStatus) {
    this.values.delete(turnId);
    this.values.set(turnId, status);
    while (this.values.size > this.limit) {
      const oldest = this.values.keys().next().value;
      if (oldest == null) break;
      this.values.delete(oldest);
    }
  }

  take(turnId: string): MemorySaveStatus | undefined {
    const status = this.values.get(turnId);
    this.values.delete(turnId);
    return status;
  }

  clear() { this.values.clear(); }
  get size() { return this.values.size; }
}

export function applyPendingMemoryStatus<T extends MemoryStatusMessage>(message: T, pending: PendingMemoryStatuses): T {
  if (message.turnId) message.memoryStatus = pending.take(message.turnId);
  return message;
}

export function resetMemoryStatuses(pending: PendingMemoryStatuses) {
  pending.clear();
}
