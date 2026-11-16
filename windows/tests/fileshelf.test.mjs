import test from "node:test";
import assert from "node:assert/strict";
import { ShelfStore } from "../src/core/fileshelf.ts";

test("FileShelfStore - default shelf exists and is named Desk", () => {
  const shelves = ShelfStore.getShelves();
  assert.ok(shelves.length >= 1);
  const defaultShelf = shelves.find((s) => s.id === "desk");
  assert.ok(defaultShelf);
  assert.equal(defaultShelf.name, "Desk");
  assert.equal(defaultShelf.isDefault, true);
});

test("FileShelfStore - create new shelf and activate it", () => {
  const created = ShelfStore.createShelf("Project Assets");
  assert.equal(created.name, "Project Assets");
  assert.equal(ShelfStore.getActiveShelfId(), created.id);
  assert.equal(ShelfStore.getActiveShelf().name, "Project Assets");
});

test("FileShelfStore - rename shelf", () => {
  const shelf = ShelfStore.createShelf("Old Name");
  ShelfStore.renameShelf(shelf.id, "New Name");
  const updated = ShelfStore.getShelves().find((s) => s.id === shelf.id);
  assert.equal(updated?.name, "New Name");
});

test("FileShelfStore - add files and calculate properties", () => {
  const shelf = ShelfStore.createShelf("Test Files");
  const added = ShelfStore.addFiles(shelf.id, [
    { name: "document.pdf", size: 1024 * 50, type: "application/pdf" },
    { name: "photo.png", size: 1024 * 1024 * 2.5, type: "image/png" },
    { name: "script.ts", size: 4096, type: "text/typescript" },
  ]);

  assert.equal(added.length, 3);
  assert.equal(added[0].name, "document.pdf");
  assert.equal(added[0].extension, "pdf");
  assert.equal(added[1].extension, "png");
  assert.equal(added[2].extension, "ts");

  const files = ShelfStore.getSortedFiles(shelf.id, "recent");
  assert.equal(files.length, 3);
});

test("FileShelfStore - sequential file addition preserves existing files", () => {
  const shelf = ShelfStore.createShelf("Sequential Addition");
  ShelfStore.addFiles(shelf.id, [{ name: "initial.txt", path: "C:\\initial.txt", size: 100 }]);
  assert.equal(shelf.files.length, 1);

  // Add 5 more files
  const batch5 = Array.from({ length: 5 }, (_, i) => ({
    name: `doc_${i + 1}.pdf`,
    path: `C:\\docs\\doc_${i + 1}.pdf`,
    size: (i + 1) * 1024,
  }));
  ShelfStore.addFiles(shelf.id, batch5);
  assert.equal(shelf.files.length, 6);

  // Add 20 more files together
  const batch20 = Array.from({ length: 20 }, (_, i) => ({
    name: `asset_${i + 1}.png`,
    path: `C:\\assets\\asset_${i + 1}.png`,
    size: (i + 1) * 2048,
  }));
  ShelfStore.addFiles(shelf.id, batch20);
  assert.equal(shelf.files.length, 26);
});

test("FileShelfStore - duplicate detection prevents duplicate entries in the same shelf", () => {
  const shelf = ShelfStore.createShelf("Duplicate Test");
  const res1 = ShelfStore.addFilesWithResult(shelf.id, [
    { name: "Contract.docx", path: "C:\\Work\\Contract.docx", size: 5000 },
  ]);
  assert.equal(res1.added.length, 1);
  assert.equal(res1.duplicates.length, 0);

  // Attempt to add duplicate file with same path (different slash case)
  const res2 = ShelfStore.addFilesWithResult(shelf.id, [
    { name: "Contract.docx", path: "c:/work/contract.docx", size: 5000 },
    { name: "Invoice.pdf", path: "C:\\Work\\Invoice.pdf", size: 2000 },
  ]);
  assert.equal(res2.added.length, 1);
  assert.equal(res2.added[0].name, "Invoice.pdf");
  assert.equal(res2.duplicates.length, 1);
  assert.equal(res2.duplicates[0], "Contract.docx");
  assert.equal(shelf.files.length, 2);
});

test("FileShelfStore - independent shelves remain isolated", () => {
  const shelfA = ShelfStore.createShelf("Shelf Alpha");
  const shelfB = ShelfStore.createShelf("Shelf Beta");

  ShelfStore.addFiles(shelfA.id, [{ name: "fileA.txt", path: "C:\\fileA.txt", size: 10 }]);
  ShelfStore.addFiles(shelfB.id, [{ name: "fileB.txt", path: "C:\\fileB.txt", size: 20 }]);

  assert.equal(shelfA.files.length, 1);
  assert.equal(shelfA.files[0].name, "fileA.txt");
  assert.equal(shelfB.files.length, 1);
  assert.equal(shelfB.files[0].name, "fileB.txt");
});

