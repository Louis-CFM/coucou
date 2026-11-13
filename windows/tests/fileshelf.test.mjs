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

test("FileShelfStore - sorting files by name and size", () => {
  const shelf = ShelfStore.createShelf("Sort Shelf");
  ShelfStore.addFiles(shelf.id, [
    { name: "beta.txt", size: 500 },
    { name: "alpha.txt", size: 1000 },
    { name: "gamma.txt", size: 100 },
  ]);

  const byName = ShelfStore.getSortedFiles(shelf.id, "name");
  assert.equal(byName[0].name, "alpha.txt");
  assert.equal(byName[1].name, "beta.txt");
  assert.equal(byName[2].name, "gamma.txt");

  const bySize = ShelfStore.getSortedFiles(shelf.id, "size");
  assert.equal(bySize[0].name, "alpha.txt");
  assert.equal(bySize[1].name, "beta.txt");
  assert.equal(bySize[2].name, "gamma.txt");
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

test("FileShelfStore - formatBytes helper", () => {
  assert.equal(ShelfStore.formatBytes(0), "0 B");
  assert.equal(ShelfStore.formatBytes(1024), "1.0 KB");
  assert.equal(ShelfStore.formatBytes(1024 * 1024 * 4.5), "4.5 MB");
});
