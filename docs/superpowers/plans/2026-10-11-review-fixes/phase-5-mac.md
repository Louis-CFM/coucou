# Phase 5 — Mac app (Swift) and its `nb-hook.py` relay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:**
- Stop the unbounded APNs retry loop (C2).
- Keep the hook server alive through `accept` errors (C6).
- Stop the 5.2 s idle timer from landing on a new turn (C7).
- Let the relay give up in 1.5 s when the app cannot show a card (C16).
- Cap what the relay forwards.
- Keep one Python template instead of two.
- Only ever touch Coucou's own entries in `~/.claude/settings.json` (C20).
- Put a time limit on runs started from the iPhone.

**Architecture:** Each Swift fix is a small pure type in its own file: `ApnsRetry`, `AcceptPolicy`, `StopTimerBook`, `HookAck`, plus helpers on `ClaudeSettingsFile`. These types are tested the way the repo already tests Swift — `swiftc` compiles the file with a `@main` test file, through a `scripts/test-*.sh` script and a step in `.github/workflows/build.yml` — and `HookServer.swift`/`LiveActivityRelay.swift` call them. The Python relay stays a Swift string literal (`nbHookPythonTemplate`) so both builds write it as before, and a new Python `unittest` runs the extracted template against a fake app socket.

**Tech Stack:** Swift 6 (strict concurrency), Foundation/Darwin, XcodeGen, Python 3 (`unittest`, `socket`, `subprocess`), GitHub Actions macOS runner.

**Spec:** `README.md` in this folder (findings C2, C6, C7, C16, C20, M5–M8, V11, V12; contract 7).

## Global Constraints

See `README.md` → Global Constraints. For this phase:
- **These tests only run on macOS.** Each task's commands run on a Mac or in the `build.yml` job. Each script is also added to `build.yml` so CI runs it.
- `NotchBuddy/project.yml` is unchanged. New Swift files go under `NotchBuddy/Sources/App/`, and the existing `Sources` group picks them up for both Mac targets.
- In `nbHookPythonTemplate` (a Swift `"""` literal), **every backslash of the Python source is written twice** (`'\\n'` in Swift is `'\n'` in the file), and the Python may not contain `"""` (it would end the Swift literal). Use `#` comments.
- Old relays keep working with the new app: an App Store `nb-hook.py` written by an older build never sends `coucou_ack`, and must never receive an ack line.
- No visual change to any view.

## Review Focus

See `README.md`. Tests this phase owns:
- `test_an_immediate_answer_without_ack_still_counts` (Task 5.5)
- `HookAckTests`: no `coucou_ack` → `wanted == false` (Task 5.5)

---

### Task 5.1: A token Apple refuses on both push servers is tried once on the other, then left alone (C2)

`LiveActivityRelay.swift:330-340` flips `env` on `BadDeviceToken` and calls itself, guarded by `phones[phoneID]?.env == env`. That guard holds again after every flip, so a token that is bad on both servers ping-pongs forever: one APNs request per round trip, all billed to the relay's quota.

**Files:**
- Create: `NotchBuddy/Sources/App/PhoneLink/ApnsRetry.swift`
- Create: `tests/ApnsRetryTests.swift`
- Create: `scripts/test-apns-retry.sh`
- Modify: `NotchBuddy/Sources/App/PhoneLink/LiveActivityRelay.swift:310-351` (`post`)
- Modify: `.github/workflows/build.yml` (one step)

**Interfaces:**
- Produces: `enum ApnsRetry { static func otherEnvironment(after env: String, alreadyRetried: Bool) -> String? }`. `post(…, phoneID:, retried: Bool = false)`.

- [ ] **Step 1: Write the failing test and its script**

Create `tests/ApnsRetryTests.swift`:

```swift
@main
enum ApnsRetryTests {
    static func main() {
        precondition(ApnsRetry.otherEnvironment(after: "production", alreadyRetried: false) == "development")
        precondition(ApnsRetry.otherEnvironment(after: "development", alreadyRetried: false) == "production")
        // A second refusal means the token is no good anywhere: nothing more is sent.
        precondition(ApnsRetry.otherEnvironment(after: "production", alreadyRetried: true) == nil)
        precondition(ApnsRetry.otherEnvironment(after: "development", alreadyRetried: true) == nil)
        print("ApnsRetry tests passed")
    }
}
```

Create `scripts/test-apns-retry.sh` (and `chmod +x` it):

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-apns-retry.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/PhoneLink/ApnsRetry.swift \
    tests/ApnsRetryTests.swift -o "$TEST_DIR/apns-retry-tests"
