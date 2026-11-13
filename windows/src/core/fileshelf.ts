// File Shelf Store: Staging dock for parked files and folders in Coucou's notch.

export interface ParkedFile {
  id: string;
  name: string;
  path: string;
  size: number;
  mimeType: string;
  extension: string;
  addedAt: number;
  lastAccessedAt: number;
}

export interface Shelf {
  id: string;
  name: string;
  isDefault?: boolean;
  createdAt: number;
  files: ParkedFile[];
}

export type ShelfSort = "recent" | "name" | "size" | "type";

const STORAGE_KEY = "coucou_file_shelves_v1";
const ACTIVE_SHELF_KEY = "coucou_active_shelf_v1";

function defaultShelves(): Shelf[] {
  return [
    {
      id: "desk",
      name: "Desk",
      isDefault: true,
      createdAt: Date.now(),
      files: [],
    },
  ];
}

class FileShelfStore {
  private shelves: Shelf[] = [];
  private activeShelfId = "desk";
  private listeners = new Set<() => void>();

  constructor() {
    this.load();
  }

  private load() {
    if (typeof localStorage === "undefined") {
      this.shelves = defaultShelves();
      return;
    }
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (raw) {
        const parsed = JSON.parse(raw);
        if (Array.isArray(parsed) && parsed.length > 0) {
          this.shelves = parsed;
        } else {
          this.shelves = defaultShelves();
        }
      } else {
        this.shelves = defaultShelves();
      }

      const savedActive = localStorage.getItem(ACTIVE_SHELF_KEY);
      if (savedActive && this.shelves.some((s) => s.id === savedActive)) {
        this.activeShelfId = savedActive;
      } else {
        this.activeShelfId = this.shelves[0]?.id ?? "desk";
      }
    } catch {
      this.shelves = defaultShelves();
      this.activeShelfId = "desk";
    }
  }

  private save() {
    if (typeof localStorage === "undefined") return;
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(this.shelves));
      localStorage.setItem(ACTIVE_SHELF_KEY, this.activeShelfId);
    } catch {
      /* ignore storage quota errors */
    }
  }

  private notify() {
    this.save();
    for (const listener of this.listeners) {
      try {
        listener();
      } catch (err) {
        console.error("[fileshelf] listener error", err);
      }
    }
  }

  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  getShelves(): Shelf[] {
    return this.shelves;
  }

  getActiveShelfId(): string {
    return this.activeShelfId;
  }

  setActiveShelfId(id: string) {
    if (this.shelves.some((s) => s.id === id)) {
      this.activeShelfId = id;
      this.notify();
    }
  }

  getActiveShelf(): Shelf {
    return (
      this.shelves.find((s) => s.id === this.activeShelfId) ??
      this.shelves[0] ??
      defaultShelves()[0]
    );
  }

  createShelf(name: string): Shelf {
    const trimmed = name.trim();
    if (!trimmed) return this.getActiveShelf();

    const id = `shelf_${Date.now()}_${Math.random().toString(36).slice(2, 7)}`;
    const shelf: Shelf = {
      id,
      name: trimmed,
      createdAt: Date.now(),
      files: [],
    };
    this.shelves.push(shelf);
    this.activeShelfId = id;
    this.notify();
    return shelf;
  }

  renameShelf(id: string, newName: string) {
    const trimmed = newName.trim();
    if (!trimmed) return;
    const shelf = this.shelves.find((s) => s.id === id);
    if (shelf) {
      shelf.name = trimmed;
      this.notify();
    }
  }

  deleteShelf(id: string): boolean {
    const shelf = this.shelves.find((s) => s.id === id);
    if (!shelf || shelf.isDefault || this.shelves.length <= 1) return false;

    this.shelves = this.shelves.filter((s) => s.id !== id);
    if (this.activeShelfId === id) {
      this.activeShelfId = this.shelves[0]?.id ?? "desk";
    }
    this.notify();
    return true;
  }

  addFiles(
    shelfId: string,
    rawFiles: { name: string; path?: string; size?: number; type?: string }[]
  ): ParkedFile[] {
    const shelf = this.shelves.find((s) => s.id === shelfId);
    if (!shelf || rawFiles.length === 0) return [];

    const added: ParkedFile[] = [];
    const now = Date.now();

    for (const f of rawFiles) {
      const ext = f.name.includes(".") ? f.name.split(".").pop()?.toLowerCase() ?? "" : "";
      const parked: ParkedFile = {
        id: `file_${now}_${Math.random().toString(36).slice(2, 7)}`,
        name: f.name,
        path: f.path || f.name,
        size: typeof f.size === "number" ? f.size : 0,
        mimeType: f.type || "application/octet-stream",
        extension: ext,
        addedAt: now,
        lastAccessedAt: now,
      };
      shelf.files.unshift(parked);
      added.push(parked);
    }

    this.notify();
    return added;
  }

  removeFile(shelfId: string, fileId: string) {
    const shelf = this.shelves.find((s) => s.id === shelfId);
    if (!shelf) return;
    shelf.files = shelf.files.filter((f) => f.id !== fileId);
    this.notify();
  }

  removeFiles(shelfId: string, fileIds: string[]) {
    const shelf = this.shelves.find((s) => s.id === shelfId);
    if (!shelf || fileIds.length === 0) return;
    const idSet = new Set(fileIds);
    shelf.files = shelf.files.filter((f) => !idSet.has(f.id));
    this.notify();
  }

  clearShelf(shelfId: string) {
    const shelf = this.shelves.find((s) => s.id === shelfId);
    if (!shelf) return;
    shelf.files = [];
    this.notify();
  }

  getSortedFiles(shelfId: string, sort: ShelfSort = "recent"): ParkedFile[] {
    const shelf = this.shelves.find((s) => s.id === shelfId);
    if (!shelf) return [];
    const files = [...shelf.files];

    switch (sort) {
      case "recent":
        return files.sort((a, b) => b.addedAt - a.addedAt);
      case "name":
        return files.sort((a, b) => a.name.localeCompare(b.name));
      case "size":
        return files.sort((a, b) => b.size - a.size);
      case "type":
        return files.sort((a, b) => a.extension.localeCompare(b.extension));
      default:
        return files;
    }
  }

  formatBytes(bytes: number): string {
    if (bytes <= 0) return "0 B";
    const k = 1024;
    const sizes = ["B", "KB", "MB", "GB"];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    const val = (bytes / Math.pow(k, i)).toFixed(i === 0 ? 0 : 1);
    return `${val} ${sizes[i]}`;
  }
}

export const ShelfStore = new FileShelfStore();
