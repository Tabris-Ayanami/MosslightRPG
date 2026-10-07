"""Read-only validator and in-memory merger for combat catalogs and draft packs."""
from __future__ import annotations

import argparse
import ast
import copy
import hashlib
import json
import math
import operator
import os
import re
import struct
import sys
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

from jsonschema import Draft202012Validator

try:
    from .schema import (AUTHORABLE, CATALOGS, DAMAGE_TYPES, EVENTS, FAMILIES, MELEE_CLIP_LENGTHS,
                         DEFAULT_ENEMY_FACTION, DEFAULT_ENEMY_RACE, DEFAULT_ENEMY_LEVEL, FACTION_IDS,
                         RACE_IDS, UNIT_IDENTITY_VERSION,
                         MODIFIERS, PRESENTATIONS, RESOURCES, RESOURCE_MODEL, RESOURCE_COST_MODIFIERS, SCHEMA, STATS,
                         WEAPON_TYPES, SPELL_COSTS, catalog_schema)
except ImportError:
    from schema import (AUTHORABLE, CATALOGS, DAMAGE_TYPES, EVENTS, FAMILIES, MELEE_CLIP_LENGTHS,
                        DEFAULT_ENEMY_FACTION, DEFAULT_ENEMY_RACE, DEFAULT_ENEMY_LEVEL, FACTION_IDS,
                        RACE_IDS, UNIT_IDENTITY_VERSION,
                        MODIFIERS, PRESENTATIONS, RESOURCES, RESOURCE_MODEL, RESOURCE_COST_MODIFIERS, SCHEMA, STATS,
                        WEAPON_TYPES, SPELL_COSTS, catalog_schema)

MAX_JSON_BYTES = 8 * 1024 * 1024
MAX_ASSET_BYTES = 64 * 1024 * 1024
ACTION_EFFECTS = {'resource', 'hp_percent', 'status', 'control', 'shield', 'teleport',
                  'dash', 'heal', 'remove_aggro', 'disengage', 'modifier', 'possess'}
PASSIVE_SPECIAL = {'forced_crit', 'hit_sequence', 'element_sequence', 'proficiency'}
MODIFIER_EVENTS = {
    'damage_before': {'crit_chance', 'crit_multiplier', 'damage_multiplier', 'damage_bonus',
                      'armor_penetration', 'resistance_penetration', 'poise_damage_multiplier',
                      'poise_damage_bonus', 'area_multiplier', 'vulnerability_all'},
    'stat_update': {*STATS, 'Armor', 'Poise', 'poise', 'spell_range_multiplier',
                    'damage_taken', 'damage_taken_bonus', 'action_speed_multiplier', 'charge_time_multiplier',
                    *RESOURCE_COST_MODIFIERS},
}


def pointer(*parts):
    return '/' + '/'.join(str(p).replace('~', '~0').replace('/', '~1') for p in parts)


@dataclass
class ValidationResult:
    report: dict
    merged: dict | None