"$TEST_DIR/apns-retry-tests"
```

- [ ] **Step 2: Run it to verify it fails**

Run (on macOS): `bash scripts/test-apns-retry.sh`
Expected: FAIL, `error: no such file … ApnsRetry.swift`.

- [ ] **Step 3: Write minimal implementation**

Create `NotchBuddy/Sources/App/PhoneLink/ApnsRetry.swift`:

```swift
// After Apple refused a Live Activity token as BadDeviceToken: the other push
// server to try, once. A token only works on one of the two (sandbox for builds
// run from Xcode, production for TestFlight and the App Store); refused by both,
// it is no good anywhere and nothing more is sent for it.
enum ApnsRetry {
    static func otherEnvironment(after env: String, alreadyRetried: Bool) -> String? {
        guard !alreadyRetried else { return nil }
        return env == "production" ? "development" : "production"
    }
}
```

In `LiveActivityRelay.swift`:
- Add a parameter to `post`: `urgent: Bool = false, dismissAfter: Int? = nil, phoneID: String, retried: Bool = false) async -> Bool {`.
- Replace the whole `if reason.contains("BadDeviceToken") { … }` block with:

```swift
            if reason.contains("BadDeviceToken"),
               let other = ApnsRetry.otherEnvironment(after: env, alreadyRetried: retried) {
                // Try the other push server once, and keep it only if it works.
                log("relay \(event): token not valid on \(env), trying \(other)")
                let ok = await post(event: event, token: token, env: other, state: state,
                                    urgent: urgent, dismissAfter: dismissAfter, phoneID: phoneID, retried: true)
                if ok { phones[phoneID]?.env = other }
                return ok
            }
```

In `.github/workflows/build.yml`, after the `Pill colour tests` step, add:

```yaml
      - name: APNs retry tests
        run: bash scripts/test-apns-retry.sh
```

- [ ] **Step 4: Run the test and the build**

Run (on macOS): `bash scripts/test-apns-retry.sh && cd NotchBuddy && xcodegen && xcodebuild -scheme NotchBuddy -configuration DebugCloud build CODE_SIGNING_ALLOWED=NO`
Expected: `ApnsRetry tests passed`, and the build succeeds. (`DebugCloud` compiles `PHONE_LINK`, which `LiveActivityRelay` needs.)

- [ ] **Step 5: Commit**

```bash
git add NotchBuddy/Sources/App/PhoneLink/ApnsRetry.swift tests/ApnsRetryTests.swift scripts/test-apns-retry.sh NotchBuddy/Sources/App/PhoneLink/LiveActivityRelay.swift .github/workflows/build.yml
git commit -m "Mac: try the other APNs server once, never in a loop"
```

---

### Task 5.2: The hook server survives `accept` errors and says why it stopped (C6)

`HookServer.swift:247-248` reads `guard clientFD >= 0 else { break }`. One EINTR, or EMFILE (GUI apps default to a 256-descriptor soft limit), ends the server thread for good: every later hook gets nothing, and the log is silent. `:228`, `:241` and `:244` also return silently when socket, bind or listen fails.

**Files:**
- Create: `NotchBuddy/Sources/App/AcceptPolicy.swift`
- Create: `tests/AcceptPolicyTests.swift`
- Create: `scripts/test-accept-policy.sh`
- Modify: `NotchBuddy/Sources/App/HookServer.swift:217-267` (`serverThread`)
- Modify: `.github/workflows/build.yml`

**Interfaces:**
- Produces: `enum AcceptPolicy { enum Next { case retry, retryAfterPause, stop }; static func next(afterErrno: Int32) -> Next }`.

- [ ] **Step 1: Write the failing test and its script**

Create `tests/AcceptPolicyTests.swift`:

```swift
import Darwin

@main
enum AcceptPolicyTests {
    static func main() {
        // A signal or a client that hung up first: just accept again.
        precondition(AcceptPolicy.next(afterErrno: EINTR) == .retry)
        precondition(AcceptPolicy.next(afterErrno: ECONNABORTED) == .retry)
        precondition(AcceptPolicy.next(afterErrno: EAGAIN) == .retry)
        // Out of descriptors or memory: give the machine a moment, then go on.
        precondition(AcceptPolicy.next(afterErrno: EMFILE) == .retryAfterPause)
        precondition(AcceptPolicy.next(afterErrno: ENFILE) == .retryAfterPause)
        precondition(AcceptPolicy.next(afterErrno: ENOBUFS) == .retryAfterPause)
        // The listening socket itself is gone: nothing left to serve.
        precondition(AcceptPolicy.next(afterErrno: EBADF) == .stop)
        precondition(AcceptPolicy.next(afterErrno: EINVAL) == .stop)
        print("AcceptPolicy tests passed")
    }
}
```

Create `scripts/test-accept-policy.sh` (executable):

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-accept-policy.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/AcceptPolicy.swift \
    tests/AcceptPolicyTests.swift -o "$TEST_DIR/accept-policy-tests"
"$TEST_DIR/accept-policy-tests"
```

- [ ] **Step 2: Run it to verify it fails**

Run (on macOS): `bash scripts/test-accept-policy.sh`
Expected: FAIL, missing `AcceptPolicy.swift`.

- [ ] **Step 3: Write minimal implementation**

Create `NotchBuddy/Sources/App/AcceptPolicy.swift`:

```swift
import Darwin

// What the hook server does after accept() failed. Leaving its loop means no
// hook event reaches Coucou again until it restarts, so it only does that when
// the listening socket itself is unusable.
enum AcceptPolicy {
    enum Next: Equatable {
        case retry
        case retryAfterPause
        case stop
    }

    static func next(afterErrno e: Int32) -> Next {
        switch e {
        case EINTR, ECONNABORTED, EAGAIN:
            return .retry
        case EMFILE, ENFILE, ENOBUFS, ENOMEM:
            return .retryAfterPause
        default:
            return .stop   // EBADF, EINVAL, ENOTSOCK…: the server socket is gone
        }
    }
}
```

In `HookServer.swift` `serverThread`:
- `guard fd >= 0 else { return }` →

```swift
        guard fd >= 0 else {
            nbLog("hook server: socket() failed: \(String(cString: strerror(errno)))")
            return
        }
```

- `guard bindRC == 0 else { close(fd); return }` →

```swift
        guard bindRC == 0 else {
            nbLog("hook server: bind \(path) failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }
```

- `guard Darwin.listen(fd, 32) == 0 else { close(fd); return }` →

```swift
        guard Darwin.listen(fd, 32) == 0 else {
            nbLog("hook server: listen failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }
```

- In the `while true` loop, replace `let clientFD = Darwin.accept(fd, nil, nil)` and `guard clientFD >= 0 else { break }` with:

```swift
            let clientFD = Darwin.accept(fd, nil, nil)
            if clientFD < 0 {
                let err = errno
                switch AcceptPolicy.next(afterErrno: err) {
                case .retry:
                    continue
                case .retryAfterPause:
                    nbLog("hook server: accept: \(String(cString: strerror(err))) — retrying")
                    usleep(200_000)
                    continue
                case .stop:
                    nbLog("hook server: accept: \(String(cString: strerror(err))) — stopped")
                    return
                }
            }
```

In `build.yml`, add after the APNs step:

```yaml
      - name: Hook server accept tests
        run: bash scripts/test-accept-policy.sh
```

- [ ] **Step 4: Run the test and the build**

Run (on macOS): `bash scripts/test-accept-policy.sh && cd NotchBuddy && xcodegen && xcodebuild -scheme NotchBuddy -configuration Debug build CODE_SIGNING_ALLOWED=NO`
Expected: `AcceptPolicy tests passed`; the build succeeds.

- [ ] **Step 5: Commit**

```bash
git add NotchBuddy/Sources/App/AcceptPolicy.swift tests/AcceptPolicyTests.swift scripts/test-accept-policy.sh NotchBuddy/Sources/App/HookServer.swift .github/workflows/build.yml
git commit -m "Mac: the hook server survives accept errors and logs why it stops"
```

---

### Task 5.3: A new turn cancels the pending return to idle (C7)

The Stop handler at `HookServer.swift:537-544` arms `DispatchQueue.main.asyncAfter(5.2)`, which nothing cancels. A prompt sent within 5.2 s of Stop is flipped to idle, and an external agent's pill is removed mid-turn. The Windows port already cancels this timer (`stopTimers`/`supersedeStop`, `hooks.ts:331,438`).

**Files:**
- Create: `NotchBuddy/Sources/App/StopTimerBook.swift`
- Create: `tests/StopTimerBookTests.swift`
- Create: `scripts/test-stop-timers.sh`
- Modify: `NotchBuddy/Sources/App/HookServer.swift` (property, `supersedeStop`, the Stop case, and the cancel calls listed below)
- Modify: `.github/workflows/build.yml`

**Interfaces:**
- Produces: `@MainActor final class StopTimerBook { nonisolated init(); func arm(_ pill: String, after seconds: Double, _ work: @escaping @MainActor () -> Void); @discardableResult func cancel(_ pill: String) -> Bool; func isArmed(_ pill: String) -> Bool }`.

- [ ] **Step 1: Write the failing test and its script**

Create `tests/StopTimerBookTests.swift`:

```swift
@MainActor
final class Fired {
    var names: [String] = []
}

@main
enum StopTimerBookTests {
    @MainActor
    static func main() async {
        let book = StopTimerBook()
        let fired = Fired()

        book.arm("a", after: 0.05) { fired.names.append("a") }
        book.arm("b", after: 0.05) { fired.names.append("b") }
        precondition(book.cancel("a"), "an armed timer can be cancelled")
        try? await Task.sleep(for: .milliseconds(300))
        precondition(fired.names == ["b"], "\(fired.names)")
        precondition(!book.isArmed("b"))
        precondition(!book.cancel("b"), "a timer that fired is no longer armed")

        // Arming again replaces the earlier timer of that pill.
        book.arm("c", after: 0.05) { fired.names.append("c1") }
        book.arm("c", after: 0.05) { fired.names.append("c2") }
        try? await Task.sleep(for: .milliseconds(300))
        precondition(fired.names == ["b", "c2"], "\(fired.names)")
        print("StopTimerBook tests passed")
    }
}
```

Create `scripts/test-stop-timers.sh` (executable):

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-stop-timers.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 NotchBuddy/Sources/App/StopTimerBook.swift \
    tests/StopTimerBookTests.swift -o "$TEST_DIR/stop-timer-tests"
"$TEST_DIR/stop-timer-tests"
```

- [ ] **Step 2: Run it to verify it fails**

Run (on macOS): `bash scripts/test-stop-timers.sh`
Expected: FAIL, missing `StopTimerBook.swift`.

- [ ] **Step 3: Write minimal implementation**

Create `NotchBuddy/Sources/App/StopTimerBook.swift`:

```swift
// The return to idle each pill's Stop arms, kept so the next turn can cancel
// it. Without that, a prompt sent within 5.2 s of Stop was flipped back to
// idle (or an agent's pill removed) in the middle of its new turn.
@MainActor
final class StopTimerBook {
    private var timers: [String: Task<Void, Never>] = [:]

    nonisolated init() {}

    func arm(_ pill: String, after seconds: Double, _ work: @escaping @MainActor () -> Void) {
        timers[pill]?.cancel()
        timers[pill] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.timers[pill] = nil
            work()
        }
    }

    @discardableResult
    func cancel(_ pill: String) -> Bool {
        guard let timer = timers.removeValue(forKey: pill) else { return false }
        timer.cancel()
        return true
    }

    func isArmed(_ pill: String) -> Bool {
        timers[pill] != nil
    }
}
```

In `HookServer.swift`:

1. Below `private var focusBeforeApproval: String? = nil`, add:

```swift
    /// The return to idle each pill's Stop armed (StopTimerBook).
    private let stopTimers = StopTimerBook()
