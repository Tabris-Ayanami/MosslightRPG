"""Offline adapter coverage. Fake CLI output/local Python only; no AI calls."""
from __future__ import annotations

import copy
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
from tools.content_pipeline import antigravity as adapter


class AntigravityTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='mosslight-agy-offline-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.brief = self.root / 'brief.txt'
        self.brief.write_text('柳林守望；使用克制的数值与简体中文名称。', encoding='utf-8')
        source = (ROOT / 'tools/content_pipeline/examples/trail_guard/pack.json').read_text('utf-8')
        self.pack = json.loads(source.replace('trail_guard', 'fixture_pack'))
        self.pack['assets'] = {}
        self.pack['bindings'] = []
        for entry in self.pack['catalogs']['weapons'].values():
            entry['special_effects'] = []
        self.jobs = 0

    def fake(self, *, pack=None, before=None, after=None, stderr='', returncode=0,
             status='SUCCESS', structured=None, missing=False, error=None):
        candidate = self.pack if pack is None else pack
        def run(argv, job, timeout):
            self.assertEqual(argv[0], str(Path(sys.executable).resolve()))
            self.assertNotIn('--dangerously-skip-permissions', argv)
            self.assertNotIn('--continue', argv)
            self.assertNotIn('--sandbox', argv)
            self.assertEqual(argv[argv.index('--json-schema') + 1], str(job / 'schema.json'))
            result = {'status': status, 'structured_output': structured if structured is not None else
                      {'pack_json': json.dumps(candidate, ensure_ascii=False)}}
            if error is not None:
                result['error'] = error
            events = [{'event': 'init', 'init': {'cwd': str(job), 'tools': ['finish'], 'permission_mode': 'request-review'}}]
            events += before or []
            if not missing:
                events.append({'event': 'result', 'result': result})
            events += after or []
            (job / 'stdout.ndjson').write_bytes(b''.join(adapter.encode(e).replace(b'\n', b'') + b'\n' for e in events))
            (job / 'stderr.txt').write_text(stderr, encoding='utf-8')
            return {'returncode': returncode, 'stop_reason': '', 'duration_seconds': 0}
        return run

    def run_job(self, runner=None, **kwargs):
        self.jobs += 1
        options = dict(brief=self.brief, pack_id='fixture_pack', job=self.root / f'job-{self.jobs}',
                       cli=Path(sys.executable), runner=runner or self.fake())
        options.update(kwargs)
        return adapter.run_job(**options)

    def assert_failed(self, report):
        self.assertFalse(report['ok'])
        self.assertEqual(report['status'], 'failed')
        self.assertFalse(report['ready_for_build'])
        self.assertTrue(report['errors'])
        job = Path(report['job'])
        self.assertFalse((job / 'pack.json').exists())
        self.assertTrue((job / 'stdout.ndjson').exists())
        self.assertTrue((job / 'stderr.txt').exists())
        self.assertEqual(json.loads((job / 'report.json').read_text('utf-8'))['status'], 'failed')

    def test_prepare_only_records_contract_without_calling_cli(self):
        runner = Mock(side_effect=AssertionError('must not launch'))
        report = self.run_job(runner, prepare_only=True, count=2)
        self.assertEqual(report['status'], 'prepared')
        self.assertFalse(report['ok'])
        self.assertFalse(report['ready_for_build'])
        runner.assert_not_called()
        job = Path(report['job'])
        for name in ('brief.txt', 'prompt.txt', 'schema.json', 'content-schema.json', 'argv.json', 'report.json'):
            self.assertTrue((job / name).is_file())
        self.assertFalse((job / 'pack.json').exists())
        self.assertEqual(json.loads((job / 'schema.json').read_text('utf-8')), adapter.TRANSPORT)
        metadata = json.loads((job / 'argv.json').read_text('utf-8'))
        self.assertFalse(metadata['is_os_sandbox'])
        self.assertEqual(metadata['cwd'], str(job))
        self.assertIn('Exactly 2 entries', (job / 'prompt.txt').read_text('utf-8'))

    def test_legal_output_passes_full_validator_and_preserves_base(self):
        originals = {p: p.read_bytes() for p in (ROOT / 'data/combat').glob('*.json')}
        report = self.run_job()
        self.assertTrue(report['ok'], report['errors'])
        self.assertTrue(report['ready_for_build'])
        self.assertEqual(report['status'], 'validated')
        self.assertTrue(report['validation']['ok'])
        job = Path(report['job'])
        self.assertEqual(json.loads((job / 'pack.json').read_text('utf-8')), self.pack)
        self.assertEqual(report['pack_sha256'], adapter.sha((job / 'pack.json').read_bytes()))
        self.assertEqual(originals, {p: p.read_bytes() for p in originals})

    def test_exit_zero_soft_denial_never_publishes_pack(self):
        for notice in ('jetski: read_file was auto-denied in headless mode',
                       'permission required; tool was denied', 'AGY_ERROR: partial response failed'):
            with self.subTest(notice=notice):
                report = self.run_job(self.fake(stderr=notice))
                self.assert_failed(report)
                self.assertTrue((Path(report['job']) / 'raw-pack.txt').is_file())

    def test_error_message_tool_error_and_tool_use_are_rejected(self):
        steps = [
            {'step_type': 'error_message', 'state': 'DONE'},
            {'step_type': 'tool', 'tool_name': 'finish', 'tool_info': {'name': 'finish', 'error': {'message': 'bad'}}},
            {'step_type': 'tool', 'tool_name': 'write_to_file', 'state': 'ACTIVE'},
            {'step_type': 'tool', 'tool_name': 'generate_image', 'state': 'ACTIVE'},
            {'step_type': 'subagent', 'subagent_info': {}},
            {'step_type': 'run_command', 'state': 'ACTIVE'},
        ]
        for step in steps:
            with self.subTest(step=step):
                self.assert_failed(self.run_job(self.fake(before=[{'event': 'step_update', 'step_update': step}])))

    def test_finish_submission_step_is_not_mistaken_for_filesystem_tool(self):
        event = {'event': 'step_update', 'step_update': {'step_type': 'finish', 'state': 'DONE'}}
        self.assertTrue(self.run_job(self.fake(before=[event]))['ok'])

    def test_missing_or_duplicate_terminal_results(self):
        self.assert_failed(self.run_job(self.fake(missing=True)))
        duplicate = {'event': 'result', 'result': {'status': 'SUCCESS', 'structured_output': {'pack_json': '{}'}}}
        self.assert_failed(self.run_job(self.fake(after=[duplicate])))

    def test_returncode_and_result_status_are_both_required(self):
        for options in ({'returncode': 3}, {'status': 'ERROR'}, {'status': 'WAITING'}, {'error': 'failed after partial output'}):
            with self.subTest(options=options):
                self.assert_failed(self.run_job(self.fake(**options)))

    def test_transport_type_unknown_field_and_malformed_json(self):
        for value in ([], {'pack_json': self.pack}, {'pack_json': '{}', 'extra': 1},
                      {'pack_json': '{'}, {'pack_json': '{"pack_id":"a","pack_id":"b"}'}):
            with self.subTest(value=value):
                self.assert_failed(self.run_job(self.fake(structured=value)))

    def test_namespace_counts_and_artwork_are_local_requirements(self):
        variants = []
        pack = copy.deepcopy(self.pack); pack['pack_id'] = 'wrong'; variants.append(pack)
        pack = copy.deepcopy(self.pack); pack['catalogs']['items'] = {}; variants.append(pack)
        pack = copy.deepcopy(self.pack); pack['catalogs']['items']['outside:bad'] = pack['catalogs']['items'].pop(next(iter(pack['catalogs']['items']))); variants.append(pack)
        pack = copy.deepcopy(self.pack); pack['assets'] = {'fixture_pack:bad': {'kind': 'icon', 'path': 'missing.png'}}; variants.append(pack)
        for pack in variants:
            with self.subTest(pack=pack['pack_id']):
                self.assert_failed(self.run_job(self.fake(pack=pack)))
        self.assert_failed(self.run_job(count=2))

    def test_full_schema_and_semantic_reference_checks_are_not_transport_checks(self):
        unknown = copy.deepcopy(self.pack)
        next(iter(unknown['catalogs']['items'].values()))['invented_mechanic'] = True
        missing = copy.deepcopy(self.pack)
        next(iter(missing['catalogs']['skills'].values()))['effects'][0]['status'] = 'not_a_real_status'
        for pack in (unknown, missing):
            report = self.run_job(self.fake(pack=pack))
            self.assert_failed(report)
            self.assertFalse(report['validation']['ok'])
            self.assertTrue(report['validation']['errors'])
            self.assertTrue((Path(report['job']) / 'draft-pack.json').is_file())

    def test_existing_job_is_not_reused_or_overwritten(self):
        job = self.root / 'existing'
        job.mkdir()
        sentinel = job / 'report.json'
        sentinel.write_text('leave this evidence', encoding='utf-8')
        runner = Mock()
        with self.assertRaises(FileExistsError):
            self.run_job(runner, job=job)
        runner.assert_not_called()
        self.assertEqual(sentinel.read_text('utf-8'), 'leave this evidence')
        self.assertEqual(list(job.iterdir()), [sentinel])

    def test_invalid_finite_limits_fail_before_job_creation(self):
        for options in ({'timeout': float('inf')}, {'timeout': float('nan')}, {'timeout': 0},
                        {'timeout': 1801}, {'count': 0}, {'count': 17}, {'pack_id': '../wrong'}):
            with self.subTest(options=options), self.assertRaises(ValueError):
                self.run_job(**options)
        self.assertEqual(list(self.root.iterdir()), [self.brief])

    def test_wrong_workspace_and_non_json_stdout_are_rejected(self):
        def runner(argv, job, timeout):
            (job / 'stdout.ndjson').write_text('not json\n', encoding='utf-8')
            (job / 'stderr.txt').write_text('', encoding='utf-8')
            return {'returncode': 0}
        self.assert_failed(self.run_job(runner))
        audit = adapter.TraceAudit(self.root / 'expected')
        audit.line(json.dumps({'event': 'init', 'init': {'cwd': str(self.root / 'wrong')}}).encode())
        self.assertIn('workspace', audit.error)

    def test_owned_process_is_stopped_immediately_after_error_message(self):
        job = self.root / 'local-fake-error'; job.mkdir()
        script = "import json,os,time;print(json.dumps({'event':'init','init':{'cwd':os.getcwd()}}),flush=True);print(json.dumps({'event':'step_update','step_update':{'step_type':'error_message'}}),flush=True);time.sleep(15)"
        started = time.monotonic()
        outcome = adapter.run_process([sys.executable, '-c', script], job, 10)
        self.assertLess(time.monotonic() - started, 4)
        self.assertIn('error_message', outcome['stop_reason'])
        self.assertNotEqual(outcome['returncode'], 0)
        self.assertIn('error_message', (job / 'stdout.ndjson').read_text('utf-8'))

    def test_owned_process_timeout_preserves_partial_trace(self):
        job = self.root / 'local-fake-timeout'; job.mkdir()
        script = "import json,os,time;print(json.dumps({'event':'init','init':{'cwd':os.getcwd()}}),flush=True);time.sleep(15)"
        outcome = adapter.run_process([sys.executable, '-c', script], job, 1)
        self.assertIn('timeout', outcome['stop_reason'])
        self.assertNotEqual(outcome['returncode'], 0)
        self.assertTrue((job / 'stdout.ndjson').read_bytes())

    def test_missing_executable_records_failure_without_candidate(self):
        report = self.run_job(adapter.run_process, cli=self.root / 'missing-agy.exe')
        self.assert_failed(report)
        outcome = json.loads((Path(report['job']) / 'exit.json').read_text('utf-8'))
        self.assertIsNone(outcome['returncode'])
        self.assertIn('could not run', outcome['stop_reason'])

    def test_runner_timeout_cannot_be_treated_as_valid_pack(self):
        fake = self.fake()
        def runner(argv, job, timeout):
            outcome = fake(argv, job, timeout)
            outcome['stop_reason'] = 'Process exceeded the finite timeout'
            return outcome
        self.assert_failed(self.run_job(runner))


if __name__ == '__main__':
    unittest.main()
