"""Contract regressions using actual base catalogs and independent draft packs."""
from __future__ import annotations

import copy
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
from tools.content_pipeline.schema import (CATALOGS, DEFAULT_ENEMY_FACTION, DEFAULT_ENEMY_LEVEL,
    DEFAULT_ENEMY_RACE, FACTION_IDS, RACE_IDS, RESOURCES, RESOURCE_MODEL, RESOURCE_COST_MODIFIERS, SCHEMA)
from tools.content_pipeline.validate import safe_formula, validate

PIPELINE = ROOT / 'tools/content_pipeline'
EXAMPLE = PIPELINE / 'examples/trail_guard'


class ContentPipelineTests(unittest.TestCase):
    def setUp(self):
        workspace = (PIPELINE / '.test-work').resolve()
        workspace.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=workspace)
        self.path = Path(self.temp.name).resolve()
        assert self.path.is_relative_to(workspace)
        self.addCleanup(self.temp.cleanup)
        shutil.copytree(EXAMPLE, self.path / 'pack')
        self.pack_file = self.path / 'pack/pack.json'
        self.pack = json.loads(self.pack_file.read_text(encoding='utf-8'))

    def check(self, pack=None, project=ROOT):
        self.pack_file.write_text(json.dumps(self.pack if pack is None else pack, ensure_ascii=False), encoding='utf-8')
        return validate(project, [self.pack_file])

    def fails(self, code, pack=None, project=ROOT):
        result = self.check(pack, project)
        self.assertFalse(result.report['ok'])
        self.assertIsNone(result.merged, 'Failed input must not expose a merge for installation')
        self.assertIn(code, {x['code'] for x in result.report['errors']}, result.report['errors'])
        return result

    def test_base_catalogs_validate_without_count_assumptions(self):
        result = validate(ROOT)
        self.assertTrue(result.report['ok'], result.report['errors'])
        self.assertEqual(set(result.report['counts']), set(CATALOGS))
        self.assertEqual(len(result.report['input_sha256']), len(CATALOGS))

    def test_spell_rank_must_match_actual_energy_cost(self):
        skill = self.pack['catalogs']['skills']['trail_guard:guard_cut']
        skill['spell_rank'] = 2
        skill['costs'] = {'Energy': 19}
        self.fails('action.spell_cost')
        skill['costs']['Energy'] = 20
        self.assertTrue(self.check().report['ok'])
        skill['spell_rank'] = 0
        skill['costs'] = {}
        self.assertTrue(self.check().report['ok'])
        skill['spell_rank'] = 3
        skill['costs'] = {'Energy': 30}
        self.fails('action.spell_cost')
        skill['costs']['Energy'] = 35
        self.assertTrue(self.check().report['ok'])

    def test_bounded_stat_bonus_formula_subset(self):
        self.assertEqual(safe_formula('floor(max(0, CON - 10) / 4)', {'CON': 9}), 0)
        self.assertEqual(safe_formula('floor(max(0, CON - 10) / 4)', {'CON': 18}), 2)
        self.assertEqual(safe_formula('min(5, level)', {'level': 10}), 5)
        for expression in ('max(1)', 'min(1, 2, 3)', 'max(x=1, y=2)'):
            with self.assertRaises(ValueError): safe_formula(expression, {})

    def test_nonlinear_resources_preserve_old_capacity_and_widen_late_gap(self):
        careers = json.loads((ROOT / 'data/combat/careers.json').read_text(encoding='utf-8'))
        old_stamina = {'warrior':'3 + floor((CON - 10) / 5)', 'rogue':'3 + floor((DEX - 10) / 5)',
                       'barbarian':'3 + floor((CON - 10) / 4)', 'mage':'2 + floor((DEX - 10) / 6)'}
        old_energy = {'warrior':'20 * (2 + floor((STR + CON - 20) / 6) + floor((level - 1) / 2))',
                      'rogue':'20 * (2 + floor((DEX + PER - 20) / 6) + floor((level - 1) / 2))',
                      'barbarian':'20 * (2 + floor((STR + CON - 20) / 4) + floor((level - 1) / 2))',
                      'mage':'20 * (2 + floor((INT - 10) / 3) + floor((level - 1) / 2))'}
        for key in old_stamina:
            for stat in ('STR', 'DEX', 'CON', 'INT', 'PER'):
                for score in (1, 7, 9, 10, 14, 18, 22, 30):
                    previous = {'Stamina':0, 'Energy':-1000}
                    for level in range(1, 11):
                        values = {**careers[key]['stats'], stat:score, 'level':level}
                        for resource, legacy in (('Stamina',old_stamina), ('Energy',old_energy)):
                            actual = safe_formula(careers[key]['formulas'][resource], values)
                            self.assertGreaterEqual(actual + 1e-6, safe_formula(legacy[key], values))
                            self.assertGreaterEqual(actual + 1e-6, previous[resource])
                            previous[resource] = actual
        gaps = []
        for level in (3, 5, 7, 10):
            gaps.append(safe_formula(careers['mage']['formulas']['Energy'], {**careers['mage']['stats'], 'level':level}) -
                        safe_formula(careers['warrior']['formulas']['Energy'], {**careers['warrior']['stats'], 'level':level}))
        self.assertEqual(gaps, [0, 20, 50, 110])

    def test_pack_all_six_families_and_explicit_grants_merge_without_writes(self):
        before = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in (ROOT / 'data/combat').glob('*.json')}
        result = self.check()
        self.assertTrue(result.report['ok'], result.report['errors'])
        self.assertIn('trail_guard:guard_cut', result.merged['catalogs']['careers']['warrior']['skills'])
        self.assertIn('trail_guard:warden', result.merged['catalogs']['careers']['warrior']['next_careers'])
        self.assertEqual(result.merged['assets']['trail_guard:placeholder_icon']['kind'], 'icon')
        self.assertEqual(len(result.merged['bindings']), 2)
        self.assertEqual(before, {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in before})
        base_again = validate(ROOT)
        self.assertNotIn('trail_guard:guard_cut', base_again.merged['catalogs']['careers']['warrior']['skills'])

    def test_unknown_effect_and_unknown_field_fail_closed(self):
        skill = self.pack['catalogs']['skills']['trail_guard:guard_cut']
        skill['effects'] = [{'type': 'summon', 'creature': 'dragon'}]
        self.fails('schema.oneOf')
        skill['effects'] = []
        skill['on_hit_script'] = 'danger.gd'
        self.fails('schema.additionalProperties')

    def test_effect_valid_elsewhere_but_not_action_is_rejected(self):
        self.pack['catalogs']['skills']['trail_guard:guard_cut']['effects'] = [{'type': 'forced_crit', 'value': True}]
        self.fails('effect.unsupported_context')

    def test_wrong_modifier_event_is_rejected(self):
        self.pack['catalogs']['passives']['trail_guard:steady_breath']['effects'] = [{'type': 'modifier', 'stat': 'crit_chance', 'value': 0.1}]
        self.fails('effect.modifier_event')

    def test_missing_status_and_passive_references(self):
        self.pack['catalogs']['skills']['trail_guard:guard_cut']['effects'][0]['status'] = 'nonexistent'
        self.pack['catalogs']['weapons']['trail_guard:watch_sword']['special_effects'] = ['unknown_passive']
        result = self.fails('reference.missing')
        self.assertGreaterEqual(len(result.report['errors']), 2)

    def test_invalid_condition_type_and_operator(self):
        condition = self.pack['catalogs']['skills']['trail_guard:guard_cut']['conditions'][0]
        condition['type'] = 'moon_phase'
        self.fails('schema.enum')
        condition.update(type='weapon_family', value='SINGLE_BLADE', op='in')
        self.fails('condition.operator')

    def test_unknown_targeting_and_resource(self):
        skill = self.pack['catalogs']['skills']['trail_guard:guard_cut']
        skill['targeting'] = 'EVERYWHERE'
        self.fails('schema.enum')
        skill['targeting'] = 'CONE'
        skill['costs'] = {'Mana': 1}
        self.fails('schema.additionalProperties')

    def test_resource_contract_matches_current_runtime_and_report(self):
        source = (ROOT / 'combat/resource_component.gd').read_text(encoding='utf-8')
        ids = re.search(r'const IDS := \[([^\]]+)\]', source)
        self.assertIsNotNone(ids)
        self.assertEqual(tuple(re.findall(r'"([A-Za-z]+)"', ids[1])), RESOURCES)
        result = self.check()
        self.assertTrue(result.report['ok'], result.report['errors'])
        self.assertEqual(result.report['resource_model'], RESOURCE_MODEL)
        self.assertEqual(result.report['resources'], list(RESOURCES))

    def test_energy_is_continuous_in_direct_runtime_units(self):
        skill = self.pack['catalogs']['skills']['trail_guard:guard_cut']
        skill['costs'] = {'Energy': 20.5, 'Stamina': .25}
        skill['gains'] = {'Energy': .5}
        skill['conditions'] = [{'type': 'resource', 'resource': 'Energy', 'op': '>=', 'value': 20.5}]
        skill['effects'] = [{'type': 'resource', 'resource': 'Energy', 'amount': -1.75}]
        passive = self.pack['catalogs']['passives']['trail_guard:steady_breath']
        passive['effects'] = [{'type': 'resource', 'resource': 'Energy', 'value': 2.25}]
        item = self.pack['catalogs']['items']['trail_guard:herbal_draught']
        item.update(resource='Energy', amount=2.5, fraction=.125)
        result = self.check()
        self.assertTrue(result.report['ok'], result.report['errors'])
        self.assertEqual(result.merged['catalogs']['skills'][skill['id']], skill)
        self.assertEqual(result.merged['catalogs']['passives'][passive['id']], passive)
        self.assertEqual(result.merged['catalogs']['items'][item['id']], item)

    def test_legacy_resources_are_rejected_without_pack_migration(self):
        original = copy.deepcopy(self.pack)
        for legacy in ('Qi', 'SpellSlot'):
            for location in ('costs', 'gains', 'condition', 'effect', 'item', 'formula'):
                with self.subTest(legacy=legacy, location=location):
                    pack = copy.deepcopy(original)
                    skill = pack['catalogs']['skills']['trail_guard:guard_cut']
                    if location in ('costs', 'gains'):
                        skill[location] = {legacy: 1}
                    elif location == 'condition':
                        skill['conditions'] = [{'type': 'resource', 'resource': legacy, 'value': 1}]
                    elif location == 'effect':
                        skill['effects'] = [{'type': 'resource', 'resource': legacy, 'amount': 1}]
                    elif location == 'item':
                        pack['catalogs']['items']['trail_guard:herbal_draught']['resource'] = legacy
                    else:
                        pack['catalogs']['careers']['trail_guard:warden']['formulas'] = {legacy: '2'}
                    before = copy.deepcopy(pack)
                    result = self.check(pack)
                    self.assertFalse(result.report['ok'])
                    self.assertIsNone(result.merged)
                    self.assertEqual(pack, before, 'Rejected legacy units must not be silently renamed or scaled')

    def test_energy_cost_modifiers_match_consumed_passive_event(self):
        controller = (ROOT / 'combat/combat_controller.gd').read_text(encoding='utf-8')
        costs_for = controller.split('func costs_for(', 1)[1].split('\nfunc ', 1)[0]
        self.assertIn('passives.actor_modifiers("stat_update"', costs_for)
        self.assertIn('"_cost_override"', costs_for)
        self.assertIn('mods.has("weapon_energy_cost_override")', costs_for)
        passive = self.pack['catalogs']['passives']['trail_guard:steady_breath']
        passive['event'] = 'stat_update'
        for stat in RESOURCE_COST_MODIFIERS:
            with self.subTest(stat=stat):
                passive['effects'] = [{'type': 'modifier', 'stat': stat, 'value': 0.5}]
                result = self.check()
                self.assertTrue(result.report['ok'], result.report['errors'])
                passive['event'] = 'damage_before'
                self.fails('effect.modifier_event')
                passive['event'] = 'stat_update'
                passive['effects'][0]['value'] = -1
                self.fails('effect.resource_override')
        for legacy in ('qi_cost_override', 'spellslot_cost_override', 'weapon_qi_cost_override'):
            passive['effects'] = [{'type': 'modifier', 'stat': legacy, 'value': 0}]
            self.fails('schema.oneOf')

    def test_resource_effect_cannot_hide_ignored_amount_alias(self):
        effect = self.pack['catalogs']['passives']['trail_guard:steady_breath']['effects'][0]
        effect.update(amount=20, value=40)
        self.fails('effect.amount_alias')

    def test_collision_and_namespace(self):
        item = self.pack['catalogs']['items'].pop('trail_guard:herbal_draught')
        item['id'] = 'healing_potion'
        self.pack['catalogs']['items']['healing_potion'] = item
        result = self.fails('id.collision')
        self.assertIn('id.namespace', {x['code'] for x in result.report['errors']})

    def test_mismatched_id(self):
        self.pack['catalogs']['items']['trail_guard:herbal_draught']['id'] = 'trail_guard:other'
        self.fails('id.mismatch')

    def test_duplicate_pack_version_rejected(self):
        result = validate(ROOT, [self.pack_file, self.pack_file])
        self.assertFalse(result.report['ok'])
        self.assertIn('pack.duplicate', {x['code'] for x in result.report['errors']})

    def test_empty_resource_item_and_boolean_numbers(self):
        item = self.pack['catalogs']['items']['trail_guard:herbal_draught']
        item.pop('fraction')
        item.pop('amount')
        self.fails('item.resource')
        item['amount'] = True
        self.fails('schema.type')

    def test_unimplemented_mechanic_field_fails(self):
        skill = self.pack['catalogs']['skills']['trail_guard:guard_cut']
        skill['effects'] = [{'type': 'teleport', 'distance': 3, 'target': 'self', 'invulnerable': False}]
        self.fails('effect.metadata_only')

    def test_inheritance_cycle_and_missing_advancement_link(self):
        self.pack['career_links'] = []
        self.fails('career.parent_link')
        career = self.pack['catalogs']['careers']['trail_guard:warden']
        career['parent_career'] = 'trail_guard:warden'
        career['next_careers'] = ['trail_guard:warden']
        self.fails('career.cycle')

    def test_foreign_grant_cannot_rewrite_base(self):
        self.pack['career_grants'] = [{'career': 'mage', 'skills': ['warrior_whirlwind']}]
        self.fails('grant.owner')

    def test_unsafe_formula_ast_never_executes(self):
        for expression in ('__import__("os").system("echo bad")', '(1).__class__', '2 ** 100000', 'floor(x=2)', 'STR[0]', 'True', '1_000', '0xFF', '1 # comment', '+1', '2 + +3'):
            with self.subTest(expression=expression), self.assertRaises((ValueError, SyntaxError)):
                safe_formula(expression, {'STR': 13, 'level': 1})
        self.assertEqual(safe_formula('2 + floor((STR - 10) / 3)', {'STR': 13, 'level': 1}), 3)
        with self.assertRaises(ZeroDivisionError):
            safe_formula('1 / (level - 2)', {'level': 2})

    def test_numeric_resource_formulas_and_zero_energy(self):
        career = copy.deepcopy(json.loads((ROOT / 'data/combat/careers.json').read_text(encoding='utf-8'))['warrior'])
        career.update(id='trail_guard:base', base_career='trail_guard:base', next_careers=[])
        career['formulas'] = {'HP': 120, 'Stamina': 3.5, 'Energy': 0, 'Poise': 50}
        self.pack['catalogs']['careers'][career['id']] = career
        result = self.check()
        self.assertTrue(result.report['ok'], result.report['errors'])
        self.assertEqual(result.merged['catalogs']['careers'][career['id']]['formulas'], career['formulas'])
        for bad in (True, -1, 1000001):
            with self.subTest(bad=bad):
                career['formulas']['Energy'] = bad
                self.fails('schema.anyOf')
        career['formulas']['Energy'] = .5
        career['formulas']['HP'] = 0
        self.fails('career.formula')

    def test_formula_types_match_runtime_arithmetic(self):
        variables = {'STR': 13, 'level': 3}
        cases = {'1 / 2': 0, '-3 / 2': -1, '3 / -2': -1,
                 '1.0 / 2': .5, '3e0 / 2': 1.5, 'level / 2': 1,
                 'STR / 2': 6.5, '(STR - 10) / 2': 1.5,
                 'floor(3.5) / 2': 1.5, 'floor(3) / 2': 1,
                 'floor(-3.5) / 3': -4 / 3, 'floor(level / 2) / 2': 0}
        for expression, expected in cases.items():
            with self.subTest(expression=expression):
                self.assertAlmostEqual(safe_formula(expression, variables), expected)
        self.assertEqual(safe_formula(20.5, variables), 20.5)
        for bad in (True, None, [], float('inf')):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                safe_formula(bad, variables)

    def test_formula_runtime_zero_is_rejected_even_if_python_division_would_pass(self):
        career = copy.deepcopy(json.loads((ROOT / 'data/combat/careers.json').read_text(encoding='utf-8'))['warrior'])
        career.update(id='trail_guard:base', base_career='trail_guard:base', next_careers=[])
        career['formulas']['HP'] = '1 / 2'
        self.pack['catalogs']['careers'][career['id']] = career
        self.fails('career.formula')

    def test_formula_subset_matches_godot_expression_when_available(self):
        # Optional parity gate only. The offline validator never starts Godot.
        executable = os.environ.get('MOSS_CONTENT_GODOT') or shutil.which('godot') or shutil.which('godot4')
        if not executable:
            self.skipTest('Set MOSS_CONTENT_GODOT to run the isolated engine parity check')
        project = self.path / 'expression-probe'
        project.mkdir()
        (project / 'project.godot').write_text('[application]\nconfig/name="ContentFormulaProbe"\n', encoding='utf-8')
        expressions = ['1 / 2', '-3 / 2', '3 / -2', '1.0 / 2', '3e0 / 2', 'level / 2',
                       'STR / 2', '(STR - 10) / 2', 'floor(3.5) / 2', 'floor(3) / 2',
                       'floor(-3.5) / 3', 'floor(level / 2) / 2',
                       'max(1, 2) / 2', 'max(0, STR - 10) / 2', 'min(4, level) / 2',
                       'floor(0.05 * (level - 1) * (level - 1) + 0.4 * (level - 1))',
                       '20 * (2 + floor((STR - 10) / 6) + floor((level - 1) / 2))']
        (project / 'input.json').write_text(json.dumps(expressions), encoding='utf-8')
        (project / 'probe.gd').write_text('''extends SceneTree
func _initialize() -> void:
    var expressions = JSON.parse_string(FileAccess.get_file_as_string("res://input.json"))
    var results: Array = []
    for text in expressions:
        var expression := Expression.new()
        if expression.parse(text, PackedStringArray(["STR", "level"])) != OK:
            quit(2)
            return
        var value = expression.execute([13.0, 3], null, false)
        if expression.has_execute_failed():
            quit(3)
            return
        results.append(value)
    print("FORMULA_PARITY=" + JSON.stringify(results))
    quit(0)
''', encoding='utf-8')
        isolated_env = os.environ.copy()
        # Windows and Unix data roots all stay inside this disposable fixture.
        for key in ('APPDATA', 'LOCALAPPDATA', 'XDG_DATA_HOME', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME'):
            path = project / key.lower()
            path.mkdir()
            isolated_env[key] = str(path)
        result = subprocess.run([str(executable), '--headless', '--path', str(project),
                                 '--log-file', str(project / 'godot.log'), '--script', 'res://probe.gd'],
                                capture_output=True, encoding='utf-8', timeout=30, env=isolated_env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        output = next(line.removeprefix('FORMULA_PARITY=') for line in result.stdout.splitlines() if line.startswith('FORMULA_PARITY='))
        for expression, expected in zip(expressions, json.loads(output), strict=True):
            with self.subTest(expression=expression):
                self.assertAlmostEqual(safe_formula(expression, {'STR': 13, 'level': 3}), expected)

    def test_formula_failure_at_intermediate_level_is_reported(self):
        base = json.loads((ROOT / 'data/combat/careers.json').read_text(encoding='utf-8'))['warrior']
        career = copy.deepcopy(base)
        career.update(id='trail_guard:base', base_career='trail_guard:base', next_careers=[])
        career['formulas']['HP'] = '100 / ((level - 5) * (level - 5))'
        self.pack['catalogs']['careers']['trail_guard:base'] = career
        self.fails('career.formula')

    def test_asset_paths_cannot_escape_or_execute(self):
        asset = self.pack['assets']['trail_guard:placeholder_icon']
        for bad in ('../outside.png', 'C:/outside.png', 'https://example.org/x.png', '/absolute.png', 'assets\\x.png', 'assets//placeholder.png', 'assets/./placeholder.png'):
            with self.subTest(path=bad):
                asset['path'] = bad
                self.fails('asset.path')
        asset['path'] = 'assets/run.gd'
        self.fails('asset.extension')

    def test_asset_missing_hash_and_dimensions(self):
        asset = self.pack['assets']['trail_guard:placeholder_icon']
        asset['width'] = 32
        self.fails('asset.invalid')
        asset['width'] = 1
        asset['sha256'] = '0' * 64
        self.fails('asset.invalid')
        asset.pop('sha256')
        asset['path'] = 'missing.png'
        self.fails('asset.invalid')

    def test_asset_binding_kind_and_owner(self):
        self.pack['bindings'][0]['assets'] = {'model': 'trail_guard:placeholder_icon'}
        self.fails('binding.kind')
        self.pack['bindings'][0]['id'] = 'healing_potion'
        self.fails('binding.owner')

    def test_duplicate_json_keys_and_nonfinite_input(self):
        for text in ('{"pack_id":"a","pack_id":"b"}', '{"value":NaN}', '{"value":1e999}'):
            self.pack_file.write_text(text, encoding='utf-8')
            result = validate(ROOT, [self.pack_file])
            self.assertIn('json.invalid', {x['code'] for x in result.report['errors']})

    def test_base_missing_reference_is_detected(self):
        project = self.path / 'project'
        shutil.copytree(ROOT / 'data/combat', project / 'data/combat')
        path = project / 'data/combat/equipment.json'
        data = json.loads(path.read_text(encoding='utf-8'))
        data['scout_hood']['passives'] = ['missing_passive']
        path.write_text(json.dumps(data), encoding='utf-8')
        result = validate(project)
        self.assertFalse(result.report['ok'])
        self.assertIn('reference.missing', {x['code'] for x in result.report['errors']})

    def test_schema_document_is_current_and_valid(self):
        Draft202012Validator.check_schema(SCHEMA)
        self.assertEqual(SCHEMA, json.loads((PIPELINE / 'schemas/content-pack-v1.schema.json').read_text(encoding='utf-8')))

    def test_unit_identity_table_matches_reviewed_runtime_literals(self):
        # Read narrowly located JSON-compatible constant/string literals only.
        # A refactor outside this grammar asks for review; no source is evaluated.
        source = (ROOT / 'rpg/race_catalog.gd').read_text(encoding='utf-8')
        ids = re.search(r'^const IDS := (\[[^\r\n]*\])\s*$', source, re.MULTILINE)
        self.assertIsNotNone(ids, 'Review capability table after race constant syntax changes')
        self.assertEqual(tuple(json.loads(ids.group(1))), RACE_IDS)
        names = re.search(r'^const NAMES := \{\s*\n(.*?)^\}', source, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(names)
        keys = []
        for line in names.group(1).splitlines():
            if not line.strip():
                continue
            entry = re.fullmatch(r'\s*("[a-z_]+"):\s*"[^"\r\n]+",?\s*', line)
            self.assertIsNotNone(entry, 'Review race names grammar before extending parser')
            keys.append(json.loads(entry.group(1)))
        self.assertEqual(set(keys), set(RACE_IDS), 'RaceCatalog.is_valid uses NAMES, not only IDS')
        default = re.search(r'^const DEFAULT_ID := ("[a-z_]+")\s*$', source, re.MULTILINE)
        self.assertIsNotNone(default)
        self.assertEqual(json.loads(default.group(1)), DEFAULT_ENEMY_RACE)
        units = (ROOT / 'combat/unit_definition.gd').read_text(encoding='utf-8')
        self.assertIn('data.get("race_id", Races.DEFAULT_ID)', units)
        self.assertIn('data.get("faction_id", "' + DEFAULT_ENEMY_FACTION + '")', units)
        self.assertIn('data.get("level", ' + str(DEFAULT_ENEMY_LEVEL) + ')', units)
        world = (ROOT / 'combat/combat_world.gd').read_text(encoding='utf-8')
        sides = re.findall(r'(?:source|other)\.faction_id in (\[[^\]\r\n]*\])', world)
        self.assertEqual(len(sides), 2, 'Review faction capability table when default relationship changes')
        for side in sides:
            self.assertEqual(tuple(json.loads(side)), FACTION_IDS)

    def enemy_project(self):
        project = self.path / 'enemy_project'
        shutil.copytree(ROOT / 'data/combat', project / 'data/combat')
        path = project / 'data/combat/enemies.json'
        return project, path, json.loads(path.read_text(encoding='utf-8'))

    def test_all_known_races_and_default_factions_are_valid(self):
        project, path, data = self.enemy_project()
        # Different race/faction values do not invent new mechanics or change IDs.
        for race in RACE_IDS:
            for faction in FACTION_IDS:
                data['soldier'].update(race_id=race, faction_id=faction)
                path.write_text(json.dumps(data), encoding='utf-8')
                result = validate(project)
                self.assertTrue(result.report['ok'], result.report['errors'])
                self.assertEqual(result.report['enemy_identities']['soldier'],
                                 {'race_id': race, 'faction_id': faction, 'level': data['soldier'].get('level', DEFAULT_ENEMY_LEVEL)})
        del data['soldier']['race_id']
        del data['soldier']['faction_id']
        path.write_text(json.dumps(data), encoding='utf-8')
        result = validate(project)
        self.assertTrue(result.report['ok'], result.report['errors'])
        self.assertEqual(result.report['enemy_identities']['soldier'],
                         {'race_id': DEFAULT_ENEMY_RACE, 'faction_id': DEFAULT_ENEMY_FACTION,
                          'level': data['soldier'].get('level', DEFAULT_ENEMY_LEVEL)})

    def test_enemy_levels_and_omitted_default(self):
        project, path, data = self.enemy_project()
        enemy = data['soldier']
        for level in (1, 2, 5, 10, 20):
            enemy['level'] = level
            path.write_text(json.dumps(data), encoding='utf-8')
            result = validate(project)
            self.assertTrue(result.report['ok'], result.report['errors'])
            self.assertEqual(result.report['enemy_identities']['soldier']['level'], level)
        enemy.pop('level')
        path.write_text(json.dumps(data), encoding='utf-8')
        result = validate(project)
        self.assertTrue(result.report['ok'], result.report['errors'])
        self.assertEqual(result.report['enemy_identities']['soldier']['level'], DEFAULT_ENEMY_LEVEL)
        for level in (0, -1, 21, 1.5, True, '2'):
            with self.subTest(level=level):
                enemy['level'] = level
                path.write_text(json.dumps(data), encoding='utf-8')
                result = validate(project)
                self.assertFalse(result.report['ok'])
                self.assertIsNone(result.merged)

    def possession_skill(self):
        skill = self.pack['catalogs']['skills']['trail_guard:guard_cut']
        skill.update(targeting='TARGET', range=12, formula={'base': 0, 'weapon': 0},
                     conditions=[{'type': 'target_level_at_most_self'}],
                     effects=[{'type': 'possess', 'target': 'self', 'duration': 15, 'max_level_delta': 0}])
        return skill

    def test_parameterless_target_level_predicate_cannot_ignore_options(self):
        skill = self.possession_skill()
        result = self.check()
        self.assertTrue(result.report['ok'], result.report['errors'])
        for extra in ({'value': False}, {'value': 10}, {'op': '>'}, {'stat': 'STR'}, {'max_level_delta': 3}):
            with self.subTest(extra=extra):
                skill['conditions'] = [{'type': 'target_level_at_most_self', **extra}]
                result = self.check()
                self.assertFalse(result.report['ok'])
                self.assertIsNone(result.merged)
        skill['conditions'] = [{'type': 'level'}]
        self.fails('schema.required')

    def test_possession_rejects_unreviewed_effect_fields_and_contexts(self):
        skill = self.possession_skill()
        valid_effect = copy.deepcopy(skill['effects'][0])
        for changes in ({'duration': 0}, {'duration': -1}, {'max_level_delta': 1},
                        {'max_level_delta': True}, {'target': 'target'}, {'script': 'control.gd'}):
            with self.subTest(changes=changes):
                skill['effects'] = [{**valid_effect, **changes}]
                self.fails('schema.oneOf')
        for missing in ('target', 'duration', 'max_level_delta'):
            effect = copy.deepcopy(valid_effect)
            effect.pop(missing)
            skill['effects'] = [effect]
            self.fails('schema.oneOf')
        skill['effects'] = [{**valid_effect, 'conditions': [{'type': 'target_level_at_most_self'}]}]
        self.fails('effect.possession_condition')
        skill['effects'] = [valid_effect]
        passive = self.pack['catalogs']['passives']['trail_guard:steady_breath']
        passive.update(event='action_started', effects=[valid_effect])
        self.fails('effect.unsupported_context')

    def test_possession_requires_targeted_non_damage_single_effect_skill(self):
        skill = self.possession_skill()
        original = copy.deepcopy(skill)
        for changes in ({'targeting': 'SELF'}, {'conditions': []}, {'range': 0},
                        {'formula': {'base': 1}}, {'duration': 2, 'tick_interval': 1},
                        {'effects': original['effects'] + [{'type': 'heal', 'target': 'self', 'percent': 0.2}]}):
            with self.subTest(changes=changes):
                skill.clear()
                skill.update(copy.deepcopy(original))
                skill.update(copy.deepcopy(changes))
                self.fails('action.possession')

    def test_target_relation_vocabulary_and_reviewed_context(self):
        skill = self.possession_skill()
        for relation in ('hostile', 'any'):
            skill['target_relation'] = relation
            result = self.check()
            self.assertTrue(result.report['ok'], result.report['errors'])
        for relation in ('friendly', 'neutral', 'all', True):
            skill['target_relation'] = relation
            self.fails('schema.enum')
        skill.update(target_relation='any', effects=[])
        self.fails('action.target_relation')

    def test_unknown_race_faction_and_arbitrary_fields_fail_closed(self):
        project, path, source = self.enemy_project()
        for field, value in (('race_id', 'mystery_race'), ('race_id', True), ('race_id', ''),
                             ('faction_id', 'hostile_typo'), ('faction_id', 'neutral'), ('faction_id', 3),
                             ('on_spawn_script', 'run.gd')):
            with self.subTest(field=field, value=value):
                data = copy.deepcopy(source)
                data['soldier'][field] = value
                path.write_text(json.dumps(data), encoding='utf-8')
                result = validate(project)
                self.assertFalse(result.report['ok'])
                self.assertIsNone(result.merged)
                code = 'schema.additionalProperties' if field == 'on_spawn_script' else 'schema.enum'
                self.assertIn(code, {x['code'] for x in result.report['errors']})

    def test_unit_definition_supported_aliases_and_skill_references(self):
        project, path, data = self.enemy_project()
        enemy = data['soldier']
        enemy.update(stamina=4, Stamina=4, Energy=40, innate_skills=['warrior_thrust'])
        enemy['stats']['Armor'] = 35
        enemy['resistances'] = enemy.pop('resistance')
        path.write_text(json.dumps(data), encoding='utf-8')
        result = validate(project)
        self.assertTrue(result.report['ok'], result.report['errors'])
        enemy['innate_skills'] = ['invented_skill']
        path.write_text(json.dumps(data), encoding='utf-8')
        result = validate(project)
        self.assertIn('reference.missing', {x['code'] for x in result.report['errors']})
        enemy['innate_skills'] = []
        enemy['resistance'] = {'FIRE': 0.4}
        path.write_text(json.dumps(data), encoding='utf-8')
        result = validate(project)
        self.assertIn('enemy.resistance_alias', {x['code'] for x in result.report['errors']})

    def test_native_combo_and_secondary_contract_checks_nested_actions(self):
        project, path, source = self.enemy_project()
        result = validate(project)
        self.assertTrue(result.report['ok'], result.report['errors'])
        ogre = result.merged['catalogs']['enemies']['ogre']
        self.assertEqual(len(ogre['innate_actions']['PRIMARY_TAP']), 3)
        self.assertNotEqual(ogre['secondary_action']['id'], ogre['grab_action']['id'])
        for field, bad, code in (
                ('conditions', [{'type': 'self_status', 'value': 'missing_status'}], 'reference.missing'),
                ('effects', [{'type': 'resource', 'resource': 'HP'}], 'effect.amount'),
                ('hyper_armor', {'start': 0, 'end': 100}, 'action.window')):
            with self.subTest(field=field):
                data = copy.deepcopy(source)
                data['ogre']['innate_actions']['PRIMARY_TAP'][1][field] = bad
                path.write_text(json.dumps(data), encoding='utf-8')
                result = validate(project)
                self.assertFalse(result.report['ok'])
                self.assertIn(code, {x['code'] for x in result.report['errors']})
        data = copy.deepcopy(source)
        data['ogre']['secondary_action']['effects'] = [{'type': 'resource', 'resource': 'HP'}]
        path.write_text(json.dumps(data), encoding='utf-8')
        self.assertIn('effect.amount', {x['code'] for x in validate(project).report['errors']})

    def test_inline_native_skills_keep_nested_validation_and_alias_identity(self):
        project, path, source = self.enemy_project()
        result = validate(project)
        self.assertTrue(result.report['ok'], result.report['errors'])
        skills = result.merged['catalogs']['enemies']['ogre']['innate_skills']
        self.assertEqual([skill['id'] for skill in skills], ['ogre_grab', 'ogre_stone_throw'])
        self.assertEqual(skills[0], source['ogre']['grab_action'])
        for field, bad, code in (
                ('effects', [{'type': 'resource', 'resource': 'HP'}], 'effect.amount'),
                ('conditions', [{'type': 'target_status', 'value': 'missing_status'}], 'reference.missing'),
                ('ai_min_distance', 20, 'action.ai_distance'),
                ('projectile_speed', 0, 'schema.oneOf'),
                ('on_execute', 'run.gd', 'schema.oneOf')):
            with self.subTest(field=field):
                data = copy.deepcopy(source)
                data['ogre']['innate_skills'][1][field] = bad
                path.write_text(json.dumps(data), encoding='utf-8')
                result = validate(project)
                self.assertFalse(result.report['ok'])
                self.assertIn(code, {x['code'] for x in result.report['errors']})
        data = copy.deepcopy(source)
        del data['ogre']['innate_skills'][1]['projectile_speed']
        path.write_text(json.dumps(data), encoding='utf-8')
        self.assertIn('action.ai_range', {x['code'] for x in validate(project).report['errors']})
        data = copy.deepcopy(source)
        data['ogre']['innate_skills'][0]['formula']['base'] += 1
        path.write_text(json.dumps(data), encoding='utf-8')
        self.assertIn('enemy.action_id_conflict', {x['code'] for x in validate(project).report['errors']})

    def test_native_combo_rejects_empty_unknown_and_conflicting_entries(self):
        project, path, source = self.enemy_project()
        for entry in ([], ['soldier_attack'], [{}], 3):
            with self.subTest(entry=entry):
                data = copy.deepcopy(source)
                data['soldier']['innate_actions']['PRIMARY_TAP'] = entry
                path.write_text(json.dumps(data), encoding='utf-8')
                result = validate(project)
                self.assertFalse(result.report['ok'])
                self.assertIsNone(result.merged)
        data = copy.deepcopy(source)
        data['soldier']['innate_actions']['UNKNOWN_INPUT'] = data['soldier']['action']
        path.write_text(json.dumps(data), encoding='utf-8')
        self.assertIn('schema.additionalProperties', {x['code'] for x in validate(project).report['errors']})
        data = copy.deepcopy(source)
        data['soldier']['innate_actions']['PRIMARY_TAP'][0]['startup'] += .1
        path.write_text(json.dumps(data), encoding='utf-8')
        self.assertIn('enemy.action_id_conflict', {x['code'] for x in validate(project).report['errors']})

    def test_weapon_input_timing_fields_are_numeric_and_nonnegative(self):
        project, _, _ = self.enemy_project()
        path = project / 'data/combat/combat_feel.json'
        source = json.loads(path.read_text(encoding='utf-8'))
        for field in ('weapon_buffer', 'combo_reset_delay'):
            for value in (-.1, True, '0.35'):
                with self.subTest(field=field, value=value):
                    data = copy.deepcopy(source)
                    data['input'][field] = value
                    path.write_text(json.dumps(data), encoding='utf-8')
                    result = validate(project)
                    self.assertFalse(result.report['ok'])
                    self.assertIsNone(result.merged)

    def test_melee_motion_markers_and_hitstop_are_bounded(self):
        project, _, _ = self.enemy_project()
        path = project / 'data/combat/actions.json'
        source = json.loads(path.read_text(encoding='utf-8'))
        for key in ('single_blade_primary_tap_1', 'short_weapon_primary_tap_4',
                    'polearm_primary_tap_1', 'heavy_2h_primary_tap_3'):
            for patch in ({'contact': 5.0}, {'follow': .01}, {'end': 10.0},
                          {'recovery_end': 9.0}, {'clip': 'missing_clip'}):
                with self.subTest(action=key, patch=patch):
                    data = copy.deepcopy(source)
                    data[key]['motion'].update(patch)
                    path.write_text(json.dumps(data), encoding='utf-8')
                    result = validate(project)
                    self.assertFalse(result.report['ok'])
                    self.assertIsNone(result.merged)
        path.write_text(json.dumps(source), encoding='utf-8')
        feel_path = project / 'data/combat/combat_feel.json'
        feel = json.loads(feel_path.read_text(encoding='utf-8'))
        feel['impact']['light_stop'] = 2.0
        feel_path.write_text(json.dumps(feel), encoding='utf-8')
        self.assertFalse(validate(project).report['ok'])

    def test_cross_pack_reference_is_order_independent(self):
        passive = self.pack['catalogs']['passives'].pop('trail_guard:steady_breath')
        passive['id'] = 'shared:steady_breath'
        self.pack['catalogs']['careers']['trail_guard:warden']['passives'] = [passive['id']]
        second = {'format_version': 1, 'pack_id': 'shared', 'version': '1.0.0', 'catalogs': {'passives': {passive['id']: passive}}, 'assets': {}, 'bindings': []}
        second_path = self.path / 'shared.json'
        second_path.write_text(json.dumps(second), encoding='utf-8')
        self.pack_file.write_text(json.dumps(self.pack), encoding='utf-8')
        self.assertFalse(validate(ROOT, [self.pack_file]).report['ok'])
        left = validate(ROOT, [self.pack_file, second_path])
        right = validate(ROOT, [second_path, self.pack_file])
        self.assertTrue(left.report['ok'], left.report['errors'])
        self.assertTrue(right.report['ok'], right.report['errors'])
        self.assertEqual(left.merged['catalogs'], right.merged['catalogs'])

    def test_dead_trigger_and_ignored_target_rejected(self):
        passive = self.pack['catalogs']['passives']['trail_guard:steady_breath']
        passive['event'] = 'stat_update'
        self.fails('effect.event')
        passive['event'] = 'perfect_dodge'
        passive['effects'][0]['target'] = 'target'
        self.fails('effect.passive_target')

    def test_valid_action_speed_and_invalid_attribute_buff(self):
        skill = self.pack['catalogs']['skills']['trail_guard:guard_cut']
        skill['effects'] = [{'type': 'modifier', 'stat': 'action_speed_multiplier', 'value': 0.1, 'duration': 3, 'target': 'self'}]
        result = self.check()
        self.assertTrue(result.report['ok'], result.report['errors'])
        skill['effects'][0]['stat'] = 'STR'
        self.fails('effect.modifier_context')

    def test_report_cannot_overwrite_pack_input(self):
        before = self.pack_file.read_bytes()
        result = subprocess.run([sys.executable, str(PIPELINE / 'validate.py'), '--pack', str(self.pack_file), '--report', str(self.pack_file)], capture_output=True, encoding='utf-8', check=False)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.pack_file.read_bytes(), before)

    def test_inline_item_action_requires_unique_namespaced_id(self):
        action = copy.deepcopy(self.pack['catalogs']['skills']['trail_guard:guard_cut'])
        action['is_skill'] = False
        action['id'] = 'trail_guard:item_cut'
        item = {'id': 'trail_guard:cut_scroll', 'name': 'Cut scroll', 'category': 'consumable', 'effect': 'action', 'cooldown': 5, 'action': action}
        self.pack['catalogs']['items'][item['id']] = item
        result = self.check()
        self.assertTrue(result.report['ok'], result.report['errors'])
        action['id'] = 'warrior_whirlwind'
        result = self.fails('id.namespace')
        self.assertIn('action.id_collision', {x['code'] for x in result.report['errors']})

    def test_namespaced_item_actions_cannot_share_skill_or_other_item_ids(self):
        action = copy.deepcopy(self.pack['catalogs']['skills']['trail_guard:guard_cut'])
        action['is_skill'] = False
        item = {'id': 'trail_guard:scroll_a', 'name': 'Scroll A', 'category': 'consumable',
                'effect': 'action', 'cooldown': 5, 'action': action}
        self.pack['catalogs']['items'][item['id']] = item
        self.fails('action.id_collision')  # Valid namespace, but a skill owns this ID.
        action['id'] = 'trail_guard:scroll_cut'
        other = copy.deepcopy(item)
        other.update(id='trail_guard:scroll_b', name='Scroll B')
        self.pack['catalogs']['items'][other['id']] = other
        self.fails('action.id_collision')  # Identical definitions still share cooldown identity.
        other['action']['id'] = 'trail_guard:other_scroll_cut'
        result = self.check()
        self.assertTrue(result.report['ok'], result.report['errors'])

    def test_cli_is_machine_readable_and_reports_nonzero_on_failure(self):
        command = [sys.executable, str(PIPELINE / 'validate.py'), '--project', str(ROOT), '--pack', str(self.pack_file)]
        result = subprocess.run(command, capture_output=True, encoding='utf-8', check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(result.stdout)['ok'])
        self.pack_file.write_text('{bad', encoding='utf-8')
        result = subprocess.run(command, capture_output=True, encoding='utf-8', check=False)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertFalse(json.loads(result.stdout)['ok'])


if __name__ == '__main__':
    unittest.main()
