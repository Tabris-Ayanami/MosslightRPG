"""Additive shop, quest and enemy-drop acquisition contract regressions."""
from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
from tools.content_pipeline import build as compiler
from tools.content_pipeline.schema import SCHEMA
from tools.content_pipeline.validate import validate

EXAMPLE = ROOT / 'tools/content_pipeline/examples/trail_guard'


class AcquisitionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mosslight-acquisition-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.project = self.root / 'project'
        (self.project / 'data').mkdir(parents=True)
        shutil.copytree(ROOT / 'data/combat', self.project / 'data/combat')
        (self.project / 'data/world').mkdir()
        for name in ('shops.json', 'quests.json'):
            shutil.copy2(ROOT / 'data/world' / name, self.project / 'data/world' / name)
        self.source = self.root / 'source'
        shutil.copytree(EXAMPLE, self.source)
        self.pack_path = self.source / 'pack.json'
        self.pack = json.loads(self.pack_path.read_text(encoding='utf-8'))
        self.output = self.root / 'bundle'

    def write_pack(self, pack=None):
        self.pack_path.write_text(json.dumps(self.pack if pack is None else pack, ensure_ascii=False), encoding='utf-8')

    def check(self, pack=None):
        self.write_pack(pack)
        return validate(self.project, [self.pack_path])

    def fails(self, code, pack=None):
        result = self.check(pack)
        self.assertFalse(result.report['ok'], result.report)
        self.assertIsNone(result.merged)
        self.assertIn(code, {issue['code'] for issue in result.report['errors']}, result.report['errors'])
        return result

    def valid_acquisition(self):
        return {
            'shops': {'village_supply': {
                'trail_guard:herbal_draught': {'stock': 2, 'buy_price': 40, 'sell_price': 8},
            }},
            'quests': {'village_patrol': {'trail_guard:herbal_draught': 2}},
            'enemy_drops': {'soldier': {'trail_guard:herbal_draught': 1}},
        }

    def add_items(self, pack, count):
        template = copy.deepcopy(pack['catalogs']['items']['trail_guard:herbal_draught'])
        for index in range(count):
            item_id = f'trail_guard:extra_{index:03d}'
            definition = copy.deepcopy(template)
            definition.update(id=item_id, name=f'测试物品 {index}')
            pack['catalogs']['items'][item_id] = definition
        return [f'trail_guard:extra_{index:03d}' for index in range(count)]

    def test_all_three_sources_merge_only_as_acquisition_and_fingerprint_world_inputs(self):
        result = self.check({**self.pack, 'acquisition': self.valid_acquisition()})
        self.assertTrue(result.report['ok'], result.report['errors'])
        acquisition = result.merged['acquisition']
        self.assertEqual(set(acquisition), {'format_version', 'world_base_sha256', 'shops', 'quests', 'enemy_drops'})
        self.assertEqual(acquisition['format_version'], 1)
        for name in ('shops', 'quests'):
            path = self.project / f'data/world/{name}.json'
            self.assertEqual(acquisition['world_base_sha256'][name], hashlib.sha256(path.read_bytes()).hexdigest())
            self.assertEqual(result.report['input_sha256'][str(path.resolve())], acquisition['world_base_sha256'][name])
        self.assertEqual(acquisition['shops']['village_supply']['trail_guard:herbal_draught'],
                         {'stock': 2, 'buy_price': 40, 'sell_price': 8})
        self.assertEqual(acquisition['quests']['village_patrol']['trail_guard:herbal_draught'], 2)
        self.assertEqual(acquisition['enemy_drops']['soldier']['trail_guard:herbal_draught'], 1)
        self.assertEqual(result.merged['catalogs']['progression']['soldier']['drops'], {'healing_potion': 1})

    def test_legacy_pack_schema_and_compiled_identity_remain_unchanged(self):
        self.assertNotIn('acquisition', self.pack)
        validated = validate(self.project, [self.pack_path])
        self.assertTrue(validated.report['ok'], validated.report['errors'])
        self.assertNotIn(str((self.project / 'data/world/shops.json').resolve()), validated.report['input_sha256'])
        self.assertNotIn(str((self.project / 'data/world/quests.json').resolve()), validated.report['input_sha256'])
        result = compiler.build(self.project, [self.pack_path], self.output)
        self.assertTrue(result['ok'], result['errors'])
        manifest_raw = (self.output / 'bundle.json').read_bytes()
        manifest = json.loads(manifest_raw)
        self.assertNotIn('acquisition', manifest)
        second = compiler.build(self.project, [self.pack_path], self.root / 'bundle-again')
        self.assertTrue(second['ok'], second['errors'])
        self.assertEqual(result['bundle_sha256'], second['bundle_sha256'])
        for path in self.output.rglob('*'):
            if path.is_file():
                self.assertEqual(path.read_bytes(), (self.root / 'bundle-again' / path.relative_to(self.output)).read_bytes())
        self.assertIn('acquisition', SCHEMA['properties'])

    def test_acquisition_pack_build_is_reproducible_and_keeps_drops_out_of_catalogs(self):
        self.pack['acquisition'] = self.valid_acquisition()
        self.write_pack()
        first = compiler.build(self.project, [self.pack_path], self.output)
        self.assertTrue(first['ok'], first['errors'])
        second = compiler.build(self.project, [self.pack_path], self.root / 'bundle-again')
        self.assertTrue(second['ok'], second['errors'])
        self.assertEqual(first['bundle_sha256'], second['bundle_sha256'])
        for path in self.output.rglob('*'):
            if path.is_file():
                self.assertEqual(path.read_bytes(), (self.root / 'bundle-again' / path.relative_to(self.output)).read_bytes())
        manifest = json.loads((self.output / 'bundle.json').read_text('utf-8'))
        catalogs = json.loads((self.output / 'catalogs.json').read_text('utf-8'))
        self.assertEqual(manifest['acquisition']['enemy_drops']['soldier'], {'trail_guard:herbal_draught': 1})
        self.assertEqual(catalogs['progression']['soldier']['drops'], {'healing_potion': 1})
        self.assertEqual(manifest['acquisition']['world_base_sha256']['shops'],
                         hashlib.sha256((self.project / 'data/world/shops.json').read_bytes()).hexdigest())

    def test_unknown_targets_and_non_owned_inventory_are_rejected(self):
        cases = [
            ('acquisition.shop_target', {'shops': {'not_a_shop': {'trail_guard:herbal_draught': {'stock': 1, 'buy_price': 2}}}}),
            ('acquisition.quest_target', {'quests': {'not_a_quest': {'trail_guard:herbal_draught': 1}}}),
            ('acquisition.enemy_target', {'enemy_drops': {'not_an_enemy': {'trail_guard:herbal_draught': 1}}}),
            ('acquisition.item_owner', {'quests': {'village_patrol': {'other_pack:healing_potion': 1}}}),
        ]
        for code, acquisition in cases:
            with self.subTest(code=code):
                self.fails(code, {**self.pack, 'acquisition': acquisition})

    def test_replacement_collisions_are_rejected_for_each_target_type(self):
        shops_path = self.project / 'data/world/shops.json'
        quests_path = self.project / 'data/world/quests.json'
        shops = json.loads(shops_path.read_text(encoding='utf-8'))
        shops['village_supply']['goods']['trail_guard:herbal_draught'] = {'stock': 1, 'buy_price': 50}
        shops_path.write_text(json.dumps(shops), encoding='utf-8')
        quests = json.loads(quests_path.read_text(encoding='utf-8'))
        quests['village_patrol']['rewards']['items']['trail_guard:herbal_draught'] = 1
        quests_path.write_text(json.dumps(quests), encoding='utf-8')
        progression_path = self.project / 'data/combat/progression.json'
        progression = json.loads(progression_path.read_text(encoding='utf-8'))
        progression['soldier']['drops']['trail_guard:herbal_draught'] = 1
        progression_path.write_text(json.dumps(progression), encoding='utf-8')
        cases = [
            ('acquisition.shop_collision', {'shops': {'village_supply': {'trail_guard:herbal_draught': {'stock': 1, 'buy_price': 50}}}}),
            ('acquisition.quest_collision', {'quests': {'village_patrol': {'trail_guard:herbal_draught': 1}}}),
            ('acquisition.drop_collision', {'enemy_drops': {'soldier': {'trail_guard:herbal_draught': 1}}}),
        ]
        for code, acquisition in cases:
            with self.subTest(code=code):
                self.fails(code, {**self.pack, 'acquisition': acquisition})

    def test_prices_stock_and_quantities_are_bounded(self):
        cases = [
            ({'shops': {'village_supply': {'trail_guard:herbal_draught': {'stock': 1, 'buy_price': 0}}}}, 'schema.minimum'),
            ({'shops': {'village_supply': {'trail_guard:herbal_draught': {'stock': 1000001, 'sell_price': 2}}}}, 'schema.maximum'),
            ({'shops': {'village_supply': {'trail_guard:herbal_draught': {'stock': 1, 'buy_price': 2147483648}}}}, 'schema.maximum'),
            ({'shops': {'village_supply': {'trail_guard:herbal_draught': {'stock': 1, 'sell_price': 2, 'unexpected': 1}}}}, 'schema.additionalProperties'),
            ({'quests': {'village_patrol': {'trail_guard:herbal_draught': 0}}, 'enemy_drops': {}}, 'schema.minimum'),
            ({'enemy_drops': {'soldier': {'trail_guard:herbal_draught': 1000001}}}, 'schema.maximum'),
            ({'shops': {'village_supply': {'trail_guard:herbal_draught': {'stock': 1, 'sell_price': 2}}}}, 'acquisition.shop_value'),
        ]
        for acquisition, code in cases:
            with self.subTest(acquisition=acquisition):
                self.fails(code, {**self.pack, 'acquisition': acquisition})

    def test_integral_json_floats_are_accepted_normalized_and_booleans_rejected(self):
        pack = {**self.pack, 'acquisition': {
            'shops': {'village_supply': {
                'trail_guard:herbal_draught': {'stock': 2.0, 'buy_price': 40.0, 'sell_price': 8.0},
            }},
            'quests': {'village_patrol': {'trail_guard:herbal_draught': 2.0}},
            'enemy_drops': {'soldier': {'trail_guard:herbal_draught': 1.0}},
        }}
        result = self.check(pack)
        self.assertTrue(result.report['ok'], result.report['errors'])
        acquisition = result.merged['acquisition']
        self.assertEqual(acquisition['shops']['village_supply']['trail_guard:herbal_draught'],
                         {'stock': 2, 'buy_price': 40, 'sell_price': 8})
        self.assertIs(type(acquisition['shops']['village_supply']['trail_guard:herbal_draught']['stock']), int)
        self.assertIs(type(acquisition['quests']['village_patrol']['trail_guard:herbal_draught']), int)
        self.assertIs(type(acquisition['enemy_drops']['soldier']['trail_guard:herbal_draught']), int)
        built = compiler.build(self.project, [self.pack_path], self.output)
        self.assertTrue(built['ok'], built['errors'])
        manifest = json.loads((self.output / 'bundle.json').read_text('utf-8'))
        compiled_goods = manifest['acquisition']['shops']['village_supply']['trail_guard:herbal_draught']
        self.assertEqual(compiled_goods, {'stock': 2, 'buy_price': 40, 'sell_price': 8})
        self.assertIs(type(compiled_goods['stock']), int)

        for bad in (1.5, True):
            with self.subTest(bad=bad):
                invalid = {**self.pack, 'acquisition': {
                    'quests': {'village_patrol': {'trail_guard:herbal_draught': bad}},
                }}
                self.assertFalse(self.check(invalid).report['ok'])

    def test_source_schema_requires_nonempty_known_acquisition_categories(self):
        self.fails('schema.minProperties', {**self.pack, 'acquisition': {}})
        self.fails('schema.additionalProperties', {**self.pack, 'acquisition': {'shops': {}, 'rewards': {}}})
        too_long = 'q' * 97
        self.fails('schema.maxLength', {**self.pack, 'acquisition': {'quests': {too_long: {'trail_guard:herbal_draught': 1}}}})
        too_long_item = 'trail_guard:' + ('x' * 85)
        self.fails('schema.maxLength', {**self.pack, 'acquisition': {'quests': {'village_patrol': {too_long_item: 1}}}})
        result = self.check({**self.pack, 'acquisition': {'quests': {'village_patrol': {'trail_guard:herbal_draught': 1}}}})
        self.assertTrue(result.report['ok'], result.report['errors'])

    def test_cross_shop_arbitrage_is_rejected(self):
        shops_path = self.project / 'data/world/shops.json'
        shops = json.loads(shops_path.read_text(encoding='utf-8'))
        shops['other_supply'] = {
            'id': 'other_supply', 'name': '另一家店', 'description': '用于契约测试。',
            'currency': 'coin', 'catalog_version': 1,
            'goods': {'healing_potion': {'sell_price': 5, 'stock': 0}},
        }
        shops_path.write_text(json.dumps(shops), encoding='utf-8')
        acquisition = {'shops': {
            'village_supply': {'trail_guard:herbal_draught': {'stock': 0, 'sell_price': 30}},
            'other_supply': {'trail_guard:herbal_draught': {'stock': 1, 'buy_price': 20}},
        }}
        self.fails('acquisition.shop_arbitrage', {**self.pack, 'acquisition': acquisition})

    def test_merged_runtime_capacity_limits_are_enforced(self):
        pack = copy.deepcopy(self.pack)
        ids = self.add_items(pack, 102)
        pack['acquisition'] = {'shops': {'village_supply': {
            item_id: {'stock': 1, 'buy_price': 10} for item_id in ids
        }}}
        self.fails('acquisition.shop_capacity', pack)

        pack = copy.deepcopy(self.pack)
        ids = self.add_items(pack, 31)
        pack['acquisition'] = {'quests': {'village_patrol': {item_id: 1 for item_id in ids}}}
        self.fails('acquisition.quest_capacity', pack)

        pack = copy.deepcopy(self.pack)
        ids = self.add_items(pack, 32)
        pack['acquisition'] = {'enemy_drops': {'soldier': {item_id: 1 for item_id in ids}}}
        self.fails('acquisition.drop_capacity', pack)

    def test_world_json_is_frozen_and_concurrent_change_prevents_bundle_publication(self):
        self.pack['acquisition'] = self.valid_acquisition()
        self.write_pack()
        real_validate = compiler.validate

        def edit_after_validation(*args):
            result = real_validate(*args)
            path = self.project / 'data/world/shops.json'
            path.write_bytes(path.read_bytes() + b'\n')
            return result

        with mock.patch.object(compiler, 'validate', side_effect=edit_after_validation):
            result = compiler.build(self.project, [self.pack_path], self.output)
        self.assertFalse(result['ok'])
        self.assertFalse(self.output.exists())
        self.assertTrue(any('Input changed' in issue['message'] for issue in result['errors']))


if __name__ == '__main__':
    unittest.main()
