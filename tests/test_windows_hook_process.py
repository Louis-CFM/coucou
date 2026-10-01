"""Exercise the real Windows relay process without opening the production pipe.

Every input is rejected before IPC. Valid same-user pipe I/O is covered by the
Rust relay fixture. No agent config, account or model request is involved.
"""
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
BINARY = ROOT / "windows/target/release/coucou-hook.exe"


@unittest.skipUnless(sys.platform == "win32", "Windows native process checks")
class WindowsHookProcessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not BINARY.is_file():
            raise RuntimeError("Build the release coucou-hook binary before this suite")

    def run_rejected(self, payload, args=("--provider", "codex", "PreToolUse")):
        result = subprocess.run([str(BINARY), *args], input=payload, capture_output=True, timeout=6)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))

    def test_invalid_json_is_silent_for_both_providers(self):
        for provider in ("claude", "codex"):
            for payload in (b"", b"invalid", b"null", b"[]"):
                self.run_rejected(payload, ("--provider", provider, "PreToolUse"))

    def test_unknown_provider_is_silent(self):
        self.run_rejected(b"{}", ("--provider", "unknown", "PreToolUse"))

    def test_oversized_input_is_silent(self):
        self.run_rejected(b" " * ((1 << 20) + 1))

    def test_long_permission_targets_return_to_the_normal_prompt(self):
        payload = b'{"hook_event_name":"PermissionRequest","tool_input":{"command":"' + b"x" * 2001 + b'"}}'
        self.run_rejected(payload, ("--provider", "codex", "PermissionRequest"))

    def test_quoted_windows_command_handles_spaces_unicode_and_ampersands(self):
        with tempfile.TemporaryDirectory(prefix="coucou path ü & ") as temporary:
            binary = pathlib.Path(temporary) / "coucou-hook.exe"
            shutil.copyfile(BINARY, binary)
            command = '"' + binary.as_posix() + '" --provider codex PreToolUse'
            result = subprocess.run(command, shell=True, input=b"invalid", capture_output=True, timeout=6)
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))

    def test_stdin_that_never_closes_has_a_deadline(self):
        started = time.monotonic()
        process = subprocess.Popen([str(BINARY), "--provider", "codex", "PreToolUse"],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            process.stdin.write(b"invalid")
            process.stdin.flush()
            # Deliberately keep stdin open: the process must end without EOF.
            self.assertEqual(process.wait(timeout=6), 0)
            self.assertEqual(process.stdout.read(), b"")
            self.assertEqual(process.stderr.read(), b"")
            self.assertLess(time.monotonic() - started, 6)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stdin.close()
            process.stdout.close()
            process.stderr.close()


if __name__ == "__main__":
    unittest.main()
