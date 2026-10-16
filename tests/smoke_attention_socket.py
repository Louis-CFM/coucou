"""Exercise the compiled app's real socket -> controller -> AppState without showing UI."""
import json
import pathlib
import socket
import subprocess
import sys
import tempfile
import time

app = pathlib.Path(sys.argv[1])
production_socket = pathlib.Path.home() / "Library/Application Support/NotchBuddy/nb.sock"
production_inode = production_socket.stat().st_ino if production_socket.exists() else None
invalid = subprocess.run([str(app / "Contents/MacOS/Coucou"), "--attention-smoke-test", "/private/tmp/not-an-attention-test"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
assert invalid.returncode != 0, "An invalid test directory must exit instead of starting normal application services"
with tempfile.TemporaryDirectory(prefix="coucou-attention-smoke-", dir="/private/tmp") as directory:
    root = pathlib.Path(directory)
    process = subprocess.Popen([str(app / "Contents/MacOS/Coucou"), "--attention-smoke-test", directory],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        sock = root / "nb.sock"
        deadline = time.monotonic() + 4
        while not sock.exists() and time.monotonic() < deadline:
            time.sleep(.05)
        assert sock.exists(), "The isolated app did not start its socket"
        def send(packet):
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(1)
                client.connect(str(sock))
                client.sendall(json.dumps(packet).encode() + b"\n")
                return json.loads(client.recv(4096))
        before = time.monotonic()
        assert send({"coucou_agent": "codex", "hook_event_name": "PermissionRequest"}) == {"permissionDecision": "ask"}
        assert time.monotonic() - before < 1, "Permission hook must not block"
        request = {"source": "opencode", "id": "per_smoke", "session_id": "ses_smoke", "title": "Test main session",
                   "reason": "Waiting for a native permission", "kind": "permission"}
        packet = {"coucou_kind": "attention", "action": "snapshot", "expires_at": time.time() + 25, "requests": [request]}
        assert send(packet)["attention_protocol"] == 1
        time.sleep(.2)
        assert send(packet)["attention_protocol"] == 1  # refresh
        time.sleep(.2)
        packet["requests"] = []
        assert send(packet)["attention_protocol"] == 1
        process.wait(timeout=10)
        assert process.returncode == 0
        receipt = json.loads((root / "receipt.json").read_text())
        transitions = receipt["transitions"]
        assert transitions == [[], ["opencode:ses_smoke:per_smoke"], []], transitions
        if production_inode is not None:
            assert production_socket.stat().st_ino == production_inode, "Test altered the production socket"
        print(json.dumps({"socket_smoke": "passed", "native_permission": "returned ask immediately",
                          "reminder_visible_then_cleared": True, "production_socket_unchanged": True, "ui_shown": False}))
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