```

2. In the `// MARK: - Badge helpers` section, add:

```swift
    /// A newer state replaces `finished`: the pending return to idle must not
    /// land on it, and the badge it was going to clear goes now.
    @MainActor
    private func supersedeStop(_ pillId: String) {
        if stopTimers.cancel(pillId) { clearPillBadge(id: pillId) }
    }
```

3. In `processEvent`'s `case "Stop":`, replace the `DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) { … }` block with:

```swift
            stopTimers.arm(agentId, after: 5.2) { [weak self] in
                if isExternalAgent {
                    AppState.shared.removeTask(id: agentId)
                } else {
                    AppState.shared.updateTask(id: agentId, state: .idle)
                    self?.clearPillBadge(id: agentId)
                }
            }
```

4. Add `supersedeStop(agentId)` as the first line of these cases in `processEvent`: `case "UserPromptSubmit":`, `case "PreToolUse":`, `case "PostToolUse":`, `case "PostToolUseFailure":`, `case "StopFailure":`, `case "Interrupt":`, `case "SessionEnd":`. In `case "Notification":`, add it inside both branches that change the state (the rate-limit branch and the `hasSuffix("?")` branch), before `state.updateTask`.

5. In `processPermissionRequest`, after `let pillId: String` is assigned (right before `// Terminal sessions: only when turned on in Settings`), add `supersedeStop(pillId)`. Do the same in `processQuestionRequest` after its `pillId` is assigned.

In `build.yml`, add:

```yaml
      - name: Stop timer tests
        run: bash scripts/test-stop-timers.sh
```

- [ ] **Step 4: Run the test and the build**

Run (on macOS): `bash scripts/test-stop-timers.sh && cd NotchBuddy && xcodegen && xcodebuild -scheme NotchBuddy -configuration Debug build CODE_SIGNING_ALLOWED=NO`
Expected: `StopTimerBook tests passed`; the build succeeds with no new Swift 6 concurrency errors.

- [ ] **Step 5: Manual check**

Run a Claude Code turn in VS Code. As soon as it stops, send another prompt within about 2 s: the pill goes to thinking/working and stays there. Before this fix, it dropped to idle about 5 s after the first Stop.

- [ ] **Step 6: Commit**

```bash
git add NotchBuddy/Sources/App/StopTimerBook.swift tests/StopTimerBookTests.swift scripts/test-stop-timers.sh NotchBuddy/Sources/App/HookServer.swift .github/workflows/build.yml
git commit -m "Mac: a new turn cancels the previous Stop's return to idle"
```

---

### Task 5.4: One Python relay template for both builds, with a test harness (M5)

`nbHookPythonGitHub` (`HookServer.swift:3095`) and `nbHookPythonAppStore` (`:3402`) are two ~300-line copies that differ only in the socket path and two comments, and nothing tests either one.

**Files:**
- Modify: `NotchBuddy/Sources/App/HookServer.swift` (rename the GitHub literal to `nbHookPythonTemplate`, use a placeholder socket, delete the App Store literal, add `nbHookPython(socket:)`, update the two writers at `:1202` and `:1488`)
- Create: `tests/test_nb_hook.py`
- Create: `scripts/test-nb-hook.sh`
- Modify: `.github/workflows/build.yml`