class Validator:
    def __init__(self, project: Path):
        self.project = Path(project).resolve()
        self.errors = []
        self.warnings = []
        self.files = {}
        self.origins = {}
        self.pack_info = []
        self.assets = {}
        self.bindings = []
        self.enemy_identities = {}
        self.acquisition = None

    def issue(self, code, path, message, *, warning=False):
        target = self.warnings if warning else self.errors
        target.append({'code': code, 'path': str(path), 'message': str(message)})

    def fingerprint(self, path, raw):
        path = str(Path(path).resolve())
        digest = hashlib.sha256(raw).hexdigest()
        previous = self.files.get(path)
        if previous is not None and previous != digest:
            self.issue('input.changed', path, 'The same source changed while this validation was reading it')
        else:
            self.files[path] = digest
        return digest

    def read_json(self, path):
        path = Path(path)
        try:
            if path.stat().st_size > MAX_JSON_BYTES:
                raise ValueError('JSON exceeds the 8 MiB authoring limit')
            raw = path.read_bytes()
            self.fingerprint(path, raw)
            def pairs(entries):
                result = {}
                for key, value in entries:
                    if key in result:
                        raise ValueError('Duplicate JSON key: ' + key)
                    result[key] = value
                return result
            def constant(value):
                raise ValueError('Non-finite JSON number: ' + value)
            value = json.loads(raw.decode('utf-8-sig'), object_pairs_hook=pairs, parse_constant=constant)
            # JSON 1e999 is syntactically legal but not a finite game number.
            self.check_finite(value, str(path))
            return value
        except (OSError, ValueError, RecursionError) as exc:
            self.issue('json.invalid', path, exc)
            return None

    def check_finite(self, value, path):
        if isinstance(value, float) and not math.isfinite(value):
            raise ValueError('Non-finite numeric value at ' + path)
        if isinstance(value, dict):
            for key, child in value.items():
                self.check_finite(child, path + pointer(key))
        elif isinstance(value, list):
            for index, child in enumerate(value):
                self.check_finite(child, path + pointer(index))

    def schema_check(self, data, schema, path):
        count = len(self.errors)
        try:
            for error in Draft202012Validator(schema).iter_errors(data):
                self.issue('schema.' + str(error.validator), str(path) + pointer(*error.absolute_path), error.message)
        except RecursionError:
            self.issue('json.depth', path, 'Nested data exceeds the validator depth limit')
        return len(self.errors) == count

    def load_base(self):
        base = {}
        for family in CATALOGS:
            path = self.project / 'data' / 'combat' / (family + '.json')
            catalog = self.read_json(path)
            if catalog is None:
                base[family] = {}
                continue
            if not self.schema_check(catalog, catalog_schema(family), path):
                base[family] = {}
                continue
            base[family] = catalog
            for key, value in catalog.items():
                self.origins[(family, key)] = str(path) + pointer(key)
                if key != value['id']:
                    self.issue('id.mismatch', self.origins[(family, key)], 'Dictionary key must equal definition.id')
        return base

    def merge_acquisition(self, valid_packs, db):
        """Validate additive world acquisition and produce a runtime sidecar.

        The sidecar intentionally stays outside the twelve combat catalogs so
        enemy progression is derived once by the runtime, never double-merged.
        """
        expanded = [(file, pack) for file, pack in valid_packs if 'acquisition' in pack]
        if not expanded:
            return None
        shops_path = (self.project / 'data/world/shops.json').resolve()
        quests_path = (self.project / 'data/world/quests.json').resolve()
        shops = self.read_json(shops_path)
        quests = self.read_json(quests_path)
        if not isinstance(shops, dict):
            self.issue('acquisition.base_shops', shops_path, 'Base shops must be a JSON object')
            shops = {}
        if not isinstance(quests, dict):
            self.issue('acquisition.base_quests', quests_path, 'Base quests must be a JSON object')
            quests = {}

        merged = {'format_version': 1,
                  'world_base_sha256': {
                      'shops': self.files.get(str(shops_path), ''),
                      'quests': self.files.get(str(quests_path), ''),
                  },
                  'shops': {}, 'quests': {}, 'enemy_drops': {}}
        shop_goods = {key: copy.deepcopy(value.get('goods', {}))
                      for key, value in shops.items() if isinstance(value, dict)}
        quest_items = {key: copy.deepcopy(value.get('rewards', {}).get('items', {}))
                       for key, value in quests.items() if isinstance(value, dict)
                       and isinstance(value.get('rewards', {}), dict)}
        enemy_drops = {key: copy.deepcopy(value.get('drops', {}))
                       for key, value in db.get('progression', {}).items()
                       if key != 'rules' and isinstance(value, dict)}
        acquisition_errors_before = len(self.errors)

        def bounded_integer(value, minimum, maximum):
            return (not isinstance(value, bool) and isinstance(value, (int, float))
                    and math.isfinite(float(value)) and float(value).is_integer()
                    and minimum <= value <= maximum)

        def own_inventory_item(pack, pack_id, item_id, path):
            if (not isinstance(item_id, str) or len(item_id) > 96
                    or not namespaced(item_id, pack_id)
                    or not any(item_id in pack.get('catalogs', {}).get(family, {})
                               for family in ('items', 'weapons', 'equipment'))):
                self.issue('acquisition.item_owner', path,
                           'Acquisition may reference only an item, weapon or equipment owned by this pack (ID length <=96)')
                return False
            return True

        for file, pack in sorted(expanded, key=lambda entry: entry[1]['pack_id']):
            pack_id = pack['pack_id']
            data = pack['acquisition']
            for shop_id, goods_map in sorted(data.get('shops', {}).items()):
                target_path = str(file) + pointer('acquisition', 'shops', shop_id)
                base_shop = shops.get(shop_id)
                if not isinstance(base_shop, dict) or not isinstance(base_shop.get('goods'), dict):
                    self.issue('acquisition.shop_target', target_path, 'Shop target must already exist in data/world/shops.json')
                    continue
                merged_goods = shop_goods.setdefault(shop_id, copy.deepcopy(base_shop['goods']))
                compiled_goods = merged['shops'].setdefault(shop_id, {})
                for item_id, goods in sorted(goods_map.items()):
                    item_path = target_path + pointer(item_id)
                    if not own_inventory_item(pack, pack_id, item_id, item_path):
                        continue
                    if item_id in merged_goods:
                        self.issue('acquisition.shop_collision', item_path, 'Cannot replace an existing or already-added shop item')
                        continue
                    if not isinstance(goods, dict):
                        self.issue('acquisition.shop_goods', item_path, 'Shop goods must be an object')
                        continue
                    stock = goods.get('stock')
                    buy = goods.get('buy_price')
                    sell = goods.get('sell_price')
                    if (not bounded_integer(stock, 0, 1000000)
                            or (buy is not None and not bounded_integer(buy, 1, 2147483647))
                            or (sell is not None and not bounded_integer(sell, 1, 2147483647))
                            or (buy is None and sell is None) or (buy is None and stock != 0)):
                        self.issue('acquisition.shop_value', item_path,
                                   'Stock must be 0..1,000,000; prices positive Int32; at least one price is required and sell-only stock must be zero')
                        continue
                    entry = {'stock': int(stock)}
                    if buy is not None: entry['buy_price'] = int(buy)
                    if sell is not None: entry['sell_price'] = int(sell)
                    merged_goods[item_id] = entry
                    compiled_goods[item_id] = entry

            for quest_id, reward_map in sorted(data.get('quests', {}).items()):
                target_path = str(file) + pointer('acquisition', 'quests', quest_id)
                base_quest = quests.get(quest_id)
                if not isinstance(base_quest, dict) or not isinstance(base_quest.get('rewards', {}), dict):
                    self.issue('acquisition.quest_target', target_path, 'Quest target must already exist in data/world/quests.json')
                    continue
                items = quest_items.setdefault(quest_id, copy.deepcopy(base_quest.get('rewards', {}).get('items', {})))
                compiled_items = merged['quests'].setdefault(quest_id, {})
                for item_id, quantity in sorted(reward_map.items()):
                    item_path = target_path + pointer(item_id)
                    if not own_inventory_item(pack, pack_id, item_id, item_path):
                        continue
                    if item_id in items:
                        self.issue('acquisition.quest_collision', item_path, 'Cannot replace an existing or already-added quest reward')
                        continue
                    if not bounded_integer(quantity, 1, 1000000):
                        self.issue('acquisition.quantity', item_path, 'Acquisition quantity must be an integer from 1 to 1,000,000')
                        continue
                    items[item_id] = int(quantity)
                    compiled_items[item_id] = int(quantity)

            for enemy_id, drops_map in sorted(data.get('enemy_drops', {}).items()):
                target_path = str(file) + pointer('acquisition', 'enemy_drops', enemy_id)
                if enemy_id not in db.get('enemies', {}) or enemy_id not in db.get('progression', {}):
                    self.issue('acquisition.enemy_target', target_path,
                               'Enemy target must already exist in both combat enemies and progression catalogs')
                    continue
                drops = enemy_drops.setdefault(enemy_id, copy.deepcopy(db['progression'][enemy_id].get('drops', {})))
                compiled_drops = merged['enemy_drops'].setdefault(enemy_id, {})
                for item_id, quantity in sorted(drops_map.items()):
                    item_path = target_path + pointer(item_id)
                    if not own_inventory_item(pack, pack_id, item_id, item_path):
                        continue
                    if item_id in drops:
                        self.issue('acquisition.drop_collision', item_path, 'Cannot replace an existing or already-added enemy drop')
                        continue
                    if not bounded_integer(quantity, 1, 1000000):
                        self.issue('acquisition.quantity', item_path, 'Acquisition quantity must be an integer from 1 to 1,000,000')
                        continue
                    drops[item_id] = int(quantity)
                    compiled_drops[item_id] = int(quantity)

        for shop_id, goods in shop_goods.items():
            if len(goods) > 128:
                self.issue('acquisition.shop_capacity', str(shops_path) + pointer(shop_id), 'Merged shop goods exceed the runtime limit of 128')
        for quest_id, items in quest_items.items():
            if len(items) > 32:
                self.issue('acquisition.quest_capacity', str(quests_path) + pointer(quest_id), 'Merged quest reward items exceed the runtime limit of 32')
        for enemy_id, drops in enemy_drops.items():
            if len(drops) > 32:
                self.issue('acquisition.drop_capacity', '/progression' + pointer(enemy_id), 'Merged enemy drop entries exceed this extension limit of 32')

        # Mirror EconomyService's existing cross-shop no-arbitrage invariant over
        # the whole merged catalog, not just the extension's own records.
        for shop_id, goods in shop_goods.items():
            for item_id, entry in goods.items():
                if not isinstance(entry, dict) or 'sell_price' not in entry:
                    continue
                for other_id, other_goods in shop_goods.items():
                    other_entry = other_goods.get(item_id, {})
                    if (isinstance(other_entry, dict) and 'buy_price' in other_entry
                            and entry['sell_price'] > other_entry['buy_price']):
                        self.issue('acquisition.shop_arbitrage',
                                   str(shops_path) + pointer(shop_id, item_id, 'sell_price'),
                                   f'Selling at {shop_id} and buying at {other_id} creates an arbitrage profit')

        if len(self.errors) != acquisition_errors_before:
            return None
        # Empty groups are deterministic, so every acquisition pack compiles to
        # the same manifest shape regardless of which categories it uses.
        return merged

    def reference(self, db, family, value, path):
        families = (family,) if isinstance(family, str) else family
        if not any(value in db.get(name, {}) for name in families):
            self.issue('reference.missing', path, f'{value!r} is not defined in {", ".join(families)}')

    def conditions(self, conditions, db, path):
        for i, condition in enumerate(conditions):
            p = path + pointer(i)
            kind = condition['type']
            if kind == 'target_level_at_most_self':
                continue  # Parameterless predicate; schema rejects ignored fields.
            expected = condition['value']
            op = condition.get('op', 'in' if isinstance(expected, list) else '==')
            values = expected if isinstance(expected, list) else [expected]
            if op in ('in', 'not_in') and not isinstance(expected, list):
                self.issue('condition.operator', p, 'in/not_in require an array value')
            if op in ('>', '>=', '<', '<=') and (isinstance(expected, bool) or not isinstance(expected, (int, float))):
                self.issue('condition.operator', p, 'Ordering comparison requires a number')
            if kind in ('stat', 'attribute', 'resource'):
                key = 'resource' if kind == 'resource' else 'stat'
                if key not in condition:
                    self.issue('condition.field', p, kind + ' requires ' + key)
            if kind in ('self_hp', 'target_hp', 'distance', 'level', 'stat', 'attribute', 'resource'):
                if isinstance(expected, bool) or not isinstance(expected, (int, float)):
                    self.issue('condition.value', p, kind + ' requires a numeric value')
                elif kind in ('self_hp', 'target_hp') and not 0 <= expected <= 1:
                    self.issue('condition.value', p, 'Health ratio must be between 0 and 1')
            if kind == 'combat_state' and not (isinstance(expected, bool) or isinstance(expected, str) and expected in ('IN_COMBAT', 'OUT_OF_COMBAT', 'NORMAL', 'CHARGING', 'ACTION', 'SWITCH', 'DODGE', 'KNOCKDOWN', 'DEAD', 'GRABBED', 'GRABBING', 'STAGGER')):
                self.issue('condition.value', p, 'Unknown combat_state value')
            if kind in ('behind', 'behind_target', 'first_hit', 'first_damage', 'elemental', 'spell', 'critical', 'crit', 'area') and not isinstance(expected, bool):
                self.issue('condition.value', p, kind + ' requires a boolean value')
            vocabulary = {'weapon_family': FAMILIES, 'proficiency': FAMILIES,
                          'weapon_type': WEAPON_TYPES, 'damage_type': DAMAGE_TYPES,
                          'presentation_type': PRESENTATIONS, 'event': EVENTS}
            if kind in vocabulary and any(x not in vocabulary[kind] for x in values):
                self.issue('condition.vocabulary', p, 'Unsupported ' + kind + ' value')
            if kind == 'career':
                for value in values:
                    self.reference(db, 'careers', str(value), p)
            if kind in ('self_status', 'target_status'):
                for value in [condition['status']] if 'status' in condition else values:
                    if value != 'controlled_by_self':
                        self.reference(db, 'status_effects', str(value), p)

    def effects(self, effects, db, path, context='action', event=None, draft=False):
        for i, effect in enumerate(effects):
            p = path + pointer(i)
            kind = effect['type']
            allowed = ACTION_EFFECTS | PASSIVE_SPECIAL if context == 'passive' else ACTION_EFFECTS
            if context == 'status':
                allowed = {'modifier', 'damage', 'stealth', 'shield'}
            if kind not in allowed:
                self.issue('effect.unsupported_context', p, f'{kind!r} is not executed in {context} effects')
            if kind == 'possess' and context != 'action':
                self.issue('effect.unsupported_context', p, 'Possession authoring requires a targeted action with cast-time checks')
            if kind == 'possess' and effect.get('conditions'):
                self.issue('effect.possession_condition', p, 'Possession conditions belong on the action so checks precede costs and startup')
            self.conditions(effect.get('conditions', []), db, p + '/conditions')
            for field in ('status', 'boss_status'):
                if field in effect:
                    self.reference(db, 'status_effects', effect[field], p + '/' + field)
            if kind == 'control' and 'boss_status' not in effect:
                self.reference(db, 'status_effects', 'binding_slow', p)
            if kind == 'resource' and 'amount' not in effect and 'value' not in effect:
                self.issue('effect.amount', p, 'resource effect requires amount or value')
            if draft and kind == 'resource' and 'amount' in effect and 'value' in effect:
                self.issue('effect.amount_alias', p, 'Use one amount or value; runtime gives amount precedence')
            if kind == 'modifier' and effect['stat'] in RESOURCE_COST_MODIFIERS and effect['value'] < 0:
                self.issue('effect.resource_override', p, 'Resource cost overrides are absolute nonnegative costs in runtime units')
            if kind in ('dash', 'teleport') and effect.get('target') != 'self':
                self.issue('effect.movement_target', p, 'Movement must explicitly target self')
            if kind == 'modifier' and context == 'passive' and effect['stat'] not in MODIFIER_EVENTS.get(event, set()):
                self.issue('effect.modifier_event', p, f'{effect["stat"]} is not consumed by passive event {event}')
            if kind == 'forced_crit' and event != 'damage_before':
                self.issue('effect.event', p, 'forced_crit requires damage_before')
            if kind == 'hit_sequence' and event != 'damage_after':
                self.issue('effect.event', p, 'hit_sequence requires damage_after')
            if kind == 'element_sequence' and event != 'action_started':
                self.issue('effect.event', p, 'element_sequence requires action_started')
            if draft:
                # These fields appear in legacy data but cannot customize the current runtime.
                for key in ('boss_duration', 'boss_move_speed_multiplier', 'normal_enemies_only', 'invulnerable'):
                    if key in effect:
                        self.issue('effect.metadata_only', p + '/' + key, 'Runtime ignores this field; omit it from new content')
                if context == 'passive' and kind == 'proficiency':
                    self.issue('effect.unsupported_context', p, 'New proficiency permissions need runtime integration')
                if context == 'passive' and kind in ACTION_EFFECTS - {'modifier'} and event not in ('damage_after', 'perfect_dodge', 'action_started'):
                    self.issue('effect.event', p, 'Immediate passive effects require a runtime trigger event')
                if context == 'passive' and effect.get('target', 'self') != 'self':
                    self.issue('effect.passive_target', p, 'Passive trigger effects are applied to their owner')
                if context == 'passive' and kind in ('hit_sequence', 'element_sequence') and effect.get('conditions'):
                    self.issue('effect.ignored_condition', p, 'Sequence interpreter does not evaluate per-effect conditions')
                if context == 'action' and kind == 'modifier' and effect['stat'] in (*STATS, 'Armor', 'Poise', 'poise'):
                    self.issue('effect.modifier_context', p, 'This modifier needs a stat_update passive; action status modifiers do not apply it')

    def action(self, data, db, path, draft=False):
        if data.get('ai_min_distance', 0) > max(.5, data.get('range', data.get('radius', 0))) * .8:
            self.issue('action.ai_distance', path, 'AI minimum distance must fit the action engagement range')
        if data.get('ai_use_at_range', False) and data.get('projectile_speed', 0) <= 0:
            self.issue('action.ai_range', path, 'Ranged AI response requires a moving projectile')
        if 'spell_rank' in data:
            rank = data['spell_rank']
            if type(rank) not in (int, float) or not math.isfinite(rank) or not 0 <= rank < len(SPELL_COSTS) or rank != int(rank):
                self.issue('action.spell_rank', path, 'Spell rank must be an integer from 0 to 9')
            elif data.get('costs', {}).get('Energy', 0) != SPELL_COSTS[int(rank)]:
                self.issue('action.spell_cost', path, 'Spell base Energy must match the rank cost table: 0/10/20/35/55/80/110/145/185/230')
        self.conditions(data.get('conditions', []), db, path + '/conditions')
        self.effects(data.get('effects', []), db, path + '/effects', draft=draft)
        possession = any(effect['type'] == 'possess' for effect in data.get('effects', []))
        if data.get('target_relation') == 'any' and not possession:
            self.issue('action.target_relation', path, 'Non-hostile target selection is reviewed only for possession skills')
        if possession:
            if data.get('targeting') != 'TARGET' or not data.get('is_skill') or len(data['effects']) != 1:
                self.issue('action.possession', path, 'Possession requires one sole effect on a TARGET skill')
            if not any(condition['type'] == 'target_level_at_most_self' for condition in data.get('conditions', [])):
                self.issue('action.possession', path, 'Possession requires target_level_at_most_self before resource payment')
            if data.get('range', 0) <= 0 or any(value != 0 for value in data.get('formula', {}).values()):
                self.issue('action.possession', path, 'Possession requires positive target range and no damage formula')
            if 'duration' in data or 'dual_sequence' in data:
                self.issue('action.possession', path, 'Possession cannot combine with periodic areas or dual sequences')
        for i, modifier in enumerate(data.get('damage_modifiers', [])):
            self.conditions(modifier['conditions'], db, path + '/damage_modifiers' + pointer(i, 'conditions'))
        duration = sum(data.get(k, 0) for k in ('startup', 'active', 'recovery'))
        if 'motion' in data:
            motion = data['motion']
            lengths = MELEE_CLIP_LENGTHS
            if not 0 < motion['contact'] < motion['follow'] <= motion['end'] <= lengths[motion['clip']] + .001:
                self.issue('action.motion', path + '/motion', 'Source markers must be ordered and inside the shipped clip')
            if ('recovery_clip' in motion) != ('recovery_end' in motion) or ('recovery_clip' in motion and motion.get('recovery_end', 0) > lengths[motion['recovery_clip']] + .001):
                self.issue('action.motion', path + '/motion', 'Recovery requires a matching clip and an in-range endpoint')
        for key in ('guard_window', 'charge_release_guard_window', 'hyper_armor', 'counter_stance'):
            if key not in data:
                continue
            window = data[key]
            if not window['start'] < window['end'] <= duration + 1e-6:
                self.issue('action.window', path + '/' + key, 'Window must start before end and fit inside action duration')
            if window.get('perfect_window', 0) > window['end'] - window['start'] + 1e-6:
                self.issue('action.window', path + '/' + key, 'Perfect window exceeds guard window')
            if key == 'counter_stance':
                self.reference(db, 'reactions', window['counter_action'], path + '/counter_stance/counter_action')
                if 'formula' in data:
                    self.issue('action.counter_formula', path, 'Counter stance itself cannot be a damaging action')
        if 'charge_guard_window' in data:
            window = data['charge_guard_window']
            if window['start_ratio'] >= window['end_ratio'] or 'charge_release_guard_window' not in data:
                self.issue('action.charge_window', path, 'Charge guard needs an ordered ratio range and release window')
        if 'dual_sequence' in data and (not data['is_skill'] or data['presentation_type'] != 'WEAPON_ACTION' or 'formula' not in data):
            self.issue('action.dual_sequence', path, 'Dual sequence requires a damaging weapon skill')
        if 'duration' in data and data.get('tick_interval', 0) <= 0:
            self.issue('action.periodic', path, 'Persistent area needs a positive tick_interval')

    def career(self, key, data, db, path):
        for field, family in (('base_career', 'careers'), ('parent_career', 'careers'), ('preferred_skill', 'skills')):
            if field in data:
                self.reference(db, family, data[field], path + '/' + field)
        for field, family in (('next_careers', 'careers'), ('skills', 'skills'), ('passives', 'passives')):
            for i, value in enumerate(data[field]):
                self.reference(db, family, value, path + pointer(field, i))
        if data['required_level'] > data['max_level']:
            self.issue('career.level', path, 'required_level exceeds max_level')
        if data['proficiencies'] != data['weapon_proficiencies']:
            self.issue('career.proficiencies', path, 'Compatibility proficiency lists must agree')
        if 'preferred_skill' in data and data['preferred_skill'] not in data['skills']:
            self.issue('career.preferred_skill', path, 'Preferred skill must belong to this career')
        visited, inherited, node = set(), set(), data
        while node:
            if node['id'] in visited:
                self.issue('career.cycle', path, 'Career parent graph contains a cycle')
                break
            visited.add(node['id'])
            inherited.update(node['skills'])
            if 'parent_career' not in node:
                if node['id'] != data['base_career']:
                    self.issue('career.root', path, 'Ancestor chain does not reach base_career')
                break
            node = db['careers'].get(node['parent_career'])
        if 'parent_career' not in data:
            if set(data['stats']) != set(STATS) or set(data['formulas']) != {*RESOURCES, 'Poise'} or len(data['default_sets']) != 2:
                self.issue('career.root_fields', path, 'Base career requires all six stats, four formulas and two default sets')
        else:
            parent = db['careers'].get(data['parent_career'])
            if parent and key not in parent['next_careers']:
                self.issue('career.parent_link', path, 'Parent next_careers must include this career; use career_links for pack additions')
            if parent and data['required_level'] < parent['required_level']:
                self.issue('career.level', path, 'Advancement cannot require a lower level than its parent')
            if data['stats'] or data['formulas']:
                self.issue('career.ignored_stats', path, 'Advancements inherit base stats/formulas; use passives for changes')
        for resource, formula in data['formulas'].items():
            try:
                for level in range(1, data['max_level'] + 1):
                    value = safe_formula(formula, {**data['stats'], 'level': level})
                    if value < 0 or value > 1000000 or (resource in ('HP', 'Stamina', 'Poise') and value <= 0):
                        raise ValueError('Resource formula leaves the supported range at level ' + str(level))
            except (ValueError, SyntaxError, ArithmeticError) as exc:
                self.issue('career.formula', path + pointer('formulas', resource), exc)
        for i, preset in enumerate(data['default_sets']):
            self.reference(db, 'weapons', preset['weapon'], path + pointer('default_sets', i, 'weapon'))
            for j, skill in enumerate(preset['skills']):
                self.reference(db, 'skills', skill, path + pointer('default_sets', i, 'skills', j))
                if skill not in inherited:
                    self.issue('career.unlearned_skill', path + pointer('default_sets', i, 'skills', j), 'Default skill is not learned by career or ancestors')
        for next_id in data['next_careers']:
            child = db['careers'].get(next_id, {})
            if child and child.get('parent_career') != key:
                self.issue('career.child_parent', path, next_id + ' does not declare this parent')
        rule = data.get('loadout_rule')
        if rule:
            types = [db['weapons'].get(x['weapon'], {}).get('weapon_type') for x in data['default_sets']]
            valid = len(types) == 2 and types[0] in ('Sword', 'Katana') and (types[1] == 'Shield' if rule == 'sword_shield_pair' else types[1] in ('Sword', 'Katana'))
            if not valid:
                self.issue('career.loadout', path, 'Default weapons do not satisfy paired loadout rule')

    def catalogs(self, db, drafts):
        inventory_ids = {}
        action_ids = {}
        def register_action(action, path):
            if action['id'] in action_ids:
                self.issue('action.id_collision', path, 'Action ID already used at ' + action_ids[action['id']])
            action_ids[action['id']] = path
        for required in ('rules', 'starter'):
            self.reference(db, 'progression', required, '/progression/' + required)
        rules = db['progression'].get('rules', {})
        if 'max_level' not in rules or 'xp_to_next' not in rules:
            self.issue('progression.rules', '/progression/rules', 'Progression rules need max_level and xp_to_next')
        else:
            for level in range(1, rules['max_level']):
                if str(level) not in rules['xp_to_next']:
                    self.issue('progression.xp', '/progression/rules/xp_to_next', 'Missing XP threshold for level ' + str(level))
        for family in CATALOGS:
            for key, data in db[family].items():
                path = self.origins[(family, key)]
                draft = (family, key) in drafts
                if family in ('items', 'weapons', 'equipment'):
                    if key in inventory_ids:
                        self.issue('id.inventory_collision', path, 'Inventory ID already used by ' + inventory_ids[key])
                    inventory_ids[key] = family
                if family in ('skills', 'actions', 'reactions'):
                    register_action(data, path)
                    self.action(data, db, path, draft)
                    if family == 'skills' and data.get('is_reaction', False):
                        self.issue('skill.reaction', path, 'A learnable skill cannot be marked as a reaction')
                elif family == 'careers':
                    self.career(key, data, db, path)
                elif family in ('weapons', 'equipment'):
                    for field in ('conditions', 'requirements'):
                        self.conditions(data[field], db, path + '/' + field)
                    for i, passive in enumerate(data.get('special_effects', data.get('passives', []))):
                        self.reference(db, 'passives', passive, path + pointer('passives', i))
                    if data['conditions'] != data['requirements']:
                        self.issue('equipment.requirements', path, 'conditions and requirements must agree; runtime gives conditions precedence')
                    if family == 'weapons':
                        expected = {'Sword': 'SINGLE_BLADE', 'Katana': 'SINGLE_BLADE', 'Dagger': 'SHORT_WEAPON', 'Spear': 'POLEARM', 'GreatAxe': 'HEAVY_2H', 'Greatsword': 'HEAVY_2H', 'Bow': 'BOW', 'Staff': 'CASTER', 'Orb': 'CASTER', 'Shield': 'SHIELD'}[data['weapon_type']]
                        if data['animation_family'] != expected:
                            self.issue('weapon.family', path, 'Weapon type and animation family disagree')
                        if data['weapon_type'] == 'Shield':
                            for field in ('physical_reduction', 'elemental_reduction', 'stamina_cost', 'angle', 'perfect_window', 'move_multiplier', 'compatible_families'):
                                if field not in data:
                                    self.issue('weapon.shield_field', path, 'Shield requires ' + field)
                    elif data['slot'] == 'ring' and set(data.get('slots', [])) != {'ring1', 'ring2'}:
                        self.issue('equipment.ring_slots', path, 'Ring must declare ring1 and ring2')
                    elif data['slot'] != 'ring' and 'slots' in data:
                        self.issue('equipment.slots', path, 'Only rings declare alternative slots')
                elif family == 'items':
                    kind = data['effect']
                    if kind == 'resource' and ('resource' not in data or not any(data.get(k, 0) > 0 for k in ('fraction', 'amount'))):
                        self.issue('item.resource', path, 'Resource item requires resource and a positive fraction or amount')
                    if kind == 'action':
                        if 'action' not in data:
                            self.issue('item.action', path, 'Action item requires action definition')
                        else:
                            register_action(data['action'], path + '/action')
                            if draft and not namespaced(data['action']['id'], key.split(':', 1)[0]):
                                self.issue('id.namespace', path + '/action/id', 'Inline action ID must use this pack namespace')
                            self.action(data['action'], db, path + '/action', draft)
                    if kind != 'action' and 'action' in data:
                        self.issue('item.ignored_action', path, 'Only action items execute their action field')
                    if kind != 'resource' and any(k in data for k in ('resource', 'fraction', 'amount')):
                        self.issue('item.ignored_resource', path, 'Only resource items use resource restoration fields')
                elif family in ('passives', 'status_effects'):
                    self.conditions(data.get('conditions', []), db, path + '/conditions')
                    self.effects(data['effects'], db, path + '/effects', 'passive' if family == 'passives' else 'status', data.get('event'), draft)
                    if family == 'passives' and data.get('event') == 'action_transform' and data.get('action_rule') != 'dual_sword_skill_repeat':
                        self.issue('passive.action_rule', path, 'action_transform requires implemented action_rule')
                elif family == 'enemies':
                    # Match UnitDefinition.for_enemy's optional identity defaults.
                    # This is a reviewed default-faction model, not an interpreter
                    # for arbitrary set_faction_relation calls in game scripts.
                    race = data.get('race_id', DEFAULT_ENEMY_RACE)
                    faction = data.get('faction_id', DEFAULT_ENEMY_FACTION)
                    if race not in RACE_IDS or faction not in FACTION_IDS:
                        self.issue('enemy.identity', path, 'Enemy identity is outside capability table v1')
                    self.enemy_identities[key] = {'race_id': race, 'faction_id': faction,
                                                  'level': data.get('level', DEFAULT_ENEMY_LEVEL)}
                    if 'resistance' in data and 'resistances' in data and data['resistance'] != data['resistances']:
                        self.issue('enemy.resistance_alias', path, 'resistance and resistances disagree; UnitDefinition gives resistance precedence')
                    self.reference(db, 'progression', key, path + '/reward')
                    native_ids = {}
                    def native_action(action, action_path):
                        self.action(action, db, action_path)
                        # Catalogs retain the legacy first action for display.
                        # Its exact snapshot may also be the first combo swing;
                        # different definitions sharing an ID remain an error.
                        previous = native_ids.get(action['id'])
                        if previous is None:
                            native_ids[action['id']] = action
                            register_action(action, action_path)
                        elif previous != action:
                            self.issue('enemy.action_id_conflict', action_path,
                                       'Native action ID has different definitions in the same unit')
                    for field in ('action', 'secondary_action', 'grab_action'):
                        if field in data:
                            native_action(data[field], path + '/' + field)
                    for index, skill in enumerate(data.get('innate_skills', [])):
                        skill_path = path + pointer('innate_skills', index)
                        if isinstance(skill, dict):
                            native_action(skill, skill_path)
                        else:
                            self.reference(db, 'skills', skill, skill_path)
                    for semantic, entry in data.get('innate_actions', {}).items():
                        action_path = path + pointer('innate_actions', semantic)
                        if isinstance(entry, list):
                            for index, action in enumerate(entry):
                                native_action(action, action_path + pointer(index))
                        else:
                            native_action(entry, action_path)
                    if 'shield' in data:
                        self.reference(db, 'weapons', data['shield'], path + '/shield')
                        if db['weapons'].get(data['shield'], {}).get('weapon_type') != 'Shield':
                            self.issue('enemy.shield', path, 'Enemy shield must reference a Shield weapon')
                elif family == 'progression':
                    for field in ('items', 'drops'):
                        for item in data.get(field, {}):
                            self.reference(db, ('items', 'weapons', 'equipment'), item, path + pointer(field, item))
                    for i, item in enumerate(data.get('equipment_rotation', [])):
                        self.reference(db, ('weapons', 'equipment'), item, path + pointer('equipment_rotation', i))
                    for i, item in enumerate(data.get('quickslots', [])):
                        self.reference(db, 'items', item, path + pointer('quickslots', i))
                    for slot, item in data.get('equipment', {}).items():
                        self.reference(db, 'equipment', item, path + pointer('equipment', slot))
                    if key not in ('rules', 'starter'):
                        self.reference(db, 'enemies', key, path)

    def pack_assets(self, pack, file):
        root = file.parent.resolve()
        pack_id = pack['pack_id']
        extensions = {'icon': ('.png',), 'portrait': ('.png',), 'texture': ('.png',),
                      'model': ('.glb',), 'animation': ('.glb',), 'audio': ('.wav', '.ogg'), 'vfx': ('.png', '.glb')}
        for asset_id, asset in pack['assets'].items():
            p = str(file) + pointer('assets', asset_id)
            if not namespaced(asset_id, pack_id):
                self.issue('id.namespace', p, 'Asset ID must use this pack namespace')
            if asset_id in self.assets:
                self.issue('asset.collision', p, 'Asset ID appears in more than one pack')
            self.assets[asset_id] = copy.deepcopy(asset)
            relative = asset['path']
            parts = PurePosixPath(relative).parts
            if not relative or '\\' in relative or ':' in relative or relative.startswith('/') or any(x in ('..', '.') for x in relative.split('/')) or any(ord(c) < 32 for c in relative) or any(not x for x in relative.split('/')):
                self.issue('asset.path', p + '/path', 'Use a normalized relative path inside the pack; no traversal, drives or URLs')
                continue
            target = (root / Path(*parts)).resolve()
            if not target.is_relative_to(root):
                self.issue('asset.path', p + '/path', 'Resolved asset escapes pack root (including symlinks)')
                continue
            if target.suffix.lower() not in extensions[asset['kind']]:
                self.issue('asset.extension', p, 'Unsupported asset extension for ' + asset['kind'])
                continue
            try:
                if target.stat().st_size > MAX_ASSET_BYTES:
                    raise ValueError('Asset exceeds 64 MiB limit')
                content = target.read_bytes()
                digest = self.fingerprint(target, content)
                if asset.get('sha256', digest) != digest:
                    raise ValueError('sha256 does not match file')
                dimensions = asset_dimensions(content, target.suffix.lower())
                if dimensions:
                    for name, value in zip(('width', 'height'), dimensions):
                        if name in asset and asset[name] != value:
                            raise ValueError(name + ' differs from PNG header')
                elif 'width' in asset or 'height' in asset:
                    raise ValueError('width/height metadata is only supported for PNG files')
            except (OSError, ValueError, struct.error) as exc:
                self.issue('asset.invalid', p, exc)
            if not asset.get('license') or not asset.get('source'):
                self.issue('asset.provenance', p, 'Record license and source before release', warning=True)
        for i, binding in enumerate(pack['bindings']):
            p = str(file) + pointer('bindings', i)
            if binding['id'] not in pack['catalogs'].get(binding['catalog'], {}):
                self.issue('binding.owner', p, 'Binding must point to a new definition in this pack')
            for role, asset_id in binding['assets'].items():
                if asset_id not in pack['assets']:
                    self.issue('binding.asset', p, 'Binding asset must exist in this pack: ' + asset_id)
                elif pack['assets'][asset_id]['kind'] != role:
                    self.issue('binding.kind', p, 'Binding role and asset kind disagree: ' + role)
            self.bindings.append(copy.deepcopy(binding))

    def run(self, pack_paths=()):
        db = self.load_base()
        valid_packs, drafts, pack_ids = [], set(), set()
        for file in map(lambda p: Path(p).resolve(), pack_paths):
            pack = self.read_json(file)
            if pack is None or not self.schema_check(pack, SCHEMA, file):
                continue
            name = pack['pack_id']
            if name in pack_ids:
                self.issue('pack.duplicate', file, 'Only one version of each pack_id is allowed')
            pack_ids.add(name)
            self.pack_info.append({'pack_id': name, 'version': pack['version'], 'path': str(file)})
            valid_packs.append((file, pack))
            for family, entries in pack['catalogs'].items():
                for key, data in entries.items():
                    p = str(file) + pointer('catalogs', family, key)
                    if key != data['id']:
                        self.issue('id.mismatch', p, 'Dictionary key must equal definition.id')
                    if not namespaced(key, name):
                        self.issue('id.namespace', p, f'New content IDs must match {name}:local_id')
                    if any(key in db[x] for x in AUTHORABLE):
                        self.issue('id.collision', p, 'New content cannot replace an existing ID')
                        continue
                    self.origins[(family, key)] = p
                    drafts.add((family, key))
                    db[family][key] = copy.deepcopy(data)
            self.pack_assets(pack, file)
        # Only explicit additive grants are allowed, after all independent packs load.
        for file, pack in valid_packs:
            for i, link in enumerate(pack.get('career_links', [])):
                p = str(file) + pointer('career_links', i)
                parent = db['careers'].get(link['parent'])
                child = pack['catalogs'].get('careers', {}).get(link['child'])
                if parent is None or child is None or child.get('parent_career') != link['parent']:
                    self.issue('career.link', p, 'Link needs an existing parent and this pack-owned child declaring that parent')
                elif link['child'] not in parent['next_careers']:
                    parent['next_careers'].append(link['child'])
            for i, grant in enumerate(pack.get('career_grants', [])):
                p = str(file) + pointer('career_grants', i)
                career = db['careers'].get(grant['career'])
                if career is None:
                    self.issue('reference.missing', p, 'Grant career does not exist')
                    continue
                for field, family in (('skills', 'skills'), ('passives', 'passives')):
                    for value in grant.get(field, []):
                        if value not in pack['catalogs'].get(family, {}):
                            self.issue('grant.owner', p, 'A grant can add only definitions owned by this pack')
                        elif value not in career[field]:
                            career[field].append(value)
        # Schema failures can leave incomplete catalogs; no semantic cascade or traceback.
        if not self.errors:
            self.catalogs(db, drafts)
        if not self.errors:
            self.acquisition = self.merge_acquisition(valid_packs, db)
        if self.errors:
            self.acquisition = None
        if valid_packs:
            self.issue('pack.offline_only', '/', 'Validation merges in memory only; it does not compile, activate, publish or preview this pack.', warning=True)
            self.issue('pack.balance_unverified', '/', 'Numeric bounds detect invalid input, not game balance or visual quality.', warning=True)
        report = {
            'report_version': 1, 'ok': not self.errors, 'mode': 'draft' if pack_paths else 'base',
            'counts': {family: len(db[family]) for family in CATALOGS}, 'packs': self.pack_info,
            'assets': len(self.assets), 'bindings': len(self.bindings),
            'unit_identity_version': UNIT_IDENTITY_VERSION,
            'resource_model': RESOURCE_MODEL, 'resources': list(RESOURCES),
            'enemy_identities': self.enemy_identities,
            'input_sha256': dict(sorted(self.files.items())),
            'errors': self.errors, 'warnings': self.warnings,
        }
        merged = {'catalogs': db, 'assets': self.assets, 'bindings': self.bindings} if not self.errors else None
        if merged is not None and self.acquisition is not None:
            merged['acquisition'] = self.acquisition
        return ValidationResult(report, merged)


