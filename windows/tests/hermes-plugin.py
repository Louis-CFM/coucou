"""Exercise the generated plugin without starting Hermes or a real relay."""
import io
import pathlib
import threading
import unittest
from unittest.mock import patch

source = (pathlib.Path(__file__).resolve().parents[1] / 'src-tauri/src/agents.rs').read_text(encoding='utf-8')
template = source.split('const HERMES_PLUGIN: &str = r#"', 1)[1].split('"#;', 1)[0]
plugin = {}
exec(template.replace('{HOOK}', '"test-relay.exe"'), plugin)


class Hooks(unittest.TestCase):
    def setUp(self):
        self.callbacks = {}
        class Context:
            register_hook = lambda _, name, fn: self.callbacks.__setitem__(name, fn)
        plugin['register'](Context())

    def test_turn_end_is_not_session_end(self):
        with patch.dict(plugin, {'_fire': lambda fields: self.fail(str(fields))}):
            self.callbacks['on_session_end'](session_id='s', completed=True)

    def test_finalize_uses_exact_session_and_never_a_cached_fallback(self):
        received = []
        with patch.dict(plugin, {'_fire': lambda fields, finalize=False: received.append((fields, finalize))}):
            self.callbacks['on_session_finalize'](session_id='s', user_message='private')
            self.callbacks['on_session_finalize']()
        self.assertEqual(received, [({'hook_event_name': 'SessionEnd', 'session_id': 's', 'coucou_lifecycle': 'finalize'}, True)])

    def test_forwarding_remains_nonblocking(self):
        with patch.object(plugin['threading'], 'Thread') as thread:
            plugin['_fire']({'hook_event_name': 'SessionEnd', 'session_id': 's'})
            self.assertTrue(thread.call_args.kwargs['daemon'])
            thread.return_value.start.assert_called_once()
            thread.return_value.join.assert_not_called()
            plugin['_fire']({'hook_event_name': 'SessionEnd', 'session_id': 's'}, finalize=True)
            self.assertFalse(thread.call_args.kwargs['daemon'])
            thread.return_value.join.assert_not_called()

    def test_finalize_writer_finishes_locally_without_waiting_for_relay(self):
        threads = []
        class Process:
            stdin = io.BytesIO()
            def wait(self, **_):
                self_outer.fail('finalization waited for the relay')
        self_outer = self
        process = Process()
        thread_class = threading.Thread
        def start_thread(**kwargs):
            thread = thread_class(**kwargs)
            threads.append(thread)
            return thread
        with patch.object(plugin['threading'], 'Thread', side_effect=start_thread), \
             patch.object(plugin['subprocess'], 'Popen', return_value=process):
            self.callbacks['on_session_finalize'](session_id='s')
            for thread in threads:
                thread.join(timeout=1)
                self.assertFalse(thread.is_alive())
        self.assertTrue(process.stdin.closed)

    def test_prompt_and_answer_callbacks_remain_separate(self):
        received = []
        with patch.dict(plugin, {'_fire': received.append}):
            self.callbacks['pre_llm_call'](session_id='s', turn_id='t', user_message='private')
            self.callbacks['post_llm_call'](session_id='s', assistant_response='answer')
        self.assertNotIn('private', str(received))
        self.assertEqual(received[0]['hook_event_name'], 'UserPromptSubmit')
        self.assertEqual(received[1]['last_assistant_message'], 'answer')


if __name__ == '__main__':
    unittest.main()