**Interfaces:**
- Produces: `private func nbHookPython(socket: String) -> String`. In tests: `relay_source(socket_path)`, `class FakeApp`, and `class Relay(unittest.TestCase)`, which Tasks 5.5 and 5.6 extend.

- [ ] **Step 1: Write the harness and the baseline tests**

Create `tests/test_nb_hook.py`:

```python
#!/usr/bin/env python3
# Runs the Mac's nb-hook.py (the template in HookServer.swift) against a fake
# Coucou on a Unix socket: what the agent reads on stdout, and how long it waits.
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SWIFT = os.path.join(ROOT, 'NotchBuddy', 'Sources', 'App', 'HookServer.swift')


def relay_source(socket_path):
    text = open(SWIFT, encoding='utf-8').read()
    m = re.search(r'private let nbHookPythonTemplate = """\n(.*?)\n"""', text, re.S)
    assert m, 'nbHookPythonTemplate not found in HookServer.swift'
    # A Swift multi-line literal writes each backslash twice.
    return m.group(1).replace('\\\\', '\\').replace('__COUCOU_SOCKET__', socket_path)


class FakeApp:
    # One connection: reads the event line, then calls respond(conn, event).
    # The connection stays open until close(), like an app that holds a card.
    def __init__(self, path, respond):
        self.respond = respond
        self.event = None
        self.conn = None
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(path)
        self.server.listen(4)
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        self.conn, _ = self.server.accept()
        data = b''
        while b'\n' not in data:
            chunk = self.conn.recv(1 << 20)
            if not chunk:
                break
            data += chunk
        self.event = json.loads(data.split(b'\n', 1)[0])
        try:
            self.respond(self.conn, self.event)
        except OSError:
            pass

    def close(self):
        if self.conn:
            self.conn.close()
        self.server.close()


class Relay(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.sock = os.path.join(self.tmp, 'nb.sock')
        self.script = os.path.join(self.tmp, 'nb-hook.py')
        with open(self.script, 'w', encoding='utf-8') as f:
            f.write(relay_source(self.sock))
        self.app = None

    def tearDown(self):
        if self.app:
            self.app.close()

    def serve(self, respond):
        self.app = FakeApp(self.sock, respond)
        return self.app

    def run_relay(self, payload, *args):
        started = time.monotonic()
        proc = subprocess.run([sys.executable, self.script, *args],
                              input=json.dumps(payload).encode(), capture_output=True, timeout=30)
        return proc.stdout.decode().strip(), time.monotonic() - started

    def received(self):
        self.app.thread.join(5)
        return self.app.event

    def test_no_app_never_holds_the_agent(self):
        out, took = self.run_relay({'hook_event_name': 'PermissionRequest', 'tool_name': 'Bash',
                                    'tool_input': {'command': 'ls'}})
        self.assertEqual(out, '')
        self.assertLess(took, 2.0)

    def test_events_reach_the_app(self):
        self.serve(lambda conn, event: None)
        out, _ = self.run_relay({'hook_event_name': 'PreToolUse', 'tool_name': 'Bash',
                                 'tool_input': {'command': 'ls'}})
        self.assertEqual(out, '')
        self.assertEqual(self.received()['tool_name'], 'Bash')

    def test_an_allow_from_the_app_is_the_documented_decision(self):
        self.serve(lambda conn, event: conn.sendall(b'{"permissionDecision":"allow"}\n'))
        out, _ = self.run_relay({'hook_event_name': 'PermissionRequest', 'tool_name': 'Bash',
                                 'tool_input': {'command': 'ls'}})
        self.assertEqual(json.loads(out)['hookSpecificOutput']['decision']['behavior'], 'allow')


if __name__ == '__main__':
    unittest.main(verbosity=2)
```

Create `scripts/test-nb-hook.sh` (executable):

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 tests/test_nb_hook.py
```

- [ ] **Step 2: Run it to verify it fails**

Run (on macOS): `bash scripts/test-nb-hook.sh`
Expected: FAIL, `nbHookPythonTemplate not found in HookServer.swift`.

- [ ] **Step 3: Make one template**

In `HookServer.swift`:
1. Rename `private let nbHookPythonGitHub = """` to `private let nbHookPythonTemplate = """`.
2. In that literal, change the two header comment lines to:

```
# nb-hook.py — Coucou hook relay for Claude Code and third-party agents
# Reads JSON from stdin, forwards to Coucou via its Unix socket, translates the response.
```

3. In that literal, replace `'~/Library/Application Support/NotchBuddy/nb.sock'` with `'__COUCOU_SOCKET__'`.
4. Delete the whole `// MARK: - nb-hook Python relay (App Store — socket in sandboxed container)` section: `private let nbHookPythonAppStore = """ … """`.
5. Below the template's closing `"""`, add:

```swift
/// The Python relay for the socket at `socket` (the script expands a leading `~`).
private func nbHookPython(socket: String) -> String {
    nbHookPythonTemplate.replacingOccurrences(of: "__COUCOU_SOCKET__", with: socket)
}
```

6. In `installHookScript()`, change `try? nbHookPythonGitHub.write(to: pyURL, …)` to:

```swift
        try? nbHookPython(socket: "~/Library/Application Support/NotchBuddy/nb.sock")
            .write(to: pyURL, atomically: true, encoding: .utf8)
```

7. In `installAndWriteClaudeHooksAppStore`, change `try nbHookPythonAppStore.write(to: pyURL, …)` to:

```swift
        try nbHookPython(socket: "~/Library/Containers/fr.louisraille.Coucou/Data/nb.sock")
            .write(to: pyURL, atomically: true, encoding: .utf8)
```

In `build.yml`, add:

```yaml
      - name: nb-hook relay tests
        run: bash scripts/test-nb-hook.sh
```

- [ ] **Step 4: Run tests and both builds**

Run (on macOS): `bash scripts/test-nb-hook.sh && cd NotchBuddy && xcodegen && xcodebuild -scheme NotchBuddy -configuration Debug build CODE_SIGNING_ALLOWED=NO && xcodebuild -scheme CoucouAppStore -configuration Debug build CODE_SIGNING_ALLOWED=NO`
Expected: 3 Python tests pass; both builds succeed.

- [ ] **Step 5: Commit**

