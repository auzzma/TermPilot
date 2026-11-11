import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

RUNNER = Path(__file__).resolve().parents[2] / 'engines/rust/src/batch/runner.py'


class BackgroundRunnerTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory(prefix='TermPilot-background-test-')
        self.environment = dict(os.environ, HOME=self.home.name)
        self.tasks = []

    def invoke(self, action, task, payload=None, check=True):
        result = subprocess.run([sys.executable, str(RUNNER), action, task, '-'],
                                input=base64.b64encode(json.dumps(payload or {}).encode()).decode() + '\n',
                                env=self.environment, capture_output=True, text=True, timeout=5)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(result.stdout.splitlines()[-1])

    def submit(self, body, timeout=0):
        task = str(uuid.uuid4())
        self.tasks.append(task)
        payload = dict(script=dict(body=body, environment={}, args=[]), jobId=str(uuid.uuid4()), ip='127.0.0.1', timeout=timeout)
        value = self.invoke('submit', task, payload)
        return task, payload, value

    def done(self, task):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            value = self.invoke('status', task)
            if value['status'] not in ('running', 'pending'):
                return value
            time.sleep(.02)
        self.fail('background task still running')

    def tearDown(self):
        for task in self.tasks:
            try:
                self.invoke('cancel', task, check=False)
                self.done(task)
            except Exception:
                pass
            work = Path('/tmp/ssh-batch-' + task)
            for path in [work, Path(str(work) + '.old')]:
                if path.is_symlink():
                    path.unlink()
                elif path.exists():
                    shutil.rmtree(path)
        self.home.cleanup()

    def test_detached_child_outlives_launcher_and_duplicate_submission_never_replays(self):
        task, payload, state = self.submit('sleep .3; printf "中文 result"; printf once >> "$HOME/marker"')
        self.assertTrue(Path(state['remoteWorkDirectory']).exists())
        self.invoke('submit', task, payload)
        final = self.done(task)
        self.assertEqual(final['status'], 'success', final)
        self.assertEqual(final['stdout'], '中文 result')
        self.assertEqual(Path(self.home.name, 'marker').read_text(), 'once')
        self.assertFalse(Path(final['remoteWorkDirectory']).exists())
        self.invoke('submit', task, payload)
        self.assertEqual(Path(self.home.name, 'marker').read_text(), 'once')

    def test_failure_and_timeout_cleanup_are_remote(self):
        task, _, _ = self.submit('printf failure >&2; exit 9')
        final = self.done(task)
        self.assertEqual((final['status'], final['exitCode'], final['cleanupStatus']), ('failed', 9, 'success'))
        task, _, _ = self.submit('sleep 15', timeout=1)
        final = self.done(task)
        self.assertEqual(final['status'], 'failed', final)
        self.assertTrue(final['timedOut'])
        self.assertEqual(final['cleanupStatus'], 'success')

    def test_explicit_cancel_reaps_process_group(self):
        task, _, _ = self.submit('sleep 15; touch "$HOME/should-not-exist"')
        self.invoke('cancel', task)
        final = self.done(task)
        self.assertEqual(final['status'], 'cancelled', final)
        self.assertEqual(final['cleanupStatus'], 'success')
        self.assertFalse(Path(self.home.name, 'should-not-exist').exists())

    def test_finished_state_is_not_overwritten_by_frequent_queries(self):
        for _ in range(8):
            task, _, _ = self.submit('sleep .05; exit 0')
            self.assertEqual(self.done(task)['status'], 'success')

    def test_maximum_size_script_runs_and_leaves_no_script_file(self):
        ending = '\nprintf full-size'
        body = '#' + 'x' * (128 * 1024 - len(ending) - 1) + ending
        task, _, _ = self.submit(body)
        final = self.done(task)
        self.assertEqual(final['status'], 'success', final)
        self.assertEqual(final['stdout'], 'full-size')
        self.assertFalse(Path(final['remoteWorkDirectory']).exists())
        self.assertFalse(any(p.suffix == '.sh' for p in Path(final['remoteLogDirectory']).iterdir()))

    def test_state_reader_tolerates_atomic_replacement_after_open(self):
        import importlib.util
        from unittest.mock import patch
        spec = importlib.util.spec_from_file_location('background_runner', RUNNER)
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        directory = self.home.name
        old = Path(directory, 'state.json')
        new = Path(directory, 'next.json')
        old.write_text('{"status":"running"}')
        new.write_text('{"status":"success"}')
        old.chmod(0o600)
        new.chmod(0o600)
        real_stat = os.fstat
        def replace_after_open(fd):
            os.replace(new, old)
            return real_stat(fd)
        with patch.object(runner.os, 'fstat', side_effect=replace_after_open):
            self.assertEqual(runner.read_state(directory)['status'], 'running')
        self.assertEqual(runner.read_state(directory)['status'], 'success')
        os.link(old, Path(directory, 'hard-link'))
        with self.assertRaises(RuntimeError):
            runner.read_state(directory)

    def test_cleanup_never_follows_replaced_directory(self):
        protected = Path(self.home.name, 'protected')
        protected.mkdir()
        (protected / 'keep').write_text('safe')
        task, _, _ = self.submit('mv "$REMOTE_WORK_DIR" "$REMOTE_WORK_DIR.old"; ln -s "$HOME/protected" "$REMOTE_WORK_DIR"')
        final = self.done(task)
        self.assertEqual(final['cleanupStatus'], 'failed')
        self.assertEqual((protected / 'keep').read_text(), 'safe')

    def test_unknown_receipt_is_read_only_and_results_are_private(self):
        unknown = str(uuid.uuid4())
        self.assertEqual(self.invoke('status', unknown)['status'], 'unknown')
        self.assertFalse(Path(self.home.name, '.ssh-batch-results').exists())
        task, _, _ = self.submit('printf content')
        final = self.done(task)
        directory = Path(final['remoteLogDirectory'])
        for path in directory.iterdir():
            self.assertEqual(path.stat().st_mode & 0o077, 0)
        outside = Path(self.home.name, 'outside')
        outside.write_text('unchanged')
        (directory / 'stdout.log').unlink()
        (directory / 'stdout.log').symlink_to(outside)
        self.assertIn('error', self.invoke('logs', task, dict(stream='stdout', offset=0), check=False))
        self.assertEqual(outside.read_text(), 'unchanged')


if __name__ == '__main__':
    unittest.main()