def namespaced(value, namespace):
    return bool(re.fullmatch(re.escape(namespace) + r':[a-z][a-z0-9_]*', value))


def safe_formula(text, variables):
    """Mirror the reviewed numeric Expression subset, without executing Godot.

    Loadout passes float stats and an integer level. Expression retains literal
    number types, truncates integer division toward zero, and floor retains its
    argument's numeric type. Those details matter to subsequent arithmetic.
    """
    if type(text) in (int, float):
        if not math.isfinite(text) or abs(text) > 1000000000:
            raise ValueError('Formula constant is non-finite or exceeds 1e9')
        return float(text)
    if not isinstance(text, str):
        raise ValueError('Formula must be a number or arithmetic string')
    if len(text) > 512:
        raise ValueError('Formula exceeds 512 characters')
    if any(character in text for character in ('#', '\n', '\r')):
        raise ValueError('Formula must be a single arithmetic expression without comments')
    text = text.strip()
    tree = ast.parse(text, mode='eval')
    if sum(1 for _ in ast.walk(tree)) > 128:
        raise ValueError('Formula exceeds 128 syntax nodes')
    def divide(left, right):
        if type(left) is int and type(right) is int:
            magnitude = abs(left) // abs(right)
            return -magnitude if (left < 0) != (right < 0) else magnitude
        return operator.truediv(left, right)
    binary = {ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul, ast.Div: divide}
    def visit(node):
        if isinstance(node, ast.Expression):
            result = visit(node.body)
        elif isinstance(node, ast.Constant) and type(node.value) in (int, float):
            literal = ast.get_source_segment(text, node)
            if not re.fullmatch(r'(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?', literal):
                raise ValueError('Only decimal numeric literals are supported')
            result = node.value
        elif isinstance(node, ast.Name) and node.id in variables and node.id in (*STATS, 'level'):
            value = variables[node.id]
            if type(value) not in (int, float) or not math.isfinite(value):
                raise ValueError('Formula variables must be finite numbers')
            if node.id == 'level' and value != int(value):
                raise ValueError('Runtime level must be an integer')
            result = int(value) if node.id == 'level' else float(value)
        elif isinstance(node, ast.BinOp) and type(node.op) in binary:
            result = binary[type(node.op)](visit(node.left), visit(node.right))
        elif isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.USub):
            result = -visit(node.operand)
        elif isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == 'floor' and len(node.args) == 1 and not node.keywords:
            argument = visit(node.args[0])
            result = math.floor(argument) if type(argument) is int else float(math.floor(argument))
        elif isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in ('max', 'min') and len(node.args) == 2 and not node.keywords:
            result = (max if node.func.id == 'max' else min)(visit(node.args[0]), visit(node.args[1]))
        else:
            raise ValueError('Only numeric constants, six stats, level, + - * /, floor(x), min(a,b), max(a,b) are supported')
        if not math.isfinite(result) or abs(result) > 1000000000:
            raise ValueError('Formula intermediate is non-finite or exceeds 1e9')
        return result
    return visit(tree)


