import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const read = (path) => readFileSync(resolve(root, path), "utf8");

function section(text, name) {
  const match = text.match(new RegExp(`/\\* Begin ${name} section \\*/([\\s\\S]*?)/\\* End ${name} section \\*/`));
  assert.ok(match, `missing ${name} section`);
  return match[1];
}

function objectBodies(text) {
  const values = new Map();
  const matcher = /^\s*([A-F0-9]{24})\s*(?:\/\*[^\n]*?\*\/)?\s*=\s*\{([\s\S]*?)\};/gm;
  for (const match of text.matchAll(matcher)) {
    assert.ok(!values.has(match[1]), `duplicate object ID ${match[1]}`);
    values.set(match[1], match[2]);
  }
  return values;
}

function listIDs(body, key) {
  const match = body.match(new RegExp(`${key}\\s*=\\s*\\(([\\s\\S]*?)\\);`));
  assert.ok(match, `missing ${key} list`);
  return [...match[1].matchAll(/([A-F0-9]{24})\s*(?:\/\*[^\n]*?\*\/)?\s*,/g)].map((value) => value[1]);
}

function targetSourcePhase(text, targetName) {
  const targets = objectBodies(section(text, "PBXNativeTarget"));
  const match = [...targets.entries()].find(([, body]) => new RegExp(`name\\s*=\\s*${targetName};`).test(body));
  assert.ok(match, `missing target ${targetName}`);
  const phases = listIDs(match[1], "buildPhases");
  const sourceObjects = objectBodies(section(text, "PBXSourcesBuildPhase"));
  const sourcePhases = phases.filter((id) => sourceObjects.has(id));
  assert.equal(sourcePhases.length, 1, `${targetName} must have exactly one Sources phase`);
  return { id: sourcePhases[0], fileIDs: listIDs(sourceObjects.get(sourcePhases[0]), "files") };
}

export function validateRequiredSources(text, required, targetNames = ["NotchBuddy", "CoucouAppStore"]) {
  const fileRefs = objectBodies(section(text, "PBXFileReference"));
  const buildFiles = objectBodies(section(text, "PBXBuildFile"));
  const phases = new Map(targetNames.map((name) => [name, targetSourcePhase(text, name)]));

  for (const path of required) {
    const refs = [...fileRefs.entries()].filter(([, body]) => new RegExp(`path\\s*=\\s*${path.replaceAll(".", "\\.")};`).test(body));
    assert.equal(refs.length, 1, `${path} must have exactly one PBXFileReference`);
    const fileRefID = refs[0][0];
    const builds = [...buildFiles.entries()].filter(([, body]) => new RegExp(`fileRef\\s*=\\s*${fileRefID}(?:\\s|;|/)`).test(body));
    assert.equal(builds.length, 2, `${path} must have exactly two PBXBuildFile objects`);
    const buildIDs = new Set(builds.map(([id]) => id));
    const usedByTarget = new Map();
    for (const [targetName, phase] of phases) {
      const entries = phase.fileIDs.filter((id) => buildIDs.has(id));
      assert.equal(entries.length, 1, `${path} must occur exactly once in ${targetName} Sources phase`);
      usedByTarget.set(targetName, entries[0]);
    }
    const usedIDs = [...usedByTarget.values()];
    assert.equal(new Set(usedIDs).size, 2, `${path} must use distinct PBXBuildFile IDs in the two target phases`);
    assert.deepEqual(new Set(usedIDs), buildIDs, `${path} target phases must use the complete PBXBuildFile ID set`);
    for (const buildID of buildIDs) {
      assert.equal(usedIDs.filter((used) => used === buildID).length, 1, `${path} build ID ${buildID} must be used exactly once across target phases`);
    }
  }
}

function fixture({ includeRef = true, duplicateFirstPhase = false, includeSecondPhase = true, reuseFirstBuildInSecondPhase = false } = {}) {
  const fileRef = "AAAAAAAAAAAAAAAAAAAAAAAA";
  const firstBuild = "BBBBBBBBBBBBBBBBBBBBBBBB";
  const secondBuild = "CCCCCCCCCCCCCCCCCCCCCCCC";
  const firstTarget = "111111111111111111111111";
  const secondTarget = "222222222222222222222222";
  const firstPhase = "333333333333333333333333";
  const secondPhase = "444444444444444444444444";
  return `
/* Begin PBXFileReference section */
${includeRef ? `${fileRef} /* Required.swift */ = {isa = PBXFileReference; path = Required.swift; sourceTree = "<group>"; };` : ""}
/* End PBXFileReference section */
/* Begin PBXBuildFile section */
${firstBuild} /* Required.swift in Sources */ = {isa = PBXBuildFile; fileRef = ${fileRef} /* Required.swift */; };
${secondBuild} /* Required.swift in Sources */ = {isa = PBXBuildFile; fileRef = ${fileRef} /* Required.swift */; };
/* End PBXBuildFile section */
/* Begin PBXNativeTarget section */
${firstTarget} /* NotchBuddy */ = {isa = PBXNativeTarget; buildPhases = (${firstPhase} /* Sources */,); name = NotchBuddy; };
${secondTarget} /* CoucouAppStore */ = {isa = PBXNativeTarget; buildPhases = (${secondPhase} /* Sources */,); name = CoucouAppStore; };
/* End PBXNativeTarget section */
/* Begin PBXSourcesBuildPhase section */
${firstPhase} /* Sources */ = {isa = PBXSourcesBuildPhase; files = (${firstBuild} /* Required.swift in Sources */,${duplicateFirstPhase ? `${firstBuild} /* Required.swift in Sources */,` : ""}); };
${secondPhase} /* Sources */ = {isa = PBXSourcesBuildPhase; files = (${includeSecondPhase ? `${reuseFirstBuildInSecondPhase ? firstBuild : secondBuild} /* Required.swift in Sources */,` : ""}); };
/* End PBXSourcesBuildPhase section */`;
}

