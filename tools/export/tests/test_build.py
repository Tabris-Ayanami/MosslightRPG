"""Build orchestration tests: real temporary artifacts, no Godot processes."""
from __future__ import annotations

from contextlib import ExitStack
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
from tools.export import build as exporter


class BuildTests(unittest.TestCase):
    PACK_BYTES = b'one export: the exact checked pack\x00\xff'
    EXE_BYTES = b'MZ independent Windows template fixture'
    TEMPLATE_BYTES = b'MZ version-pinned debug template fixture'

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='mosslight-build-test-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.project = self.root / 'project'
        (self.project / 'tests').mkdir(parents=True)
        (self.project / 'data').mkdir()
        (self.project / 'tests/export_smoke.gd').write_text('extends SceneTree\n', encoding='utf-8')
        (self.project / 'data/game.json').write_text('{"unchanged":true}\n', encoding='utf-8')
        self.preset = self.project / 'export_presets.cfg'
        self.write_preset(embedded=False)
        self.engine = self.root / 'godot.exe'
        self.engine.write_bytes(b'fake version-pinned editor; never executable')
        self.template = self.root / 'windows_debug_x86_64.exe'
        self.template.write_bytes(self.TEMPLATE_BYTES)
        self.output = self.root / 'output'
        self.export_calls = []
        self.smoke_calls = []
        self.missing = set()
        self.empty = set()
        self.export_code = 0
        self.export_stderr = ''
        self.on_export = None
        self.on_smoke = None

    def write_preset(self, *, embedded):
        self.preset.write_text(
            '[preset.0]\nname="Windows Debug"\nplatform="Windows Desktop"\n'
            'exclude_filter=""\n[preset.0.options]\n'
            'custom_template/debug=""\n'
            'binary_format/embed_pck=' + ('true' if embedded else 'false') + '\n'
            'binary_format/architecture="x86_64"\n', encoding='utf-8')

    @staticmethod
    def sha(data):
        return hashlib.sha256(data).hexdigest()

    def source_manifest(self):
        return {name: self.sha((self.project / name).read_bytes())
                for name in ('export_presets.cfg', 'data/game.json')}

    def templates(self, _engine):
        return {'directory': str(self.root), 'directory_exists': True,
                'windows_debug_x86_64': str(self.template),
                'debug_available': self.template.is_file(), 'windows_release_x86_64': str(self.template), 'release_available': self.template.is_file()}

    def fake_run(self, argv, cwd, log_dir, label, timeout):
        argv = [str(argument) for argument in argv]
        self.export_calls.append({'argv': argv, 'cwd': Path(cwd), 'label': label})
        self.assertTrue(any(flag in argv for flag in ('--export-debug', '--export-release', '--export-pack')))
        target = Path(argv[-1])
        is_executable = '--export-debug' in argv or '--export-release' in argv
        artifacts = {'pck': target.with_suffix('.pck')}
        if is_executable:
            artifacts['exe'] = target
        for kind, path in artifacts.items():
            if kind not in self.missing:
                payload = self.EXE_BYTES if kind == 'exe' else self.PACK_BYTES
                path.write_bytes(b'' if kind in self.empty else payload)
        Path(log_dir, label + '.stdout.log').write_text('', encoding='utf-8')
        Path(log_dir, label + '.stderr.log').write_text(self.export_stderr, encoding='utf-8')
        if self.on_export:
            self.on_export()
        return {'argv': argv, 'cwd': str(cwd), 'returncode': self.export_code, 'seconds': .01}

    def fake_smoke(self, engine, pck, destination, expected, bundle=None):
        pck = Path(pck)
        observed = {'engine': Path(engine), 'pck': pck, 'bytes': pck.read_bytes(),
                    'expected': dict(expected), 'bundle': bundle}
        self.smoke_calls.append(observed)
        result = {'returncode': 0, 'report': {'ok': True, 'checks': 5, 'failures': []},
                  'errors': [], 'pck_sha256': self.sha(observed['bytes'])}
        if self.on_smoke:
            self.on_smoke(len(self.smoke_calls), result)
        return result

    def build(self, *, debug_exe=False, bundle=None, release_exe=False):
        with ExitStack() as patches:
            patches.enter_context(mock.patch.object(exporter, 'PROJECT', self.project))
            patches.enter_context(mock.patch.object(exporter, 'source_manifest', side_effect=self.source_manifest))
            patches.enter_context(mock.patch.object(exporter, 'templates', side_effect=self.templates))
            patches.enter_context(mock.patch.object(exporter, 'run', side_effect=self.fake_run))
            patches.enter_context(mock.patch.object(exporter, 'smoke', side_effect=self.fake_smoke))
            patches.enter_context(mock.patch.object(exporter.subprocess, 'check_output', return_value=exporter.ENGINE_VERSION + '.official.fixture'))
            patches.enter_context(mock.patch.object(exporter.subprocess, 'Popen', side_effect=AssertionError('This test must never start a process')))
            return exporter.build(self.engine, self.output, debug_exe=debug_exe, content_bundle=bundle, release_exe=release_exe)

    def assert_failure_report(self, result):
        self.assertFalse(result['ok'])
        self.assertTrue(result['errors'])
        self.assertFalse(result['independent_exe_verified'])
        report = json.loads((self.output / 'report.json').read_text(encoding='utf-8'))
        self.assertFalse(report['ok'])
        self.assertEqual(report['errors'], result['errors'])

    def test_default_remains_pck_only_without_windows_template(self):
        self.template.unlink()
        result = self.build()
        self.assertTrue(result['ok'], result['errors'])
        self.assertTrue(result['pck_verified'])
        self.assertFalse(result['independent_exe_verified'])
        self.assertEqual(len(self.export_calls), 1)
        self.assertIn('--export-pack', self.export_calls[0]['argv'])
        self.assertNotIn('--export-debug', self.export_calls[0]['argv'])
        self.assertEqual(Path(self.export_calls[0]['argv'][-1]), self.output / 'MosslightRPG.pck')
        self.assertEqual(len(self.smoke_calls), 1)
        self.assertEqual(self.smoke_calls[0]['bytes'], self.PACK_BYTES)
        self.assertNotIn('debug_exe', result)
        self.assertFalse((self.output / 'MosslightRPG.exe').exists())

    def test_release_export_verifies_its_exact_companion_pack(self):
        result = self.build(release_exe=True)
        self.assertTrue(result['ok'], result['errors'])
        self.assertEqual(len(self.export_calls), 1)
        self.assertIn('--export-release', self.export_calls[0]['argv'])
        self.assertNotIn('debug_exe', result)
        self.assertEqual(result['release_exe']['sha256'], self.sha(self.EXE_BYTES))
        self.assertEqual(self.smoke_calls[0]['bytes'], self.PACK_BYTES)

    def test_debug_export_is_one_adjacent_exe_and_exact_pack_with_honest_report(self):
        result = self.build(debug_exe=True)
        self.assertTrue(result['ok'], result['errors'])
        self.assertEqual(len(self.export_calls), 1, 'An EXE build must not silently replace an earlier verified export')
        argv = self.export_calls[0]['argv']
        self.assertIn('--export-debug', argv)
        self.assertNotIn('--export-pack', argv)
        self.assertEqual(argv[argv.index('--export-debug') + 1], exporter.PRESET)
        exe = self.output / 'MosslightRPG.exe'
        pck = self.output / 'MosslightRPG.pck'
        self.assertEqual(Path(argv[-1]), exe)
        self.assertEqual(exe.read_bytes(), self.EXE_BYTES)
        self.assertEqual(pck.read_bytes(), self.PACK_BYTES)
        self.assertFalse((self.output / 'windows-debug').exists())
        self.assertEqual(len(self.smoke_calls), 1)
        self.assertEqual(self.smoke_calls[0]['pck'], pck)
        self.assertEqual(self.smoke_calls[0]['bytes'], self.PACK_BYTES)
        self.assertEqual(self.smoke_calls[0]['expected'], {'res://data/game.json': self.source_manifest()['data/game.json']})
        self.assertTrue(result['pck_verified'])
        self.assertFalse(result['independent_exe_verified'])
        self.assertEqual(result['pck_sha256'], self.sha(self.PACK_BYTES))
        self.assertEqual(result['export']['argv'], argv)
        self.assertEqual(result['debug_exe'], {
            'path': str(exe), 'sha256': self.sha(self.EXE_BYTES), 'bytes': len(self.EXE_BYTES),
            'template_sha256': self.sha(self.TEMPLATE_BYTES), 'runtime_verified': False})
        saved = json.loads((self.output / 'report.json').read_text(encoding='utf-8'))
        self.assertEqual(saved['debug_exe'], result['debug_exe'])
        self.assertFalse(saved['independent_exe_verified'])

    def test_bundle_smoke_uses_the_same_single_debug_export(self):
        bundle = self.root / 'reviewed-bundle'
        bundle.mkdir()
        result = self.build(debug_exe=True, bundle=bundle)
        self.assertTrue(result['ok'], result['errors'])
        self.assertEqual(len(self.export_calls), 1)
        self.assertEqual(len(self.smoke_calls), 2)
        self.assertIsNone(self.smoke_calls[0]['bundle'])
        self.assertEqual(Path(self.smoke_calls[1]['bundle']), bundle.resolve())
        self.assertTrue(all(call['pck'] == self.output / 'MosslightRPG.pck' and call['bytes'] == self.PACK_BYTES for call in self.smoke_calls))
        self.assertEqual(result['smoke']['pck_sha256'], result['external_bundle_smoke']['pck_sha256'])
        self.assertFalse(result['debug_exe']['runtime_verified'])

    def test_missing_template_fails_before_any_export_or_smoke(self):
        self.template.unlink()
        result = self.build(debug_exe=True)
        self.assert_failure_report(result)
        self.assertEqual(self.export_calls, [])
        self.assertEqual(self.smoke_calls, [])
        self.assertFalse(result['pck_verified'])

    def test_embedded_pack_preset_is_rejected_before_export(self):
        self.write_preset(embedded=True)
        result = self.build(debug_exe=True)
        self.assert_failure_report(result)
        self.assertEqual(self.export_calls, [])
        self.assertEqual(self.smoke_calls, [])

    def test_wrong_architecture_or_custom_template_is_rejected_before_export(self):
        changes = [('architecture', 'binary_format/architecture="x86_64"', 'binary_format/architecture="x86_32"'),
                   ('custom-template', 'custom_template/debug=""', 'custom_template/debug="foreign.exe"')]
        for label, original, replacement in changes:
            with self.subTest(preset=label):
                self.output = self.root / label
                self.write_preset(embedded=False)
                self.preset.write_text(self.preset.read_text(encoding='utf-8').replace(original, replacement), encoding='utf-8')
                result = self.build(debug_exe=True)
                self.assert_failure_report(result)
                self.assertEqual(self.export_calls, [])
                self.assertEqual(self.smoke_calls, [])

    def test_editor_binary_cannot_masquerade_as_exported_executable(self):
        self.on_export = lambda: (self.output / 'MosslightRPG.exe').write_bytes(self.engine.read_bytes())
        result = self.build(debug_exe=True)
        self.assert_failure_report(result)
        self.assertFalse(result['pck_verified'])
        self.assertEqual(self.smoke_calls, [])

    def test_missing_or_empty_exe_and_pack_never_reach_smoke(self):
        for kind in ('exe', 'pck'):
            for defect in ('missing', 'empty'):
                with self.subTest(artifact=kind, defect=defect):
                    self.output = self.root / (kind + '-' + defect)
                    self.missing = {kind} if defect == 'missing' else set()
                    self.empty = {kind} if defect == 'empty' else set()
                    self.export_calls.clear()
                    self.smoke_calls.clear()
                    result = self.build(debug_exe=True)
                    self.assert_failure_report(result)
                    self.assertFalse(result['pck_verified'])
                    self.assertEqual(self.smoke_calls, [])

    def test_export_failure_keeps_artifacts_but_does_not_claim_verification(self):
        self.export_code = 7
        result = self.build(debug_exe=True)
        self.assert_failure_report(result)
        self.assertEqual(result['export']['returncode'], 7)
        self.assertFalse(result['pck_verified'])
        self.assertEqual(self.smoke_calls, [])
        self.assertEqual((self.output / 'MosslightRPG.pck').read_bytes(), self.PACK_BYTES)
        self.assertEqual((self.output / 'MosslightRPG.exe').read_bytes(), self.EXE_BYTES)

    def test_zero_exit_with_engine_error_is_not_a_successful_export(self):
        self.export_stderr = 'ERROR: missing exported game resource\n'
        result = self.build(debug_exe=True)
        self.assert_failure_report(result)
        self.assertFalse(result['pck_verified'])
        self.assertEqual(self.smoke_calls, [])

    def test_source_mutation_during_export_is_rejected_before_smoke(self):
        self.on_export = lambda: (self.project / 'data/game.json').write_text('{"changed":true}\n', encoding='utf-8')
        result = self.build(debug_exe=True)
        self.assert_failure_report(result)
        self.assertEqual(self.smoke_calls, [])
        self.assertFalse(result['pck_verified'])

    def test_source_mutation_during_smoke_prevents_success(self):
        def mutate(_index, _result):
            (self.project / 'data/game.json').write_text('{"changed_after_export":true}\n', encoding='utf-8')
        self.on_smoke = mutate
        self.assert_failure_report(self.build(debug_exe=True))

    def test_pack_or_exe_mutation_after_smoke_prevents_success(self):
        for extension in ('pck', 'exe'):
            with self.subTest(artifact=extension):
                self.output = self.root / ('changed-' + extension)
                self.export_calls.clear()
                self.smoke_calls.clear()
                def mutate(_index, _result):
                    (self.output / ('MosslightRPG.' + extension)).write_bytes(b'replaced after smoke')
                self.on_smoke = mutate
                result = self.build(debug_exe=True)
                self.assert_failure_report(result)
                self.assertEqual(self.smoke_calls[0]['bytes'], self.PACK_BYTES)

    def test_installed_template_drift_during_verification_prevents_success(self):
        def mutate(_index, _result):
            self.template.write_bytes(b'different installed template')
        self.on_smoke = mutate
        self.assert_failure_report(self.build(debug_exe=True))

    def test_smoke_failure_retains_export_and_failure_diagnostics(self):
        def fail(_index, _result):
            raise RuntimeError('fixture: exact exported PCK smoke failed')
        self.on_smoke = fail
        result = self.build(debug_exe=True)
        self.assert_failure_report(result)
        self.assertFalse(result['pck_verified'])
        self.assertEqual((self.output / 'MosslightRPG.pck').read_bytes(), self.PACK_BYTES)
        self.assertEqual((self.output / 'MosslightRPG.exe').read_bytes(), self.EXE_BYTES)


if __name__ == '__main__':
    unittest.main()
