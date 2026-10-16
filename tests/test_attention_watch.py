"""The native reader sleeps while its observed sources are unchanged."""
import importlib.util
import os
from pathlib import Path
import select
import tempfile
import time
import unittest

spec = importlib.util.spec_from_file_location('attention_bridge', Path(__file__).resolve().parents[1] / 'NotchBuddy/Resources/attention_bridge.py')
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)


@unittest.skipUnless(hasattr(select, 'kqueue'), 'macOS vnode watcher')
class SourceWatcherTests(unittest.TestCase):
    def test_source_watcher_is_available(self):
        self.assertTrue(hasattr(b, 'SourceWatcher'), 'reader currently polls rather than awaiting source events')

    def test_idle_then_file_change(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'rollout.jsonl'
            path.write_text('first\n')
            with b.SourceWatcher([path]) as watcher:
                self.assertFalse(watcher.wait(.03))
                with path.open('a') as stream:
                    stream.write('second\n')
                self.assertTrue(watcher.wait(1))
                self.assertFalse(watcher.wait(.03))

    def test_idle_stays_false_past_coalescing_window(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'rollout.jsonl'
            path.write_text('first\n')
            with b.SourceWatcher([path]) as watcher:
                with path.open('a') as stream:
                    stream.write('second\n')
                self.assertTrue(watcher.wait(1))
                self.assertFalse(watcher.wait(.05))
                # An unchanged source must not keep waking the loop, even past
                # the coalescing window.
                self.assertFalse(watcher.wait(b.SourceWatcher.MIN_WAKE_INTERVAL + .2))

    def test_directory_wakes_for_new_database(self):
        with tempfile.TemporaryDirectory() as root:
            with b.SourceWatcher([Path(root)]) as watcher:
                (Path(root) / 'state_5.sqlite-wal').write_text('changed')
                self.assertTrue(watcher.wait(1))

    def test_absent_file_watched_through_nearest_parent(self):
        with tempfile.TemporaryDirectory() as root:
            target = Path(root) / 'rollout.jsonl'
            with b.SourceWatcher([target]) as watcher:
                self.assertFalse(watcher.wait(.03))
                target.write_text('created\n')
                self.assertTrue(watcher.wait(1))

    def test_update_closes_old_watches_and_adopts_new_sources(self):
        with tempfile.TemporaryDirectory() as root:
            first = Path(root) / 'first.jsonl'
            second = Path(root) / 'second.jsonl'
            first.write_text('a\n')
            second.write_text('b\n')
            with b.SourceWatcher([first]) as watcher:
                watcher.update([second])
                with first.open('a') as stream:
                    stream.write('ignored\n')
                self.assertFalse(watcher.wait(.05), 'a closed watch must not fire')
                with second.open('a') as stream:
                    stream.write('watched\n')
                self.assertTrue(watcher.wait(1))

    def test_replacement_recovery(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'rollout.jsonl'
            path.write_text('one\n')
            with b.SourceWatcher([path]) as watcher:
                replacement = Path(root) / 'replacement.jsonl'
                replacement.write_text('two\n')
                os.replace(replacement, path)
                self.assertTrue(watcher.wait(1), 'a replaced source must wake the loop')
                watcher.update([path])  # re-open: adopts the replacement inode
                with path.open('a') as stream:
                    stream.write('three\n')
                self.assertTrue(watcher.wait(1), 'the replacement must be observed')

    def test_deleted_source_fires_then_updates_cleanly(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'rollout.jsonl'
            path.write_text('one\n')
            with b.SourceWatcher([path]) as watcher:
                path.unlink()
                self.assertTrue(watcher.wait(1))
                watcher.update([])
                self.assertFalse(watcher.wait(.05))

    def test_stdin_readiness_is_urgent_and_level_triggered(self):
        read_fd, write_fd = os.pipe()
        try:
            with b.SourceWatcher([], stdin_fd=read_fd) as watcher:
                self.assertFalse(watcher.wait(.03))
                os.write(write_fd, b'hint\n')
                self.assertTrue(watcher.wait(.5))
                os.read(read_fd, 64)
                self.assertFalse(watcher.wait(.05))
        finally:
            os.close(read_fd)
            os.close(write_fd)

    def test_bursts_are_coalesced(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'rollout.jsonl'
            path.write_text('a\n')
            with b.SourceWatcher([path]) as watcher:
                with path.open('a') as stream:
                    stream.write('first\n')
                self.assertTrue(watcher.wait(.5))
                start = time.monotonic()
                for _ in range(20):
                    with path.open('a') as stream:
                        stream.write('x\n')
                self.assertTrue(watcher.wait(1))
                # The burst is held back to the coalescing window: at most four
                # source checks per second.
                self.assertGreaterEqual(time.monotonic() - start,
                                        b.SourceWatcher.MIN_WAKE_INTERVAL - .05)


if __name__ == '__main__':
    unittest.main()