```bash
git add NotchBuddy/Sources/App/HookServer.swift tests/test_nb_hook.py scripts/test-nb-hook.sh .github/workflows/build.yml
git commit -m "Mac: one nb-hook.py template for both builds, with a relay test harness"
```

---

### Task 5.5: The relay gives up in 1.5 s when the app cannot put the card up (C16, contract 7)

The Mac relay waits up to 118 s on a held PermissionRequest (`s.settimeout(118)` at `HookServer.swift:3308`, and 125 s in `--ask` mode). `processPermissionRequest` runs on the main actor (`:326`), so a stalled main actor blocks Claude Code for nearly two minutes. Windows solved this with an 800 ms ack (`pipe.rs:45`).

**Files:**
- Create: `NotchBuddy/Sources/App/HookAck.swift`
- Create: `tests/HookAckTests.swift`
- Create: `scripts/test-hook-ack.sh`
- Modify: `NotchBuddy/Sources/App/HookServer.swift` (`processPermissionRequest`, `processQuestionRequest`; template: new `wait_reply`, and the PermissionRequest and `--ask` branches)
- Modify: `tests/test_nb_hook.py`
- Modify: `.github/workflows/build.yml`

**Interfaces:**
- Produces: `enum HookAck { static let line: String; static func wanted(_ payload: [String: Any]) -> Bool }`. Python `wait_reply(s, long_timeout) -> str`, and `ACK_BUDGET = 1.5`.

- [ ] **Step 1: Write the failing tests**

Create `tests/HookAckTests.swift`:

```swift
import Foundation

@main
enum HookAckTests {
    static func main() throws {
        func payload(_ json: String) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        }
        precondition(HookAck.wanted(try payload(#"{"hook_event_name":"PermissionRequest","coucou_ack":1}"#)))
        // A relay written before the ack existed never asks, and gets no line it would take for an answer.
        precondition(!HookAck.wanted(try payload(#"{"hook_event_name":"PermissionRequest"}"#)))
        precondition(!HookAck.wanted(try payload(#"{"coucou_ack":"1"}"#)))
        precondition(!HookAck.wanted(try payload(#"{"coucou_ack":0}"#)))
        precondition(HookAck.line == #"{"ack":true}"#)
        print("HookAck tests passed")
    }
}
```

Create `scripts/test-hook-ack.sh` (executable):

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-hook-ack.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/HookAck.swift \
    tests/HookAckTests.swift -o "$TEST_DIR/hook-ack-tests"
"$TEST_DIR/hook-ack-tests"
```

Add to `class Relay` in `tests/test_nb_hook.py`:

```python
    PERMISSION = {'hook_event_name': 'PermissionRequest', 'tool_name': 'Bash', 'tool_input': {'command': 'ls'}}

    def test_the_relay_asks_for_an_ack(self):
        self.serve(lambda conn, event: conn.sendall(b'{"permissionDecision":"ask"}\n'))
        self.run_relay(self.PERMISSION)
        self.assertEqual(self.received().get('coucou_ack'), 1)

    def test_an_app_that_never_shows_the_card_costs_the_agent_under_two_seconds(self):
        self.serve(lambda conn, event: None)  # reads the event, never answers, keeps the connection
        out, took = self.run_relay(self.PERMISSION)
        self.assertEqual(out, '')
        self.assertLess(took, 2.5)

    def test_after_the_ack_the_relay_waits_for_the_click(self):
        def respond(conn, event):
            conn.sendall(b'{"ack":true}\n')
            time.sleep(2.0)  # longer than the ack budget: a human deciding
            conn.sendall(b'{"permissionDecision":"deny"}\n')
        self.serve(respond)
        out, took = self.run_relay(self.PERMISSION)
        self.assertEqual(json.loads(out)['hookSpecificOutput']['decision']['behavior'], 'deny')
        self.assertGreater(took, 1.9)

    def test_an_immediate_answer_without_ack_still_counts(self):
        self.serve(lambda conn, event: conn.sendall(b'{"permissionDecision":"allow"}\n'))
        out, _ = self.run_relay(self.PERMISSION)
        self.assertEqual(json.loads(out)['hookSpecificOutput']['decision']['behavior'], 'allow')

    def test_a_question_waits_for_its_answer_after_the_ack(self):
        question = {'hook_event_name': 'PreToolUse', 'tool_name': 'AskUserQuestion',
                    'tool_input': {'questions': [{'question': 'Which?', 'options': [{'label': 'A'}, {'label': 'B'}]}]}}
        def respond(conn, event):
            conn.sendall(b'{"ack":true}\n')
            time.sleep(2.0)
            conn.sendall(b'{"permissionDecision":"answer","answers":{"Which?":"B"}}\n')
        self.serve(respond)
        out, _ = self.run_relay(question, '--ask')
        self.assertEqual(json.loads(out)['hookSpecificOutput']['updatedInput']['answers'], {'Which?': 'B'})
```

- [ ] **Step 2: Run them to verify they fail**

Run (on macOS): `bash scripts/test-hook-ack.sh; bash scripts/test-nb-hook.sh`
Expected: FAIL. `HookAck.swift` is missing; `coucou_ack` is absent; the never-answering app holds the relay for the full 118 s (the subprocess times out at 30 s).

- [ ] **Step 3: Write minimal implementation**

Create `NotchBuddy/Sources/App/HookAck.swift`:

```swift
import Foundation

// The relay asks the app to confirm that a held request is on screen: its
// payload carries "coucou_ack": 1, and without the line {"ack":true} within
// 1.5 s it lets the agent ask in its own terminal. A relay written before this
// existed (an App Store nb-hook.py from an older build) never asks, and gets
// no ack line it would mistake for an answer.
enum HookAck {
    static let line = #"{"ack":true}"#

    static func wanted(_ payload: [String: Any]) -> Bool {
        (payload["coucou_ack"] as? NSNumber)?.intValue == 1
    }
}
```

In `HookServer.swift`:

1. In `processPermissionRequest`, right after `approvalFDSource = source`, add:

```swift
        // The card is up: the relay may now wait for a human (HookAck).
        if HookAck.wanted(payload) {
            let ackFD = fd
            Task.detached { [weak self] in self?.sendLine(fd: ackFD, text: HookAck.line) }
        }
```

2. In `processQuestionRequest`, right after `questionFDSource = source`, add the same block.

3. In `nbHookPythonTemplate`, add after `def normalize_tool_fields(payload): …`. This is written as it appears in the Swift file, with backslashes doubled:

```python
ACK_BUDGET = 1.5

