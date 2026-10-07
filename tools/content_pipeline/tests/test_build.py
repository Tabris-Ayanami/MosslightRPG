"""Build lifecycle regressions: actual inputs, failure isolation, repeatability."""
from __future__ import annotations

import hashlib
import io
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest import mock
from PIL import Image

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
from tools.content_pipeline import build as compiler


class ContentBuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mosslight-content-build-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copytree(ROOT / 'tools/content_pipeline/examples/trail_guard', self.root / 'source')
        self.pack = self.root / 'source/pack.json'
        self.output = self.root / 'bundle'

    def build(self):
        return compiler.build(ROOT, [self.pack], self.output)

    def test_reproducible_portable_payload_and_unchanged_sources(self):
        original = {path: path.read_bytes() for path in [self.pack, *(ROOT / 'data/combat').glob('*.json')]}
        first = self.build()
        self.assertTrue(first['ok'], first['errors'])
        second_dir = self.root / 'again'
        second = compiler.build(ROOT, [self.pack], second_dir)
        self.assertTrue(second['ok'], second['errors'])
        self.assertEqual(first['bundle_sha256'], second['bundle_sha256'])
        for file in self.output.rglob('*'):
            if file.is_file():
                self.assertEqual(file.read_bytes(), (second_dir / file.relative_to(self.output)).read_bytes())
        manifest = json.loads((self.output / 'bundle.json').read_text('utf-8'))
        receipt = json.loads((self.output / 'receipt.json').read_text('utf-8'))
        self.assertEqual(receipt['bundle_sha256'], hashlib.sha256((self.output / 'bundle.json').read_bytes()).hexdigest())
        self.assertEqual(manifest['catalogs_sha256'], hashlib.sha256((self.output / 'catalogs.json').read_bytes()).hexdigest())
        for metadata in manifest['assets'].values():
            raw = (self.output / metadata['path']).read_bytes()
            self.assertEqual(hashlib.sha256(raw).hexdigest(), metadata['sha256'])
            self.assertEqual(len(raw), metadata['bytes'])
        self.assertNotIn(str(self.root), (self.output / 'bundle.json').read_text('utf-8'))
        self.assertEqual(original, {path: path.read_bytes() for path in original})

    def test_existing_output_is_never_replaced(self):
        self.output.mkdir()
        sentinel = self.output / 'leave-me.txt'
        sentinel.write_text('old build', 'utf-8')
        self.assertFalse(self.build()['ok'])
        self.assertEqual(sentinel.read_text('utf-8'), 'old build')
        self.assertEqual(list(self.output.iterdir()), [sentinel])

    def test_pack_order_and_directory_names_do_not_change_build_identity(self):
        second_source = self.root / 'aaa_source'
        shutil.copytree(self.pack.parent, second_source)
        second_pack = second_source / 'pack.json'
        second_pack.write_text(second_pack.read_text('utf-8').replace('trail_guard', 'zz_guard'), 'utf-8')
        first = compiler.build(ROOT, [self.pack, second_pack], self.output)
        renamed = self.root / 'zzz_source'
        shutil.move(str(second_source), str(renamed))
        second = compiler.build(ROOT, [renamed / 'pack.json', self.pack], self.root / 'bundle2')
        self.assertTrue(first['ok'], first['errors'])
        self.assertTrue(second['ok'], second['errors'])
        self.assertEqual(first['bundle_sha256'], second['bundle_sha256'])

    def test_invalid_content_leaves_no_output(self):
        pack = json.loads(self.pack.read_text('utf-8'))
        pack['catalogs']['items']['trail_guard:herbal_draught']['resource'] = 'Unknown'
        self.pack.write_text(json.dumps(pack), 'utf-8')
        self.assertFalse(self.build()['ok'])
        self.assertFalse(self.output.exists())

    def test_runtime_rejecting_bindings_are_blocked_before_publication(self):
        original = json.loads(self.pack.read_text('utf-8'))
        for empty in (True, False):
            pack = json.loads(json.dumps(original))
            if empty:
                pack['bindings'][0]['assets'] = {}
            else:
                pack['bindings'].append(pack['bindings'][0])
            self.pack.write_text(json.dumps(pack), 'utf-8')
            result = self.build()
            self.assertFalse(result['ok'])
            self.assertEqual(result['errors'][-1]['code'], 'build.failed')
            self.assertFalse(self.output.exists())

    def test_valid_but_oversized_png_does_not_publish(self):
        image_path = self.pack.parent / 'assets/placeholder.png'
        Image.new('RGBA', (4096, 4096), '#65a18f').save(image_path)
        pack = json.loads(self.pack.read_text('utf-8'))
        pack['assets']['trail_guard:placeholder_icon'].update(width=4096, height=4096)
        self.pack.write_text(json.dumps(pack), 'utf-8')
        result = self.build()
        self.assertFalse(result['ok'])
        self.assertIn('dimensions', result['errors'][-1]['message'])
        self.assertFalse(self.output.exists())

    def test_small_encoded_files_can_exceed_decoded_memory_budget(self):
        image_path = self.pack.parent / 'assets/placeholder.png'
        Image.new('RGBA', (2048, 2048), '#65a18f').save(image_path)
        pack = json.loads(self.pack.read_text('utf-8'))
        metadata = pack['assets']['trail_guard:placeholder_icon']
        metadata.update(width=2048, height=2048, kind='texture')
        for binding in pack['bindings']:
            binding['assets'] = {'texture': 'trail_guard:placeholder_icon'}
        pack['assets']['trail_guard:second'] = dict(metadata)
        pack['assets']['trail_guard:third'] = dict(metadata)
        self.pack.write_text(json.dumps(pack), 'utf-8')
        result = self.build()
        self.assertFalse(result['ok'])
        self.assertIn('128 MiB', result['errors'][-1]['message'])
        self.assertFalse(self.output.exists())

    def test_png_header_only_is_not_a_decoded_image(self):
        image_path = self.pack.parent / 'assets/placeholder.png'
        image_path.write_bytes(image_path.read_bytes()[:33])
        result = self.build()
        self.assertFalse(result['ok'])
        self.assertFalse(self.output.exists())

    def test_large_icon_batch_keeps_original_pngs_with_bounded_display_budget(self):
        image_path = self.pack.parent / 'assets/placeholder.png'
        Image.new('RGBA', (1254, 1254), '#65a18f').save(image_path)
        original = image_path.read_bytes()
        pack = json.loads(self.pack.read_text('utf-8'))
        metadata = pack['assets']['trail_guard:placeholder_icon']
        metadata.update(width=1254, height=1254)
        for index in range(23):
            pack['assets'][f'trail_guard:icon_{index}'] = dict(metadata)
        self.pack.write_text(json.dumps(pack), 'utf-8')
        result = self.build()
        self.assertTrue(result['ok'], result['errors'])
        manifest = json.loads((self.output / 'bundle.json').read_text('utf-8'))
        self.assertEqual(len(manifest['assets']), 24)
        for asset in manifest['assets'].values():
            self.assertEqual((asset['width'], asset['height']), (1254, 1254))
            self.assertEqual((self.output / asset['path']).read_bytes(), original)
        self.assertEqual(image_path.read_bytes(), original)

    def test_icon_cache_budget_also_reserves_transient_full_source_decode(self):
        image_path = self.pack.parent / 'assets/placeholder.png'
        Image.new('RGBA', (2048, 2048), '#65a18f').save(image_path)
        pack = json.loads(self.pack.read_text('utf-8'))
        metadata = pack['assets']['trail_guard:placeholder_icon']
        metadata.update(width=2048, height=2048)
        # 22 cached 512-square icons alone fit; their full-source decode
        # workspace makes the combined estimate exceed 128 MiB.
        for index in range(21):
            pack['assets'][f'trail_guard:icon_{index}'] = dict(metadata)
        self.pack.write_text(json.dumps(pack), 'utf-8')
        result = self.build()
        self.assertFalse(result['ok'])
        self.assertIn('128 MiB', result['errors'][-1]['message'])
        self.assertFalse(self.output.exists())

    def test_narrow_mipmap_chains_cannot_hide_a_mixed_batch_over_budget(self):
        Image.new('RGBA', (1, 4096), '#65a18f').save(self.pack.parent / 'assets/tall.png')
        Image.new('RGBA', (1024, 1024), '#65a18f').save(self.pack.parent / 'assets/square.png')
        pack = json.loads(self.pack.read_text('utf-8'))
        for index in range(1604):
            narrow = index < 1600
            pack['assets'][f'trail_guard:portrait_{index}'] = {
                'kind': 'portrait', 'path': 'assets/tall.png' if narrow else 'assets/square.png',
                'width': 1 if narrow else 1024, 'height': 4096 if narrow else 1024,
            }
        # The previous base-pixels * 12 estimate accepted this valid batch.
        self.assertLess(1600 * 4096 * 12 + 4 * 1024 * 1024 * 12 + 12, compiler.MAX_IMAGE_MEMORY)
        self.assertEqual(compiler.cache_memory_bytes(1, 4096), 65528)
        self.assertEqual(compiler.cache_memory_bytes(4096, 1), 65528)
        self.assertEqual(compiler.cache_memory_bytes(512, 512), 512 * 512 * 12)
        self.pack.write_text(json.dumps(pack), 'utf-8')
        result = self.build()
        self.assertFalse(result['ok'])
        self.assertIn('128 MiB', result['errors'][-1]['message'])
        self.assertFalse(self.output.exists())

    def test_png_trailing_bytes_are_rejected_like_the_runtime(self):
        image_path = self.pack.parent / 'assets/placeholder.png'
        image_path.write_bytes(image_path.read_bytes() + b'x')
        result = self.build()
        self.assertFalse(result['ok'])
        self.assertIn('IEND', result['errors'][-1]['message'])
        self.assertFalse(self.output.exists())

    def test_source_overlap_and_empty_pack_list_are_refused(self):
        result = compiler.build(ROOT, [self.pack], self.pack.parent / 'build')
        self.assertFalse(result['ok'])
        self.assertFalse((self.pack.parent / 'build').exists())
        self.assertFalse(compiler.build(ROOT, [], self.output)['ok'])

    def test_concurrent_input_edit_leaves_no_partial_build(self):
        real_validate = compiler.validate
        def edit_after_validation(*args):
            result = real_validate(*args)
            self.pack.write_bytes(self.pack.read_bytes() + b'\n')
            return result
        with mock.patch.object(compiler, 'validate', side_effect=edit_after_validation):
            result = self.build()
        self.assertFalse(result['ok'])
        self.assertIn('changed during validation', result['errors'][-1]['message'])
        self.assertFalse(self.output.exists())

    def test_one_source_used_twice_cannot_hide_a_mid_validation_edit(self):
        image_path = (self.pack.parent / 'assets/placeholder.png').resolve()
        first = image_path.read_bytes()
        buffer = io.BytesIO()
        Image.new('RGBA', (1, 1), '#772233').save(buffer, format='PNG')
        later = buffer.getvalue()
        pack = json.loads(self.pack.read_text('utf-8'))
        metadata = pack['assets']['trail_guard:placeholder_icon']
        pack['assets']['trail_guard:second'] = dict(metadata)
        metadata['sha256'] = hashlib.sha256(first).hexdigest()
        self.pack.write_text(json.dumps(pack), 'utf-8')
        real_read = Path.read_bytes
        reads = [0]
        def changing_read(path):
            if path.resolve() == image_path:
                reads[0] += 1
                return first if reads[0] == 1 else later
            return real_read(path)
        with mock.patch.object(Path, 'read_bytes', changing_read):
            result = self.build()
        self.assertFalse(result['ok'])
        self.assertIn('input.changed', {issue['code'] for issue in result['errors']})
        self.assertFalse(self.output.exists())

    def test_failed_publish_cleans_its_temporary_directory_only(self):
        other = self.root / 'unrelated'
        other.mkdir()
        with mock.patch.object(compiler.os, 'rename', side_effect=OSError('simulated failure')):
            result = self.build()
        self.assertFalse(result['ok'])
        self.assertFalse(self.output.exists())
        self.assertTrue(other.exists())
        self.assertFalse(list(self.root.glob('.bundle-build-*')))


if __name__ == '__main__':
    unittest.main()