test("FileShelfStore - all 7 sorting modes work correctly", () => {
  const shelf = ShelfStore.createShelf("All Sorts");
  const t0 = 1000000;
  ShelfStore.addFiles(shelf.id, [
    { name: "zebra.txt", path: "C:\\z.txt", size: 300 },
    { name: "apple.pdf", path: "C:\\a.pdf", size: 100 },
    { name: "mango.png", path: "C:\\m.png", size: 500 },
  ]);
  // Set explicit timestamps for testing
  shelf.files.find((f) => f.name === "zebra.txt").addedAt = t0 + 1;
  shelf.files.find((f) => f.name === "apple.pdf").addedAt = t0 + 2;
  shelf.files.find((f) => f.name === "mango.png").addedAt = t0 + 3;

  // 1. Name A-Z
  const byNameAsc = ShelfStore.getSortedFiles(shelf.id, "name_asc");
  assert.deepEqual(byNameAsc.map((f) => f.name), ["apple.pdf", "mango.png", "zebra.txt"]);

  // 2. Name Z-A
  const byNameDesc = ShelfStore.getSortedFiles(shelf.id, "name_desc");
  assert.deepEqual(byNameDesc.map((f) => f.name), ["zebra.txt", "mango.png", "apple.pdf"]);

  // 3. Recently added (newest first)
  const byRecent = ShelfStore.getSortedFiles(shelf.id, "recent");
  assert.deepEqual(byRecent.map((f) => f.name), ["mango.png", "apple.pdf", "zebra.txt"]);

  // 4. Oldest added
  const byOldest = ShelfStore.getSortedFiles(shelf.id, "oldest");
  assert.deepEqual(byOldest.map((f) => f.name), ["zebra.txt", "apple.pdf", "mango.png"]);

  // 5. Largest first
  const bySizeDesc = ShelfStore.getSortedFiles(shelf.id, "size_desc");
  assert.deepEqual(bySizeDesc.map((f) => f.name), ["mango.png", "zebra.txt", "apple.pdf"]);

  // 6. Smallest first
  const bySizeAsc = ShelfStore.getSortedFiles(shelf.id, "size_asc");
  assert.deepEqual(bySizeAsc.map((f) => f.name), ["apple.pdf", "zebra.txt", "mango.png"]);

  // 7. File type
  const byType = ShelfStore.getSortedFiles(shelf.id, "type");
  assert.deepEqual(byType.map((f) => f.name), ["apple.pdf", "mango.png", "zebra.txt"]);
});

test("FileShelfStore - rename display name without changing path or originalName", () => {
  const shelf = ShelfStore.createShelf("Rename File Test");
  const [file] = ShelfStore.addFiles(shelf.id, [
    { name: "Final_Presentation_v2_edit.pptx", path: "C:\\Work\\Final_Presentation_v2_edit.pptx", size: 1200 },
  ]);

  const renamed = ShelfStore.renameFile(shelf.id, file.id, "Presentation 2026.pptx");
  assert.equal(renamed, true);

  const updated = shelf.files.find((f) => f.id === file.id);
  assert.equal(updated.name, "Presentation 2026.pptx");
  assert.equal(updated.originalName, "Final_Presentation_v2_edit.pptx");
  assert.equal(updated.path, "C:\\Work\\Final_Presentation_v2_edit.pptx");
});

test("FileShelfStore - remove single file and batch remove", () => {
  const shelf = ShelfStore.createShelf("Remove Shelf");
  const added = ShelfStore.addFiles(shelf.id, [
    { name: "file1.txt", size: 100 },
    { name: "file2.txt", size: 200 },
    { name: "file3.txt", size: 300 },
  ]);

  ShelfStore.removeFile(shelf.id, added[0].id);
  assert.equal(ShelfStore.getActiveShelf().files.length, 2);

  ShelfStore.removeFiles(shelf.id, [added[1].id, added[2].id]);
  assert.equal(ShelfStore.getActiveShelf().files.length, 0);
});

test("FileShelfStore - clear shelf", () => {
  const shelf = ShelfStore.createShelf("Clear Shelf");
  ShelfStore.addFiles(shelf.id, [{ name: "item.txt", size: 100 }]);
  assert.equal(shelf.files.length, 1);

  ShelfStore.clearShelf(shelf.id);
  assert.equal(shelf.files.length, 0);
});

test("FileShelfStore - cannot delete default shelf", () => {
  const deleted = ShelfStore.deleteShelf("desk");
  assert.equal(deleted, false);
  const stillExists = ShelfStore.getShelves().some((s) => s.id === "desk");
  assert.equal(stillExists, true);
});

test("FileShelfStore - total size and formatBytes helper", () => {
  const shelf = ShelfStore.createShelf("Size Test");
  ShelfStore.addFiles(shelf.id, [
    { name: "a.bin", size: 1024 },
    { name: "b.bin", size: 1024 * 1024 * 23.6 },
  ]);

  const total = ShelfStore.getTotalSize(shelf.id);
  assert.ok(total > 23 * 1024 * 1024);

  assert.equal(ShelfStore.formatBytes(0), "0 B");
  assert.equal(ShelfStore.formatBytes(1024), "1.0 KB");
  assert.equal(ShelfStore.formatBytes(1024 * 1024 * 4.5), "4.5 MB");
  assert.equal(ShelfStore.formatBytes(1024 * 1024 * 1024 * 2.1), "2.1 GB");
});
