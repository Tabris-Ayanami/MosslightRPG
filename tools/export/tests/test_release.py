"""Release packaging tests; expensive Godot exports are mocked here."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
from tools.export import release


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mosslight-release-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        manifest_patch = mock.patch.object(release.exporter, 'source_manifest', return_value={'fixture/source.gd': 'f' * 64})
        manifest_patch.start()
        self.addCleanup(manifest_patch.stop)
        self.bundle = self.root / 'bundle-source'
        (self.bundle / 'assets').mkdir(parents=True)
        catalogs = b'{"items":{}}\n'
        (self.bundle / 'catalogs.json').write_bytes(catalogs)
        asset = b'candidate-art-bytes'
        (self.bundle / 'assets' / 'sample.dat').write_bytes(asset)
        bundle = {
            'format_version': 1,
            'contract': 'mosslight-energy-v1',
            'catalogs_file': 'catalogs.json',
            'catalogs_sha256': hashlib.sha256(catalogs).hexdigest(),
            'base_sha256': {'careers': '1' * 64},
            'packs': [{'pack_id': 'sample', 'version': '0.1.0', 'sha256': '2' * 64}],
            'assets': {'sample:asset': {'path': 'assets/sample.dat', 'sha256': hashlib.sha256(asset).hexdigest(), 'bytes': len(asset)}},
            'bindings': [],
        }
        bundle_raw = (json.dumps(bundle, ensure_ascii=False, sort_keys=True, separators=(',', ':')) + '\n').encode()
        (self.bundle / 'bundle.json').write_bytes(bundle_raw)
        receipt = {'format_version': 1, 'bundle_sha256': hashlib.sha256(bundle_raw).hexdigest()}
        (self.bundle / 'receipt.json').write_text(json.dumps(receipt) + '\n', encoding='utf-8')
        self.output = self.root / 'release'
        self.engine = self.root / 'godot.exe'
        self.engine.write_bytes(b'fake godot')
        self.original_bundle = {p.relative_to(self.bundle).as_posix(): p.read_bytes() for p in self.bundle.rglob('*') if p.is_file()}

    def fake_export(self, engine, output, debug_exe=False, content_bundle=None, release_exe=False):
        output.mkdir()
        pck = output / 'MosslightRPG.pck'
        pck.write_bytes(b'verified pck fixture')
        (output / 'source-manifest.json').write_text(json.dumps(release.exporter.source_manifest(), ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        result = {
            'ok': True,
            'pck_verified': True,
            'independent_exe_verified': False,
            'engine_version': '4.7.2.stable.official.test',
            'pck': str(pck),
            'pck_sha256': hashlib.sha256(pck.read_bytes()).hexdigest(),
        }
        if content_bundle is not None:
            result['external_bundle_smoke'] = {'report': {'ok': True}}
        if debug_exe or release_exe:
            exe = output / 'MosslightRPG.exe'
            exe.write_bytes(b'official debug template fixture')
            result['release_exe' if release_exe else 'debug_exe'] = {'path': str(exe), 'sha256': release.digest_file(exe),
                                   'bytes': exe.stat().st_size, 'template_sha256': 'd' * 64,
                                   'runtime_verified': False}
        return result

    def do_build(self, bundle=None, debug_exe=False):
        with mock.patch.object(release.exporter, 'build', side_effect=self.fake_export), \
             mock.patch.object(release, 'smoke_release', return_value={'returncode': 0, 'errors': []}), \
             mock.patch.object(release, 'smoke_native_release', return_value={'ok': True, 'verification_scope': 'local_headless_native_bootstrap'}):
            return release.build(self.engine, self.output, 'chapter_one', '0.1.0', bundle, debug_exe)

    def test_debug_release_publishes_adjacent_verified_files_and_scoped_native_report(self):
        result = self.do_build(self.bundle, debug_exe=True)
        self.assertTrue(result['ok'], result['errors'])
        for name in ['MosslightRPG.exe', 'MosslightRPG.pck', 'release.json', 'source-manifest.json', 'content']:
            self.assertTrue((self.output / name).exists(), name)
        self.assertFalse((self.output / 'windows-debug').exists())
        report = json.loads((self.output / 'report.json').read_text())
        self.assertFalse(report['independent_exe_verified'])
        self.assertTrue(report['native_bootstrap_verified'])
        self.assertEqual(report['native_bootstrap_verification_scope'], 'local_headless_native_bootstrap')
        self.assertFalse(report['target_machine_and_long_term_verified'])
        self.assertTrue(report['debug_exe']['runtime_verified'])
        self.assertEqual(report['debug_exe']['path'], str(self.output / 'MosslightRPG.exe'))
        self.assertEqual(report['debug_exe']['sha256'], release.digest_file(self.output / 'MosslightRPG.exe'))
        self.assertEqual(report['pck_sha256'], release.digest_file(self.output / 'MosslightRPG.pck'))

    def test_release_template_publication_keeps_bootstrap_verification(self):
        with mock.patch.object(release.exporter, 'build', side_effect=self.fake_export), \
             mock.patch.object(release, 'smoke_release', return_value={'returncode': 0, 'errors': []}), \
             mock.patch.object(release, 'smoke_native_release', return_value={'ok': True}) as native:
            result = release.build(self.engine, self.output, 'chapter_one', '0.1.0', self.bundle, release_exe=True)
        self.assertTrue(result['ok'], result['errors'])
        native.assert_called_once()
        self.assertTrue(result['export']['release_exe']['runtime_verified'])
        self.assertNotIn('debug_exe', result['export'])
        self.assertEqual(result['export']['release_exe']['sha256'], release.digest_file(self.output / 'MosslightRPG.exe'))

    def test_default_release_never_invokes_native_smoke(self):
        with mock.patch.object(release.exporter, 'build', side_effect=self.fake_export) as exporter, \
             mock.patch.object(release, 'smoke_release', return_value={'returncode': 0, 'errors': []}), \
             mock.patch.object(release, 'smoke_native_release') as native:
            result = release.build(self.engine, self.output, 'chapter_one', '0.1.0')
        self.assertTrue(result['ok'], result['errors'])
        self.assertFalse(exporter.call_args.kwargs['debug_exe'])
        native.assert_not_called()
        self.assertFalse(result['export']['independent_exe_verified'])

    def test_debug_cli_passes_existing_bundle_and_new_switch(self):
        with mock.patch.object(release, 'build', return_value={'ok': True}) as build_mock, \
             mock.patch('builtins.print'):
            self.assertEqual(release.main(['--engine', str(self.engine), '--output', str(self.output),
                                          '--release-id', 'chapter_one', '--version', '0.1.0',
                                          '--bundle', str(self.bundle), '--debug-exe']), 0)
        build_mock.assert_called_once_with(self.engine, self.output, 'chapter_one', '0.1.0', self.bundle, True, False)

    def test_native_failure_keeps_staging_and_does_not_claim_exe_verified(self):
        for native_result in [RuntimeError('native startup failed'), {'ok': False}]:
            with self.subTest(native_result=native_result):
                output = self.root / ('failed-' + str(isinstance(native_result, dict)))
                with mock.patch.object(release.exporter, 'build', side_effect=self.fake_export), \
                     mock.patch.object(release, 'smoke_release', return_value={'returncode': 0, 'errors': []}), \
                     mock.patch.object(release, 'smoke_native_release', **(
                         {'side_effect': native_result} if isinstance(native_result, Exception) else {'return_value': native_result})):
                    result = release.build(self.engine, output, 'chapter_one', '0.1.0', debug_exe=True)
                self.assertFalse(result['ok'])
                self.assertFalse(output.exists())
                stage = Path(result['staging'])
                self.assertTrue((stage / 'MosslightRPG.pck').is_file())
                self.assertTrue((stage / 'release-build-report.json').is_file())
                self.assertFalse(result['export']['independent_exe_verified'])
                self.assertFalse(result['export']['debug_exe']['runtime_verified'])

    def test_missing_exe_or_changed_exported_pck_fails_before_native_startup(self):
        for failure in ['missing-exe', 'empty-exe', 'changed-pck']:
            with self.subTest(failure=failure):
                def bad_export(engine, output, debug_exe=False, content_bundle=None):
                    exported = self.fake_export(engine, output, debug_exe, content_bundle)
                    if failure == 'missing-exe': (output / 'MosslightRPG.exe').unlink()
                    elif failure == 'empty-exe': (output / 'MosslightRPG.exe').write_bytes(b'')
                    else: (output / 'MosslightRPG.pck').write_bytes(b'not the tested pack')
                    return exported
                output = self.root / failure
                with mock.patch.object(release.exporter, 'build', side_effect=bad_export), \
                     mock.patch.object(release, 'smoke_release') as pack_smoke, \
                     mock.patch.object(release, 'smoke_native_release') as native:
                    result = release.build(self.engine, output, 'chapter_one', '0.1.0', debug_exe=True)
                self.assertFalse(result['ok'])
                self.assertFalse(output.exists())
                pack_smoke.assert_not_called()
                native.assert_not_called()

    def test_native_mutation_after_success_report_cannot_publish(self):
        for filename in ['MosslightRPG.pck', 'MosslightRPG.exe']:
            with self.subTest(filename=filename):
                def mutate_after_start(release_root, log_dir):
                    (release_root / filename).write_bytes(b'changed after successful startup')
                    return {'ok': True}
                output = self.root / filename.replace('.', '-')
                with mock.patch.object(release.exporter, 'build', side_effect=self.fake_export), \
                     mock.patch.object(release, 'smoke_release', return_value={'returncode': 0, 'errors': []}), \
                     mock.patch.object(release, 'smoke_native_release', side_effect=mutate_after_start):
                    result = release.build(self.engine, output, 'chapter_one', '0.1.0', debug_exe=True)
                self.assertFalse(result['ok'])
                self.assertFalse(output.exists())

    def test_export_failure_never_launches_or_publishes_native_release(self):
        with mock.patch.object(release.exporter, 'build', return_value={'ok': False, 'pck_verified': False}), \
             mock.patch.object(release, 'smoke_release') as pack_smoke, \
             mock.patch.object(release, 'smoke_native_release') as native:
            result = release.build(self.engine, self.output, 'chapter_one', '0.1.0', debug_exe=True)
        self.assertFalse(result['ok'])
        self.assertFalse(self.output.exists())
        pack_smoke.assert_not_called()
        native.assert_not_called()

    def test_release_wraps_bundle_identity_and_preserves_source_bytes(self):
        result = self.do_build(self.bundle)
        self.assertTrue(result['ok'], result['errors'])
        manifest = json.loads((self.output / 'release.json').read_text('utf-8'))
        identity = release.inspect_bundle(self.bundle)
        self.assertEqual(set(manifest), {'format_version', 'release_id', 'version', 'engine_version', 'source_manifest_sha256', 'pck', 'content'})
        self.assertEqual(manifest['content'], {'path': 'content', 'identity': identity})
        self.assertEqual(manifest['pck']['sha256'], hashlib.sha256((self.output / 'MosslightRPG.pck').read_bytes()).hexdigest())
        source_manifest_raw = (self.output / 'source-manifest.json').read_bytes()
        self.assertEqual(manifest['source_manifest_sha256'], hashlib.sha256(source_manifest_raw).hexdigest())
        self.assertEqual(self.original_bundle, {p.relative_to(self.bundle).as_posix(): p.read_bytes() for p in self.bundle.rglob('*') if p.is_file()})
        self.assertEqual(self.original_bundle, {p.relative_to(self.output / 'content').as_posix(): p.read_bytes() for p in (self.output / 'content').rglob('*') if p.is_file()})
        report = json.loads((self.output / 'report.json').read_text('utf-8'))
        self.assertEqual(report['release'], manifest)
        self.assertEqual(report['release_smoke']['returncode'], 0)
        self.assertEqual(Path(report['pck']), self.output / 'MosslightRPG.pck')

    def test_builtin_release_has_empty_content_field(self):
        result = self.do_build()
        self.assertTrue(result['ok'], result['errors'])
        manifest = json.loads((self.output / 'release.json').read_text('utf-8'))
        self.assertEqual(manifest['content'], {})

    def test_existing_target_is_never_overwritten(self):
        self.output.mkdir()
        sentinel = self.output / 'keep.txt'
        sentinel.write_text('keep', encoding='utf-8')
        result = self.do_build()
        self.assertFalse(result['ok'])
        self.assertEqual(sentinel.read_text('utf-8'), 'keep')
        self.assertEqual(list(self.output.iterdir()), [sentinel])

    def test_bad_bundle_hash_leaves_no_publish_target(self):
        (self.bundle / 'catalogs.json').write_bytes(b'changed')
        result = self.do_build(self.bundle)
        self.assertFalse(result['ok'])
        self.assertFalse(self.output.exists())
        self.assertTrue(Path(result['staging']).is_dir())
        self.assertTrue((Path(result['staging']) / 'release-build-report.json').is_file())

    def test_bundle_mutation_during_export_is_rejected(self):
        def mutate_after_initial_check(engine, output, debug_exe=False, content_bundle=None):
            result = self.fake_export(engine, output, debug_exe, content_bundle)
            (self.bundle / 'assets' / 'sample.dat').write_bytes(b'changed after preflight')
            return result

        with mock.patch.object(release.exporter, 'build', side_effect=mutate_after_initial_check), \
             mock.patch.object(release, 'smoke_release', return_value={'returncode': 0, 'errors': []}):
            result = release.build(self.engine, self.output, 'chapter_one', '0.1.0', self.bundle)
        self.assertFalse(result['ok'])
        self.assertFalse(self.output.exists())
        self.assertTrue(Path(result['staging']).is_dir())
        self.assertIn('mismatch', ' '.join(result['errors']).lower())

    def test_bundle_mutation_after_copy_before_publish_is_rejected(self):
        def mutate_during_smoke(engine, release_root, log_dir):
            (self.bundle / 'assets' / 'sample.dat').write_bytes(b'changed after release copy')
            return {'returncode': 0, 'errors': []}

        with mock.patch.object(release.exporter, 'build', side_effect=self.fake_export), \
             mock.patch.object(release, 'smoke_release', side_effect=mutate_during_smoke):
            result = release.build(self.engine, self.output, 'chapter_one', '0.1.0', self.bundle)
        self.assertFalse(result['ok'])
        self.assertFalse(self.output.exists())
        self.assertIn('changed before final', ' '.join(result['errors']).lower())

    def test_source_manifest_drift_before_publish_is_rejected(self):
        original = release.exporter.source_manifest()
        changed = dict(original)
        changed['new/source.py'] = 'f' * 64
        with mock.patch.object(release.exporter, 'build', side_effect=self.fake_export), \
             mock.patch.object(release.exporter, 'source_manifest', side_effect=[original, changed]), \
             mock.patch.object(release, 'smoke_release', return_value={'returncode': 0, 'errors': []}):
            result = release.build(self.engine, self.output, 'chapter_one', '0.1.0')
        self.assertFalse(result['ok'])
        self.assertFalse(self.output.exists())
        self.assertIn('source inputs changed', ' '.join(result['errors']).lower())

    def test_output_cannot_be_inside_exported_source_tree(self):
        inside = ROOT / 'scripts/.release-test-output'
        with mock.patch.object(release.exporter, 'build') as build_mock:
            result = release.build(self.engine, inside, 'chapter_one', '0.1.0')
        self.assertFalse(result['ok'])
        build_mock.assert_not_called()

    def test_release_smoke_uses_absolute_script_and_requires_test_report(self):
        package = self.root / 'smoke-package'
        package.mkdir()
        (package / 'MosslightRPG.pck').write_bytes(b'pck')
        test_script = self.root / 'content_release.gd'
        test_script.write_text('extends SceneTree\n', encoding='utf-8')
        log_dir = self.root / 'logs'
        log_dir.mkdir()
        observed = {}

        def fake_run(argv, cwd, destination, label, timeout):
            observed['argv'] = argv
            observed['cwd'] = Path(cwd)
            storage = Path(next(arg.split('=', 1)[1] for arg in argv if arg.startswith('--storage-root=')))
            (storage / 'release-smoke-report.json').write_text(
                json.dumps({'ok': True, 'checks': 3, 'failures': []}), encoding='utf-8')
            return {'returncode': 0, 'seconds': 0.01}

        with mock.patch.object(release, 'RELEASE_TEST', test_script), \
             mock.patch.object(release.exporter, 'run', side_effect=fake_run), \
             mock.patch.object(release.exporter, 'errors_in', return_value=[]):
            result = release.smoke_release(self.engine, package, log_dir)
        script_arg = observed['argv'][observed['argv'].index('--script') + 1]
        self.assertTrue(Path(script_arg).is_absolute())
        runtime_arg = Path(observed['argv'][observed['argv'].index('--path') + 1])
        self.assertEqual(observed['cwd'], runtime_arg)
        self.assertEqual(runtime_arg.name, 'release')
        self.assertEqual(Path(result['workspace']) / 'release', runtime_arg)
        self.assertEqual(result['runtime_report']['checks'], 3)

        def no_checks(argv, cwd, destination, label, timeout):
            storage = Path(next(arg.split('=', 1)[1] for arg in argv if arg.startswith('--storage-root=')))
            (storage / 'release-smoke-report.json').write_text(
                json.dumps({'ok': True, 'checks': 0, 'failures': []}), encoding='utf-8')
            return {'returncode': 0, 'seconds': 0.01}

        with mock.patch.object(release, 'RELEASE_TEST', test_script), \
             mock.patch.object(release.exporter, 'run', side_effect=no_checks), \
             mock.patch.object(release.exporter, 'errors_in', return_value=[]):
            with self.assertRaisesRegex(RuntimeError, 'smoke failed'):
                release.smoke_release(self.engine, package, log_dir)

    def test_failed_release_smoke_keeps_diagnostics_outside_target(self):
        with mock.patch.object(release.exporter, 'build', side_effect=self.fake_export), \
             mock.patch.object(release, 'smoke_release', side_effect=RuntimeError('simulated bootstrap failure')):
            result = release.build(self.engine, self.output, 'chapter_one', '0.1.0')
        self.assertFalse(result['ok'])
        self.assertFalse(self.output.exists())
        stage = Path(result['staging'])
        self.assertTrue((stage / 'release.json').is_file())
        self.assertTrue((stage / 'release-build-report.json').is_file())

    def test_release_id_and_semver_are_validated_before_build(self):
        for release_id, version in [('Upper', '0.1.0'), ('valid', '01.2.3'), ('valid', '1.2.3-01')]:
            with self.subTest(release_id=release_id, version=version):
                with mock.patch.object(release.exporter, 'build') as build_mock:
                    result = release.build(self.engine, self.output, release_id, version)
                self.assertFalse(result['ok'])
                build_mock.assert_not_called()


class NativeReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mosslight-native-unit-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.package = self.root / 'staged release'
        self.package.mkdir()
        for name, value in [('MosslightRPG.exe', b'debug exe'), ('MosslightRPG.pck', b'pack'),
                            ('source-manifest.json', b'{}')]:
            (self.package / name).write_bytes(value)
        self.manifest = {'release_id': 'chapter_one', 'content': {}}
        (self.package / 'release.json').write_text(json.dumps(self.manifest))
        self.count = 0

    def invoke(self, behavior='valid'):
        self.count += 1
        workspace = self.root / ('native-' + str(self.count))
        workspace.mkdir()
        log_dir = self.root / ('logs-' + str(self.count))
        log_dir.mkdir()
        captured = {}

        def fake_run(argv, cwd, destination, label, timeout, env=None):
            captured.update(argv=argv, cwd=Path(cwd), env=env, timeout=timeout)
            (destination / (label + '.stdout.log')).write_text('')
            (destination / (label + '.stderr.log')).write_text('')
            event = {'formal': True, 'identity': self.manifest['content'].get('identity', {})}
            if behavior == 'not-formal': event['formal'] = False
            if behavior == 'wrong-identity': event['identity'] = {'bundle_sha256': 'f' * 64}
            line = 'GAME_STARTUP ' + json.dumps(event) + '\n'
            if behavior == 'no-startup': line = 'Godot header only\n'
            if behavior == 'duplicate': line += line
            if behavior == 'malformed': line = 'GAME_STARTUP {broken\n'
            if behavior == 'engine-error': line += 'SCRIPT ERROR: smoke fixture failure\n'
            if behavior == 'refused': line += 'GAME_STARTUP_REFUSED fixture failure\n'
            if behavior == 'warning': line += 'WARNING: recorded diagnostic\n'
            log = Path(argv[argv.index('--log-file') + 1])
            if behavior == 'stdout-only':
                (destination / (label + '.stdout.log')).write_text(line)
            else: log.write_text(line)
            if behavior != 'no-storage':
                identity = self.manifest['content'].get('identity', {})
                (Path(env['APPDATA']) / 'Godot/app_userdata/Fixture/releases/chapter_one'
                 / identity.get('bundle_sha256', 'builtin')).mkdir(parents=True)
            if behavior == 'mutated-copy': Path(argv[0]).with_suffix('.pck').write_bytes(b'changed copy')
            if behavior == 'mutated-stage': (self.package / 'MosslightRPG.pck').write_bytes(b'changed stage')
            return {'argv': argv, 'cwd': str(cwd), 'returncode': 1 if behavior == 'nonzero' else 0}

        with mock.patch.object(release.tempfile, 'mkdtemp', return_value=str(workspace)), \
             mock.patch.object(release.exporter, 'run', side_effect=fake_run):
            result = release.smoke_native_release(self.package, log_dir)
        return result, captured

    def test_natural_native_launch_uses_foreign_cwd_and_child_only_profile(self):
        environment = dict(os.environ)
        result, seen = self.invoke()
        self.assertTrue(result['ok'])
        self.assertEqual(result['verification_scope'], 'local_headless_native_bootstrap')
        self.assertEqual(Path(seen['argv'][0]).name, 'MosslightRPG.exe')
        self.assertNotEqual(Path(seen['argv'][0]).parent, seen['cwd'])
        self.assertEqual(list(seen['cwd'].iterdir()), [])
        for forbidden in ['--script', '--path', '--main-pack', '--release-root', '--', '--sample']:
            self.assertNotIn(forbidden, seen['argv'])
        for key in ['APPDATA', 'LOCALAPPDATA', 'USERPROFILE', 'TEMP', 'TMP']:
            self.assertTrue(Path(seen['env'][key]).is_relative_to(self.root))
        self.assertEqual(dict(os.environ), environment)
        self.assertTrue(result['release_bytes_unchanged'])
        self.assertEqual(len(result['formal_directories']), 1)

    def test_valid_external_identity_and_actual_isolated_namespace_are_required(self):
        self.manifest['content'] = {'identity': {'bundle_sha256': 'a' * 64, 'format_version': 1}}
        (self.package / 'release.json').write_text(json.dumps(self.manifest))
        result, _seen = self.invoke()
        self.assertEqual(result['startup']['identity'], self.manifest['content']['identity'])
        self.assertEqual(Path(result['formal_directories'][0]).name, 'a' * 64)

    def test_false_success_signals_fail_closed(self):
        for behavior in ['nonzero', 'no-startup', 'duplicate', 'malformed', 'not-formal',
                         'wrong-identity', 'no-storage', 'engine-error', 'refused', 'mutated-copy', 'mutated-stage']:
            with self.subTest(behavior=behavior):
                with self.assertRaisesRegex(RuntimeError, 'Native release bootstrap smoke failed'):
                    self.invoke(behavior)

    def test_gui_stdout_fallback_is_checked_and_warnings_remain_visible(self):
        result, _seen = self.invoke('stdout-only')
        self.assertTrue(result['ok'])
        result, _seen = self.invoke('warning')
        self.assertTrue(result['ok'])
        self.assertEqual(result['warnings'], ['WARNING: recorded diagnostic'])

    def test_missing_runtime_member_prevents_any_process_launch(self):
        (self.package / 'MosslightRPG.exe').unlink()
        with mock.patch.object(release.exporter, 'run') as run_mock:
            with self.assertRaisesRegex(ValueError, 'missing its adjacent'):
                release.smoke_native_release(self.package, self.root)
        run_mock.assert_not_called()


if __name__ == '__main__':
    unittest.main()