def wait_reply(s, long_timeout):
    # The app's answer line. We asked for an ack (coucou_ack): the first line
    # must be {"ack":true} within ACK_BUDGET, so an app that cannot show the
    # card (busy, hung) costs the agent 1.5 s, not two minutes. An answer sent
    # at once (an "ask" for an agent the app does not serve) is the reply.
    s.settimeout(ACK_BUDGET)
    acked = False
    buf = b''
    while True:
        while b'\\n' in buf:
            line, buf = buf.split(b'\\n', 1)
            text = line.decode('utf-8', 'replace').strip()
            if not text:
                continue
            if not acked:
                try:
                    if json.loads(text).get('ack') is True:
                        acked = True
                        s.settimeout(long_timeout)
                        continue
                except Exception:
                    pass
            return text
        chunk = s.recv(4096)
        if not chunk:
            return ''
        buf += chunk
```

4. In the `--ask` branch, replace everything from `s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)` through `response = b''.join(chunks).decode().strip()` with:

```python
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(1.0)
            s.connect(socket_path)
            payload['coucou_ack'] = 1
            s.sendall((json.dumps(payload) + '\\n').encode())
            response = wait_reply(s, 125)
            s.close()
```

5. In the `if event == 'PermissionRequest':` branch, replace everything from `s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)` through `response = b''.join(chunks).decode().strip()` with:

```python
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(1.0)
            s.connect(socket_path)
            payload['coucou_ack'] = 1
            s.sendall((json.dumps(payload) + '\\n').encode())
            response = wait_reply(s, 118)
            s.close()
```

The rest of both branches (`if response:` …) is unchanged. A `socket.timeout` raised by `wait_reply` is caught by the branch's existing `except Exception: pass`, which falls through to "no decision".

In `build.yml`, add:

```yaml
      - name: Hook ack tests
        run: bash scripts/test-hook-ack.sh
```

- [ ] **Step 4: Run tests and the build**

Run (on macOS): `bash scripts/test-hook-ack.sh && bash scripts/test-nb-hook.sh && cd NotchBuddy && xcodegen && xcodebuild -scheme NotchBuddy -configuration Debug build CODE_SIGNING_ALLOWED=NO`
Expected: `HookAck tests passed`; all Python tests pass; the build succeeds.

- [ ] **Step 5: Manual check**

With the GitHub build, Claude Code in VS Code, and the hooks installed:
1. Trigger a Bash permission and click Allow on the card: the tool runs.
2. Open Settings → Hooks → Install. While the diff sheet is up, trigger another permission: either the card appears, or Claude Code asks in the terminal within about 2 s. It never hangs.

- [ ] **Step 6: Commit**

```bash
git add NotchBuddy/Sources/App/HookAck.swift tests/HookAckTests.swift scripts/test-hook-ack.sh NotchBuddy/Sources/App/HookServer.swift tests/test_nb_hook.py .github/workflows/build.yml
git commit -m "Mac: the relay gives up in 1.5 s when the app cannot put the card up"
```

---

### Task 5.6: The relay caps what it forwards, as the Windows relay does (M6)

The Mac relay sends payloads whole. A Write or Edit over 1 MiB then fails to parse at the server, which reads at most 1 MiB (`HookServer.swift:289-297`), so the event is dropped silently. The Windows relay caps each string at 2000 bytes, except the edit text the live diff needs (`windows/hook/src/main.rs:47-60, 263-345`). The question text Claude Code asked must stay whole, because answers are keyed by it, and so must the turn's answer the iPhone shows.

**Files:**
- Modify: `NotchBuddy/Sources/App/HookServer.swift` (template: `cap_payload` and its helpers; three send sites)
- Modify: `tests/test_nb_hook.py`

**Interfaces:**
- Produces: Python `cap_payload(payload) -> dict`. It is applied only to what is **sent**; the relay builds its replies from the original payload.

- [ ] **Step 1: Write the failing tests**

Add to `class Relay` in `tests/test_nb_hook.py`:

```python
    def test_a_huge_tool_input_is_capped_on_its_way_to_the_app(self):
        self.serve(lambda conn, event: None)
        self.run_relay({'hook_event_name': 'PreToolUse', 'tool_name': 'Write',
                        'tool_input': {'file_path': '/p/a.txt', 'content': 'é' * 1_500_000}})
        content = self.received()['tool_input']['content']
        self.assertLessEqual(len(content.encode('utf-8')), 2000 + 3)
        self.assertTrue(content.endswith('…'))

    def test_a_finished_edit_keeps_its_text_for_the_live_diff(self):
        self.serve(lambda conn, event: None)
        big = 'line\n' * 4_000  # 20 KB
        self.run_relay({'hook_event_name': 'PostToolUse', 'tool_name': 'Edit',
                        'tool_input': {'file_path': '/p/a.ts', 'old_string': big, 'new_string': 'x'}})
        event = self.received()
        self.assertEqual(event['tool_input']['old_string'], big)
        self.assertNotIn('coucou_diff_truncated', event)

    def test_an_edit_past_the_diff_budget_is_cut_and_flagged(self):
        self.serve(lambda conn, event: None)
        self.run_relay({'hook_event_name': 'PostToolUse', 'tool_name': 'Write',
                        'tool_input': {'file_path': '/p/big.txt', 'content': 'x' * 300_000}})
        event = self.received()
        self.assertLessEqual(len(event['tool_input']['content'].encode('utf-8')), 256 * 1024 + 3)
        self.assertTrue(event['coucou_diff_truncated'])

    def test_the_question_and_the_final_answer_are_kept_whole(self):
        self.serve(lambda conn, event: None)
        self.run_relay({'hook_event_name': 'Stop', 'last_assistant_message': 'w' * 50_000})
        self.assertEqual(len(self.received()['last_assistant_message']), 50_000)

        self.app.close()
        os.unlink(self.sock)  # a closed Unix socket leaves its file behind
        long_q = 'q' * 3000
        def respond(conn, event):
            conn.sendall(b'{"ack":true}\n')
            conn.sendall(json.dumps({'permissionDecision': 'answer', 'answers': {long_q: 'A'}}).encode() + b'\n')
        self.serve(respond)
        question = {'hook_event_name': 'PreToolUse', 'tool_name': 'AskUserQuestion',
                    'tool_input': {'questions': [{'question': long_q, 'options': [{'label': 'A'}, {'label': 'B'}]}]}}
        out, _ = self.run_relay(question, '--ask')
        self.assertEqual(len(self.received()['tool_input']['questions'][0]['question']), 3000)
        self.assertEqual(json.loads(out)['hookSpecificOutput']['updatedInput']['questions'][0]['question'], long_q)
