"""Read-only smoke test: never sends a valid playback command."""
from collections import deque
import os
import json
import pathlib
import selectors
import subprocess
import time
import sys

root = pathlib.Path(__file__).resolve().parents[1]
child = subprocess.Popen(
    ['/usr/bin/perl', str(root / 'Resources/bridge.pl'), str(pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'build/NowPlayingBridge.dylib')],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
)
selector = selectors.DefaultSelector()
selector.register(child.stdout, selectors.EVENT_READ)

pending = deque()
buffer = bytearray()

def wait_for(event_type, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        while pending:
            event = pending.popleft()
            if event['type'] == 'error':
                raise AssertionError(event.get('message', 'Bridge error'))
            if event['type'] == event_type:
                return event
        if not selector.select(0.25):
            continue
        chunk = os.read(child.stdout.fileno(), 32768)
        if not chunk:
            raise AssertionError('Helper exited before expected response')
        buffer.extend(chunk)
        assert len(buffer) <= 6 * 1024 * 1024
        while b'\n' in buffer:
            line, _, tail = buffer.partition(b'\n')
            buffer[:] = tail
            pending.append(json.loads(line))
    raise AssertionError('No response before deadline')

try:
    snapshot = wait_for('snapshot')
    # Do not log titles, artists or artwork from the user's playback.
    print('Initial snapshot received; Compatible player active:', snapshot['active'])
    child.stdin.write(b'{"command":"pause","pid":1e300,"bundleIdentifier":"com.google.Chrome"}\n{"command":"pause","pid":1,"bundleIdentifier":"com.google.Chrome"}\n')
    child.stdin.flush()
    assert wait_for('command')['accepted'] is False
    child.stdin.close()
    child.wait(timeout=3)
    assert child.returncode == 0
    print('Passed: invalid PID rejected; no playback changed; EOF closes helper.')
finally:
    selector.close()
    if child.poll() is None:
        child.terminate()
        child.wait(timeout=3)
