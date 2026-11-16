import test from "node:test";
import assert from "node:assert/strict";
import { installFakeDom } from "./fakedom.mjs";
import { sent } from "./tauri.mjs";

installFakeDom();

// Import after DOM is ready
const { buildCoudrop } = await import("../src/views/coudrop.ts");
const { State } = await import("../src/core/state.ts");

test("Coucou File Drop - Minimal Apple Design contains only upload icon, primary instruction, and browse action", () => {
  State.coudropConnected = true;
  State.coudropConnectedDevice = "Pixel 9";
  State.coudropProgress = null;

  const mockActions = {
    openSettings: () => {},
    close: () => {},
    switchView: () => {},
  };

  const view = buildCoudrop(mockActions);
  view.sync();

  const el = view.el;
  assert.ok(el, "Coudrop root element exists");

  // Transmitter / Drop Zone
  const transmitter = el.querySelector(".coudrop-transmitter");
  assert.ok(transmitter, "Drop zone (.coudrop-transmitter) exists");

  // 1. Upload Icon with border2
  const uploadIcon = transmitter.querySelector(".coudrop-upload-icon");
  assert.ok(uploadIcon, "Minimal upload icon (.coudrop-upload-icon) exists inside drop zone");
  assert.ok(uploadIcon.classList.contains("border-2") || uploadIcon.classList.contains("border2"), "Upload icon carries border2 class");

  // 2. Primary text: "Drop files to send"
  const title = transmitter.querySelector(".coudrop-title");
  assert.ok(title, "Primary text (.coudrop-title) exists inside drop zone");
  assert.equal(title.textContent, "Drop files to send");

  // 3. Secondary clickable text: "or browse files"
  const browseAction = transmitter.querySelector(".coudrop-browse-action");
  assert.ok(browseAction, "Secondary action (.coudrop-browse-action) exists inside drop zone");
  assert.equal(browseAction.textContent, "or browse files");

  // 4. Strict check: No unnecessary format badges, chips, or duplicate rings
  const chips = transmitter.querySelector(".coudrop-chips");
  assert.equal(chips, null, "Format badges/chips must NOT exist inside drop zone");

  const progressRing = transmitter.querySelector(".coudrop-progress-ring");
  assert.equal(progressRing, null, "Duplicate progress ring must NOT exist inside drop zone");

  const cancelBtn = transmitter.querySelector(".coudrop-cancel-btn");
  assert.equal(cancelBtn, null, "Duplicate cancel button must NOT exist inside drop zone");

  const radarPulse = transmitter.querySelector(".coudrop-radar-pulse");
  assert.equal(radarPulse, null, "Decorative radar pulse must NOT exist inside drop zone");

  // 5. Test drag-and-drop state transitions
  assert.equal(transmitter.classList.contains("drag-over"), false);

  transmitter.fire("dragenter");
  assert.equal(transmitter.classList.contains("drag-over"), true, "dragenter adds .drag-over");

  transmitter.fire("dragleave");
  assert.equal(transmitter.classList.contains("drag-over"), false, "dragleave removes .drag-over");

  // 6. Test click-to-browse trigger
  browseAction.fire("click");
  assert.ok(sent("coudrop_pick_files").length > 0, "Clicking 'or browse files' invokes coudrop_pick_files bridge command");

  // 7. Test Clear option in Recent Transfers section
  // Empty state: no clear button
  assert.equal(el.querySelector(".coudrop-clear-btn"), null, "Empty history has no Clear button");

  // Populate history
  State.coudropReceivedFiles = [
    { name: "test-photo.jpg", path: "/path/to/test-photo.jpg", size: 1024 * 500 },
    { name: "document.pdf", path: "/path/to/document.pdf", size: 1024 * 1024 },
  ];
  view.sync();

  const clearBtn = el.querySelector(".coudrop-clear-btn");
  assert.ok(clearBtn, "Clear button exists when recent transfers are present");
  assert.equal(clearBtn.textContent, "Clear");

  // Click Clear
  clearBtn.fire("click");
  assert.equal(State.coudropReceivedFiles.length, 0, "Clicking Clear empties coudropReceivedFiles");
  assert.equal(State.coudropHistoryCleared, true, "Clicking Clear marks history as cleared");
  assert.equal(el.querySelector(".coudrop-clear-btn"), null, "Clear button disappears after clearing");
  assert.ok(el.querySelector(".coudrop-history-empty"), "Empty state is displayed after clearing");
});