```

The last test serves twice. `self.app.close()` plus `os.unlink(self.sock)` free the socket path for the second `FakeApp`.

- [ ] **Step 2: Run them to verify they fail**

Run (on macOS): `bash scripts/test-nb-hook.sh`
Expected: FAIL. The 3 MB content arrives whole, or not at all if the event is over the fake app's 1 MiB recv size, and the diff is never flagged.

- [ ] **Step 3: Write minimal implementation**

In `nbHookPythonTemplate`, add after `wait_reply`. There are no backslashes in this block:

```python
# What is forwarded to the app is capped like the Windows relay's: each string
# to MAX_FIELD bytes, except the edit text of a finished Edit / MultiEdit /
# Write (the live diff needs it), the prompt and the turn's final answer. The
# app reads at most 1 MiB, and a cut payload used to be dropped whole. The
# question Claude Code asked is never cut: answers are keyed by its text.
MAX_FIELD = 2000
LONG_FIELDS = {'prompt': 65536, 'last_assistant_message': 65536}
DIFF_TOOLS = ('Edit', 'MultiEdit', 'Write')
DIFF_FIELDS = ('old_string', 'new_string', 'content')
MAX_DIFF_FIELD = 256 * 1024
MAX_DIFF_TOTAL = 512 * 1024

def cut(s, limit):
    b = s.encode('utf-8')
    if len(b) <= limit:
        return s, False
    return b[:limit].decode('utf-8', 'ignore') + '…', True

def cap(value, key, diff):
    if isinstance(value, str):
        if diff is not None and key in DIFF_FIELDS:
            out, was_cut = cut(value, min(MAX_DIFF_FIELD, diff['budget']))
            diff['budget'] = max(0, diff['budget'] - len(out.encode('utf-8')))
            diff['cut'] = diff['cut'] or was_cut
            return out
        return cut(value, LONG_FIELDS.get(key, MAX_FIELD))[0]
    if isinstance(value, dict):
        return {k: cap(v, k, diff) for k, v in value.items()}
    if isinstance(value, list):
        return [cap(v, key, diff) for v in value]
    return value

def cap_payload(payload):
    keeps_diff = payload.get('hook_event_name') == 'PostToolUse' and payload.get('tool_name') in DIFF_TOOLS
    diff = {'budget': MAX_DIFF_TOTAL, 'cut': False} if keeps_diff else None
    out = {}
    for k, v in payload.items():
        if k == 'tool_input' and payload.get('tool_name') == 'AskUserQuestion':
            out[k] = v
        else:
            out[k] = cap(v, k, diff if k == 'tool_input' else None)
    if diff and diff['cut']:
        out['coucou_diff_truncated'] = True
    return out