function expectInvalid(text, label) {
  assert.throws(() => validateRequiredSources(text, ["Required.swift"]), undefined, label);
}

validateRequiredSources(fixture(), ["Required.swift"]);
expectInvalid(fixture({ includeRef: false }), "missing ref fixture must fail");
expectInvalid(fixture({ duplicateFirstPhase: true }), "duplicate phase entry fixture must fail");
expectInvalid(fixture({ includeSecondPhase: false }), "missing second phase fixture must fail");
expectInvalid(fixture({ reuseFirstBuildInSecondPhase: true }), "same build ID in both target phases must fail");

const pbx = read("NotchBuddy/NotchBuddy.xcodeproj/project.pbxproj");
validateRequiredSources(pbx, ["ClaudeService.swift", "ChatMemoryContracts.swift", "KeychainStore.swift", "HindsightUIContracts.swift", "MemoryManagerView.swift", "MemoryManagerWindowController.swift"]);

const appState = read("NotchBuddy/Sources/App/AppState.swift");
assert.ok(appState.includes("@Published var privateChat = AppSessionDefaults.privateChat"));
assert.ok(!appState.includes('forKey: "privateChat"'));
assert.ok(!appState.includes('object(forKey: "privateChat")'));
assert.ok(appState.includes("lastIndex(where: { $0.turnId == turnId && $0.role == .assistant })"));

const keychain = read("NotchBuddy/Sources/App/KeychainStore.swift");
assert.ok(keychain.includes("keys: [String]? = nil"));
assert.ok(!keychain.includes("keys: [String] = KeychainStore.allKeys"));

const manager = read("NotchBuddy/Sources/App/MemoryManagerView.swift");
assert.ok(manager.includes("private var requestState = MemoryManagerRequestState()"));
assert.ok(manager.includes("service.memorySafeDetail(id: memory.id)"));
assert.ok(manager.includes("setPendingDocumentIds"));
assert.ok(!manager.includes("private var listGeneration"));
assert.ok(!manager.includes("private var detailGeneration"));

const providerContracts = read("NotchBuddy/Sources/App/ChatMemoryContracts.swift");
const claudeService = read("NotchBuddy/Sources/App/ClaudeService.swift");
assert.match(claudeService, /final class ClaudeService:\s*ChatProviderServing/);
assert.match(claudeService, /func send\(_ request: ChatProviderRequest\) async throws -> ChatProviderResult/);
assert.ok(claudeService.includes("claudeRequestParts(request"));
assert.ok(providerContracts.includes('"system": anthropicSystemContent'));

const coordinator = read("NotchBuddy/Sources/App/ChatMemoryCoordinator.swift");
assert.ok(coordinator.includes("discoverRetainedArtifact(maxAttempts: 4"));
assert.ok(coordinator.includes("func prepareForgetTurn(turnId: String)"));
assert.ok(coordinator.includes("func forgetTurn(confirmation: PreparedForgetTurn)"));
assert.ok(coordinator.includes("completeDocumentUnion(documentIds:"));
assert.ok(coordinator.includes("registry.clear()"));
assert.ok(!coordinator.includes("String(describing: value)"));

const settings = read("NotchBuddy/Sources/App/SettingsView.swift");
assert.ok(settings.includes("HindsightCredentialReplacement.store"));
assert.ok(!settings.includes("KeychainStore.shared.set(hindsightBearerTokenKey"));

const chat = read("NotchBuddy/Sources/App/IslandViewContent.swift");
assert.ok(chat.includes("confirmForget(turnId:"));
assert.ok(chat.includes("present(documentIds: result.documentIds)"));

const windowController = read("NotchBuddy/Sources/App/MemoryManagerWindowController.swift");
assert.ok(windowController.includes("memoryManagerWindowConfiguration()"));
assert.ok(!windowController.includes(".standard"));

console.log("hindsight-project: PASS");