def asset_dimensions(content, extension):
    if extension == '.png':
        if len(content) < 33 or content[:8] != b'\x89PNG\r\n\x1a\n' or content[12:16] != b'IHDR' or struct.unpack('>I', content[8:12])[0] != 13:
            raise ValueError('Invalid PNG signature/IHDR')
        dimensions = struct.unpack('>II', content[16:24])
        if any(x < 1 or x > 16384 for x in dimensions):
            raise ValueError('PNG dimensions must be within 1..16384')
        return dimensions
    if extension == '.glb':
        if len(content) < 12 or content[:4] != b'glTF' or struct.unpack('<II', content[4:12]) != (2, len(content)):
            raise ValueError('Invalid GLB 2 header/length')
    elif extension == '.wav':
        if len(content) < 12 or content[:4] != b'RIFF' or content[8:12] != b'WAVE':
            raise ValueError('Invalid WAV signature')
    elif extension == '.ogg' and not content.startswith(b'OggS'):
        raise ValueError('Invalid Ogg signature')
    return None


def validate(project, pack_paths=()):
    return Validator(Path(project)).run(list(pack_paths))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--pack', type=Path, action='append', default=[], help='Repeatable content-pack JSON path')
    parser.add_argument('--report', type=Path, help='Optional report output; stdout is always JSON')
    args = parser.parse_args(argv)
    result = validate(args.project, args.pack)
    output = json.dumps(result.report, ensure_ascii=False, indent=2) + '\n'
    if args.report:
        resolved = args.report.resolve()
        inputs = {os.path.normcase(p) for p in result.report['input_sha256']}
        if os.path.normcase(str(resolved)) in inputs or resolved.is_relative_to(args.project.resolve() / 'data'):
            parser.error('--report cannot overwrite input files or the game data directory')
        resolved.write_text(output, encoding='utf-8')
    sys.stdout.reconfigure(encoding='utf-8') if hasattr(sys.stdout, 'reconfigure') else None
    print(output, end='')
    return 0 if result.report['ok'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