```

Then change what is sent, in three places, from `json.dumps(payload)` to `json.dumps(cap_payload(payload))`:
- the `--ask` branch: `s.sendall((json.dumps(cap_payload(payload)) + '\\n').encode())`
- the `PermissionRequest` branch: same
- the fire-and-forget block at the end: `s.sendall((json.dumps(cap_payload(payload)) + '\\n').encode())`

Leave every other use of `payload` (reading `tool_input.questions` and `permission_suggestions` for the reply) untouched, so replies are built from the original payload.

- [ ] **Step 4: Run tests and the build**

Run (on macOS): `bash scripts/test-nb-hook.sh && cd NotchBuddy && xcodegen && xcodebuild -scheme NotchBuddy -configuration Debug build CODE_SIGNING_ALLOWED=NO`
Expected: all Python tests pass; the build succeeds.

- [ ] **Step 5: Commit**

```bash
git add NotchBuddy/Sources/App/HookServer.swift tests/test_nb_hook.py
git commit -m "Mac: the relay caps what it forwards, keeping diffs, questions and answers whole"
```

---

### Task 5.7: Coucou only ever touches its own hook entries in settings.json (C20, M8)

`HookServer.swift` matches `contains("NotchBuddy") || contains("coucou")` at lines 1228, 1244, 1303, 1330-1331, 1506-1507 and 1542-1543. That removes any user hook group whose command merely lives under a folder with that name, including the maintainers' own repo folder. It also removes the user's other hooks that share a group with Coucou's. Every Coucou version has run its relay as `…/nb-hook` (the hook script name since the first commit). Separately, `JSONSerialization` without `.withoutEscapingSlashes` rewrites every `/` as `\/` in the whole file.

**Files:**
- Modify: `NotchBuddy/Sources/App/ClaudeSettingsFile.swift` (two helpers)
- Modify: `tests/ClaudeSettingsFileTests.swift` (a new check, called from `main`)
- Modify: `NotchBuddy/Sources/App/HookServer.swift` (the lines above; JSON options at 1315, 1339, 1406, 1446, 1515, 1556)

**Interfaces:**
- Produces: `static func isCoucouHookCommand(_ command: String) -> Bool`, `static func removingCoucouHooks(from groups: [[String: Any]]) -> (groups: [[String: Any]], changed: Bool)`.

- [ ] **Step 1: Write the failing test**

In `tests/ClaudeSettingsFileTests.swift`, add this function to `enum ClaudeSettingsFileTests` and call `testCoucouHookMarker()` as the last line of `main()`:

```swift
    static func testCoucouHookMarker() {
        precondition(ClaudeSettingsFile.isCoucouHookCommand("\"/Users/me/Library/Application Support/NotchBuddy/nb-hook\""))
        precondition(ClaudeSettingsFile.isCoucouHookCommand("/bin/sh \"/Users/me/.claude/coucou/nb-hook\" --ask"))
        precondition(!ClaudeSettingsFile.isCoucouHookCommand("/Users/me/Desktop/coucou/scripts/lint.sh"))
        precondition(!ClaudeSettingsFile.isCoucouHookCommand("~/NotchBuddy-tools/notify.sh"))

        let groups: [[String: Any]] = [
            ["hooks": [["type": "command", "command": "/Users/me/Desktop/coucou/scripts/lint.sh"]]],
            ["matcher": "Bash", "hooks": [["type": "command", "command": "./mine.sh"],
                                          ["type": "command", "command": "\"/x/nb-hook\""]]],
            ["hooks": [["type": "command", "command": "\"/x/nb-hook\""]]],
        ]
        let (kept, changed) = ClaudeSettingsFile.removingCoucouHooks(from: groups)
        precondition(changed)
        precondition(kept.count == 2, "\(kept)")
        precondition(((kept[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String) == "/Users/me/Desktop/coucou/scripts/lint.sh")
        precondition(kept[1]["matcher"] as? String == "Bash")
        precondition((kept[1]["hooks"] as? [[String: Any]])?.count == 1, "the user's own hook in a shared group stays")
        let (same, touched) = ClaudeSettingsFile.removingCoucouHooks(from: [groups[0]])
        precondition(!touched && same.count == 1)
        print("Coucou hook marker tests passed")
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run (on macOS): `bash scripts/test-claude-settings.sh`
Expected: FAIL to compile, `type 'ClaudeSettingsFile' has no member 'isCoucouHookCommand'`.

- [ ] **Step 3: Write minimal implementation**

In `ClaudeSettingsFile.swift`, add inside `enum ClaudeSettingsFile`:

```swift
    /// A hook command Coucou wrote: every version has run its relay as `…/nb-hook`.
    /// Matching "coucou" or "NotchBuddy" also caught the user's own hooks that only
    /// live under a folder with that name.
    static func isCoucouHookCommand(_ command: String) -> Bool {
        command.contains("nb-hook")
    }

    /// `groups` with Coucou's hook entries taken out. A group left with no hook
    /// goes; the user's other hooks stay where they were, even in a group they
    /// share with ours. `changed` is false when nothing of ours was there.
    static func removingCoucouHooks(from groups: [[String: Any]]) -> (groups: [[String: Any]], changed: Bool) {
        var changed = false
        let kept: [[String: Any]] = groups.compactMap { group in
            guard let hooks = group["hooks"] as? [[String: Any]] else { return group }
            let mine = hooks.filter { !isCoucouHookCommand($0["command"] as? String ?? "") }
            if mine.count == hooks.count { return group }
            changed = true
            if mine.isEmpty { return nil }
            var g = group
            g["hooks"] = mine
            return g
        }
        return (kept, changed)
    }
```

In `HookServer.swift`:
1. Lines 1228 and 1244 (`hooksNeedUpdate`): replace `cmd.contains("NotchBuddy") || cmd.contains("coucou")` with `ClaudeSettingsFile.isCoucouHookCommand(cmd)`.
2. Line 1303 (`buildHooksData()`) and the matching `existing.removeAll { … }` at 1541-1544 (`buildHooksData(claudeURL:)`): replace each `existing.removeAll { … }` with:

```swift
            existing = ClaudeSettingsFile.removingCoucouHooks(from: existing).groups
```

3. In `uninstallClaudeHooks()` (1326-1337) and `uninstallClaudeHooksAppStore` (around 1503-1512), replace the per-key removal loop with:

```swift
        for key in hooks.keys {
            if let matchers = hooks[key] as? [[String: Any]] {
                let (kept, changed) = ClaudeSettingsFile.removingCoucouHooks(from: matchers)
                guard changed else { continue }
                if kept.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = kept }
            }
        }
```

4. At lines 1315, 1339, 1406, 1446, 1515 and 1556, change `options: [.prettyPrinted, .sortedKeys]` to `options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]`.

- [ ] **Step 4: Run tests and the builds**

Run (on macOS): `bash scripts/test-claude-settings.sh && cd NotchBuddy && xcodegen && xcodebuild -scheme NotchBuddy -configuration Debug build CODE_SIGNING_ALLOWED=NO && xcodebuild -scheme CoucouAppStore -configuration Debug build CODE_SIGNING_ALLOWED=NO`
Expected: `Coucou hook marker tests passed` (plus the existing checks); both builds succeed.

- [ ] **Step 5: Manual check**

1. Add a user hook `{"hooks":[{"type":"command","command":"$HOME/coucou-test/echo.sh"}]}` under `PreToolUse` in `~/.claude/settings.json`.
2. In Settings, install and then uninstall Coucou's hooks: the user hook survives both, and the preview diff shows `/` unescaped.

- [ ] **Step 6: Commit**

```bash
git add NotchBuddy/Sources/App/ClaudeSettingsFile.swift tests/ClaudeSettingsFileTests.swift NotchBuddy/Sources/App/HookServer.swift
git commit -m "Mac: only touch Coucou's own hook entries; keep slashes unescaped in settings.json"
```

---

### Task 5.8: A run started from the iPhone has a time limit (V11)

`InstructionRunner.run` (`InstructionRunner.swift:142-186`) starts `claude -p … --resume <id>` with no watchdog. A hung run keeps `running[sessionId]` set, so every later instruction for that session is refused until Coucou restarts.

**Files:**
- Modify: `NotchBuddy/Sources/App/PhoneLink/InstructionRunner.swift`

- [ ] **Step 1: Write the change**

There is nothing a script test can drive: `Process` plus CloudKit. In `InstructionRunner`, add below `private let maxAge`:

```swift
    /// A run longer than this is stopped: until it ends, the session takes no
    /// other instruction from the iPhone.
    private let maxRun: TimeInterval = 20 * 60
```

In `run(…)`, replace the `do { try process.run() … } catch { … }` block with:

```swift
        do {
            try process.run()
            running[sessionId] = process
            log("running in \(URL(fileURLWithPath: cwd).lastPathComponent) (\(sessionId.prefix(8))): \(text.count) chars")
            let limit = maxRun
            let started = ObjectIdentifier(process)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(limit))
                // Only this run: a later one for the same session has its own limit.
                guard let self, let current = self.running[sessionId],
                      ObjectIdentifier(current) == started, current.isRunning else { return }
                self.log("stopped after \(Int(limit / 60)) min (\(sessionId.prefix(8)))")
                current.terminate()
            }
        } catch {
            log("couldn't start claude: \(error.localizedDescription)")
        }
```

`terminate()` triggers the existing `terminationHandler`, which clears `running[sessionId]`.

- [ ] **Step 2: Build**

Run (on macOS): `cd NotchBuddy && xcodegen && xcodebuild -scheme NotchBuddy -configuration DebugCloud build CODE_SIGNING_ALLOWED=NO`
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add NotchBuddy/Sources/App/PhoneLink/InstructionRunner.swift
git commit -m "Mac: stop an iPhone-started run after 20 minutes"
```

---

## Phase 5 done when

- [ ] On macOS, every `scripts/test-*.sh` passes, including the 5 new ones.
- [ ] `build.yml` runs the 5 new scripts and is green on the branch.
- [ ] `xcodebuild` succeeds for `NotchBuddy` (Debug, Release, DebugCloud, ReleaseCloud) and `CoucouAppStore`.
- [ ] The manual checks in Tasks 5.3, 5.5 and 5.7 were done on a Mac with Claude Code.
