#!/usr/bin/env bash
# wire() in both nb-hook.py relays (GitHub and App Store builds, in HookServer.swift).
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -I - NotchBuddy/Sources/App/HookServer.swift <<'EOF'
import json, re, sys

source = open(sys.argv[1]).read()
copies = re.findall(r"^MAX_LINE = \d+\n\ndef wire\(.*?(?=^def )", source, flags=re.S | re.M)
assert len(copies) == 2, f"expected the wire() of both relays, found {len(copies)}"

for n, code in enumerate(copies, 1):
    scope = {"json": json}
    # The script lives in a Swift string: "\\n" there is "\n" in Python.
    exec(code.replace("\\\\n", "\\n"), scope)
    wire, limit = scope["wire"], scope["MAX_LINE"]

    small = {"hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": {"command": "ls"}}
    assert json.loads(wire(small, waits=True))["tool_input"]["command"] == "ls", "a normal request goes whole"

    huge = {"hook_event_name": "PermissionRequest", "tool_name": "Bash",
            "tool_input": {"command": "echo ok; " + "x" * limit}}
    try:
        wire(huge, waits=True)
        raise AssertionError("an oversized request awaiting a decision must not reach the card")
    except ValueError:
        pass

    event = dict(huge, hook_event_name="PostToolUse")
    cut = json.loads(wire(event))
    assert len(cut["tool_input"]["command"]) == 2000, "other events still go, cut"
    print(f"  ✓ relay {n}")
print("Relay wire: all passed")
EOF
