"""Authoring contracts for the existing combat interpreter (not new game mechanics).

Run this file to regenerate the checked-in JSON Schema documents. Runtime
validation uses the same definitions, via the maintained jsonschema package.
"""
from __future__ import annotations

import copy
import json
from pathlib import Path

VERSION = 1
CATALOGS = ('careers', 'weapons', 'skills', 'passives', 'equipment', 'enemies',
            'status_effects', 'actions', 'combat_feel', 'reactions', 'items', 'progression')
AUTHORABLE = ('items', 'weapons', 'equipment', 'careers', 'skills', 'passives')
STATS = ('STR', 'DEX', 'CON', 'INT', 'PER', 'CHA')
RESOURCES = ('HP', 'Stamina', 'Energy')
# Direct runtime units, including continuous Energy values. Legacy Qi/SpellSlot
# conversion is a save-migration concern, never an authoring-pack inference.
RESOURCE_MODEL = 'unified_energy_v1'
SPELL_COSTS = (0, 10, 20, 35, 55, 80, 110, 145, 185, 230)
RESOURCE_COST_MODIFIERS = ('energy_cost_override', 'weapon_energy_cost_override')
FAMILIES = ('SINGLE_BLADE', 'SHORT_WEAPON', 'POLEARM', 'HEAVY_2H', 'BOW', 'CASTER', 'SHIELD', 'UNARMED')
WEAPON_TYPES = ('Sword', 'Katana', 'Dagger', 'Bow', 'Spear', 'GreatAxe', 'Greatsword', 'Staff', 'Orb', 'Shield')
DAMAGE_TYPES = ('PHYSICAL', 'FIRE', 'ICE', 'LIGHTNING', 'EARTH', 'WIND', 'TRUE')
TARGETING = ('SELF', 'CIRCLE', 'SELF/CIRCLE', 'POINT', 'POINT/CIRCLE', 'TARGET', 'CONE', 'DIRECTION', 'LINE', 'POINT/LINE')
PRESENTATIONS = ('WEAPON_ACTION', 'CASTER_ACTION', 'SPELL', 'VFX_ONLY')
EVENTS = ('damage_before', 'damage_after', 'perfect_dodge', 'stat_update', 'action_started', 'action_transform')
MODIFIERS = (*STATS, 'Armor', 'Poise', 'poise', 'crit_chance', 'crit_multiplier',
             'damage_multiplier', 'damage_bonus', 'armor_penetration', 'resistance_penetration',
             'poise_damage_multiplier', 'poise_damage_bonus', 'area_multiplier',
             'spell_range_multiplier', 'damage_taken', 'damage_taken_bonus',
             'move_speed', 'move_speed_multiplier', *RESOURCE_COST_MODIFIERS,
             'action_speed_multiplier', 'charge_time_multiplier', 'all_vulnerability',
             'vulnerability', 'vulnerability_all', 'vulnerability_physical',
             *('vulnerability_' + x for x in (*DAMAGE_TYPES, 'ALL')))
SLOTS = ('head', 'torso', 'legs', 'feet', 'belt', 'ring', 'neck')
ID = {'type': 'string', 'pattern': r'^[A-Za-z0-9_]+(?::[a-z][a-z0-9_]*)?$'}
TEXT = {'type': 'string', 'minLength': 1, 'maxLength': 4096}
BOOL = {'type': 'boolean'}
NUM = {'type': 'number', 'minimum': -1000000, 'maximum': 1000000}
NONNEG = {'type': 'number', 'minimum': 0, 'maximum': 1000000}
POSITIVE = {'type': 'number', 'exclusiveMinimum': 0, 'maximum': 1000000}
RATIO = {'type': 'number', 'minimum': 0, 'maximum': 1}
LEVEL = {'type': 'integer', 'minimum': 1, 'maximum': 20}
# Reviewed capability table v1, mirrored from race_catalog.gd and the default
# relation in combat_world.gd. Tests statically check drift; no GDScript executes.
UNIT_IDENTITY_VERSION = 1
RACE_IDS = ('human', 'elf', 'orc', 'dwarf', 'dragonborn', 'dead_apostle',
            'angel', 'demon', 'devil', 'elemental', 'construct', 'giant')
FACTION_IDS = ('heroes', 'hostiles')
DEFAULT_ENEMY_RACE = 'human'
DEFAULT_ENEMY_FACTION = 'hostiles'
DEFAULT_ENEMY_LEVEL = 1


# Lengths are verified against shipped retargeted resources by the engine tests.
MELEE_CLIP_LENGTHS = {'SwordAlt': .433334, 'SwordB': .533334, 'SwordC': 2.0,
                      'SwordARecovery': .966667, 'SwordBRecovery': 1.033334,
                      'KnifeDiagonal': 1.0, 'KnifeReturn': 1.066667,
                      'KnifeStab': 1.6, 'KnifeChop': 1.066667,
                      'TwoHandSlice': 1.1, 'TwoHandChop': 1.633333,
                      'TwoHandStab': 1.6, 'TwoHandSpin': 2.4, 'TwoHandIdle': 1.066667}


def enum(values):
    return {'enum': list(values)}


def obj(properties, required=(), additional=False):
    return {'type': 'object', 'properties': properties, 'required': list(required), 'additionalProperties': additional}


def array(items, **kwargs):
    return {'type': 'array', 'items': items, 'maxItems': 10000, **kwargs}


def ref(name):
    return {'$ref': '#/$defs/' + name}


def number_map(keys, value=NUM, required=()):
    return obj({k: value for k in keys}, required)


def definition(properties, required=()):
    return obj({'id': ID, 'name': TEXT, 'description': TEXT, **properties}, ('id', 'name', *required))


def build_schema():
    defs = {}
    defs['formula'] = number_map(('base', 'base_value', 'weapon', 'weapon_scaling_coeff', *STATS, *(x + '_coeff' for x in STATS)))
    defs['conditions'] = array(ref('condition'))
    condition_types = ('weapon_family', 'weapon_type', 'stat', 'attribute', 'self_hp', 'target_hp',
                       'behind', 'behind_target', 'combat_state', 'self_status', 'target_status',
                       'career', 'resource', 'proficiency', 'first_hit', 'first_damage', 'distance',
                       'elemental', 'level', 'presentation_type', 'spell', 'critical', 'crit', 'area', 'event', 'damage_type',
                       'target_level_at_most_self')
    defs['condition'] = obj({
        'type': enum(condition_types), 'value': {'anyOf': [TEXT, NUM, BOOL, array(TEXT, minItems=1)]},
        'op': enum(('in', 'not_in', '==', '=', 'eq', '!=', 'ne', 'contains', '>', '>=', '<', '<=')),
        'stat': enum((*STATS, 'Armor')), 'resource': enum(RESOURCES), 'status': ID,
    }, ('type',))
    # This predicate compares two context fields. Runtime ignores all parameters;
    # rejecting them avoids accepting a fake custom threshold or inverted check.
    defs['condition']['allOf'] = [{
        'if': {'properties': {'type': {'const': 'target_level_at_most_self'}}},
        'then': {'properties': {k: False for k in ('value', 'op', 'stat', 'resource', 'status')}},
        'else': {'required': ['value']},
    }]
    # Distinct branches prevent accepting an effect's fields on an unrelated effect.
    common = {'target': enum(('self', 'target')), 'conditions': ref('conditions')}
    variants = []
    def effect(kind, props, required=()):
        variants.append(obj({'type': {'const': kind}, **common, **props}, ('type', *required)))
    effect('resource', {'resource': enum(RESOURCES), 'amount': NUM, 'value': NUM}, ('resource',))
    effect('hp_percent', {'value': {'type': 'number', 'minimum': -1, 'maximum': 1}, 'basis': {'const': 'current'}}, ('value',))
    status = {'status': ID, 'duration': NUM, 'formula': ref('formula'), 'damage_type': enum(DAMAGE_TYPES), 'tick_interval': POSITIVE}
    effect('status', status, ('status',))
    effect('control', {**status, 'boss_status': ID, 'boss_duration': NONNEG, 'boss_move_speed_multiplier': RATIO}, ('status',))
    effect('shield', {'formula': ref('formula'), 'value': NONNEG, 'duration': POSITIVE})
    for kind in ('teleport', 'dash'):
        effect(kind, {'distance': NONNEG if kind == 'teleport' else NUM, 'invulnerable': {'const': False}}, ('distance',))
    effect('heal', {'percent': RATIO}, ('percent',))
    # Reviewed authoring subset: a finite, level-bounded targeted control lease.
    # Other runtime control/form branches require their own contract review.
    effect('possess', {'target': {'const': 'self'}, 'duration': POSITIVE,
                       'max_level_delta': {'const': 0}}, ('target', 'duration', 'max_level_delta'))
    for kind in ('remove_aggro', 'disengage'):
        effect(kind, {'normal_enemies_only': {'const': True}})
    effect('modifier', {'stat': enum(MODIFIERS), 'value': NUM, 'duration': POSITIVE}, ('stat', 'value'))
    effect('forced_crit', {'value': {'const': True}})
    effect('hit_sequence', {'count': {'type': 'integer', 'minimum': 1, 'maximum': 100}, 'presentation_type': enum(PRESENTATIONS), 'skill_only': BOOL, 'multiplier': NONNEG}, ('count', 'multiplier'))
    effect('element_sequence', {'count': {'type': 'integer', 'minimum': 1, 'maximum': 5}, 'multiplier': NONNEG}, ('count', 'multiplier'))
    effect('proficiency', {'value': array(enum((*FAMILIES, *WEAPON_TYPES)), minItems=1)}, ('value',))
    # Existing status definitions contain descriptive metadata not dispatched by apply_effect.
    effect('damage', {'formula': ref('formula'), 'damage_type': enum(DAMAGE_TYPES), 'can_crit': BOOL}, ('formula',))
    effect('stealth', {'value': {'const': True}}, ('value',))
    defs['effect'] = {'oneOf': variants}
    defs['effects'] = array(ref('effect'))
    guard_props = {'start': NONNEG, 'end': POSITIVE, 'perfect_window': POSITIVE, 'angle': {'type': 'number', 'exclusiveMinimum': 0, 'maximum': 360}, 'physical_reduction': RATIO, 'elemental_reduction': RATIO, 'stamina_cost': NONNEG, 'use_equipped_shield': BOOL}
    defs['guard'] = obj(guard_props, ('start', 'end', 'perfect_window'))
    defs['window'] = obj({'start': NONNEG, 'end': POSITIVE}, ('start', 'end'))
    action_props = {
        'is_skill': BOOL, 'leap_motion': BOOL, 'is_reaction': BOOL, 'presentation_type': enum(PRESENTATIONS),
        'animation_family': enum(FAMILIES), 'animation_id': TEXT,
        'semantic': enum(('PRIMARY_TAP', 'PRIMARY_CHARGE', 'SECONDARY_TAP', 'SECONDARY_CHARGE')),
        'combo_index': {'type': 'integer', 'minimum': 0}, 'combo_window': NONNEG,
        'startup': NONNEG, 'active': POSITIVE, 'recovery': NONNEG, 'cooldown': NONNEG,
        'ai_attack_every': {'type': 'integer', 'minimum': 0}, 'ai_min_distance': NONNEG,
        'ai_use_at_range': {'type': 'boolean'},
        'costs': number_map(RESOURCES, NONNEG), 'gains': number_map(RESOURCES, NONNEG),
        'spell_rank': {'type': 'integer', 'minimum': 0, 'maximum': 9},
        'formula': ref('formula'), 'damage_type': enum(DAMAGE_TYPES), 'targeting': enum(TARGETING),
        'target_relation': enum(('hostile', 'any')),
        'range': NONNEG, 'radius': NONNEG, 'angle': {'type': 'number', 'minimum': 0, 'maximum': 360},
        'angle_degrees': {'type': 'number', 'minimum': 0, 'maximum': 360}, 'width': NONNEG,
        'length': NONNEG, 'vertical_reach': NONNEG, 'target_radius': NONNEG,
        'center_on_point': BOOL, 'point_origin': BOOL, 'poise_damage': NONNEG,
        'knockback_force': NONNEG, 'launch_force': NONNEG, 'knockdown': BOOL, 'can_crit': BOOL,
        'conditions': ref('conditions'), 'effects': ref('effects'), 'min_level': LEVEL,
        'crit_multiplier_bonus': NUM, 'crit_chance_bonus': NUM, 'forced_crit': BOOL,
        'projectile_speed': POSITIVE, 'pierce': {'type': 'integer', 'minimum': 0, 'maximum': 100}, 'explosion_radius': NONNEG,
        'projectiles': {'type': 'integer', 'minimum': 1, 'maximum': 100}, 'spread_angle': NONNEG,
        'duration': POSITIVE, 'tick_interval': POSITIVE, 'waves': {'type': 'integer', 'minimum': 1, 'maximum': 100},
        'shape': enum(('CIRCLE', 'LINE')), 'chain_targets': {'type': 'integer', 'minimum': 1, 'maximum': 100},
        'chain_range': NONNEG, 'chain_multiplier': RATIO,
        'damage_modifiers': array(obj({'conditions': ref('conditions'), 'damage_bonus': NUM}, ('conditions', 'damage_bonus'))),
        'guard_window': ref('guard'), 'hyper_armor': ref('window'), 'charge_release_guard_window': ref('guard'),
        'charge_guard_window': obj({'start_ratio': RATIO, 'end_ratio': RATIO, 'angle': NONNEG, 'physical_reduction': RATIO, 'elemental_reduction': RATIO, 'stamina_cost': NONNEG}, ('start_ratio', 'end_ratio')),
        'counter_stance': obj({'start': NONNEG, 'end': POSITIVE, 'angle': NONNEG, 'counter_action': ID}, ('start', 'end', 'counter_action')),
        'dual_sequence': obj({'template': enum(('spin', 'thrust', 'slash')), 'origin': enum(('action_origin', 'after_movement'))}, ('template', 'origin')),
        'attack_kind': enum(('GRAB',)), 'blockable': BOOL, 'parryable': BOOL, 'grab_duration': POSITIVE,
        'punch_hand': enum(('left', 'right')),
        'motion': obj({'clip': enum(tuple(k for k in MELEE_CLIP_LENGTHS if not k.endswith('Recovery') and not k.endswith('Idle'))), 'contact': POSITIVE,
                       'follow': POSITIVE, 'end': POSITIVE,
                       'recovery_clip': enum(('SwordARecovery', 'SwordBRecovery')),
                       'recovery_end': POSITIVE}, ('clip', 'contact', 'follow', 'end')),
    }
    action_required = ('is_skill', 'presentation_type', 'startup', 'active', 'recovery', 'cooldown', 'costs', 'gains', 'targeting', 'conditions', 'effects')
    defs['action'] = definition(action_props, action_required)
    defs['skills'] = copy.deepcopy(defs['action'])
    defs['skills']['properties']['is_skill'] = {'const': True}
    defs['skills']['required'].append('min_level')
    defs['visual'] = obj({'style': TEXT, 'color': {'type': 'string', 'pattern': '^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$'}}, ('style', 'color'))
    common_equipment = {'color': defs['visual']['properties']['color'], 'visual': ref('visual'), 'conditions': ref('conditions'), 'requirements': ref('conditions')}
    defs['weapons'] = definition({**common_equipment,
        'weapon_type': enum(WEAPON_TYPES), 'animation_family': enum(FAMILIES), 'quality': enum(('Common', 'Fine', 'Rare', 'Epic', 'Legendary')),
        'weapon_scaling': NONNEG, 'special_effects': array(ID), 'model_id': TEXT,
        'physical_reduction': RATIO, 'elemental_reduction': RATIO, 'stamina_cost': NONNEG,
        'angle': {'type': 'number', 'exclusiveMinimum': 0, 'maximum': 360}, 'perfect_window': POSITIVE,
        'move_multiplier': RATIO, 'compatible_families': array(enum(FAMILIES), minItems=1),
    }, ('weapon_type', 'animation_family', 'weapon_scaling', 'requirements', 'conditions', 'special_effects', 'model_id', 'visual'))
    defs['equipment'] = definition({**common_equipment, 'slot': enum(SLOTS), 'slots': array(enum(('ring1', 'ring2')), uniqueItems=True, minItems=1), 'modifiers': number_map((*STATS, 'Armor')), 'passives': array(ID)}, ('slot', 'modifiers', 'passives', 'requirements', 'conditions', 'visual'))
    defs['items'] = definition({'category': enum(('consumable', 'material')), 'effect': enum(('resource', 'action', 'level', 'none')), 'resource': enum(RESOURCES), 'fraction': RATIO, 'amount': POSITIVE, 'cooldown': NONNEG, 'action': ref('action'), 'icon': {'const': 'wood'}, 'color': defs['visual']['properties']['color']}, ('category', 'effect', 'cooldown'))
    defs['items']['allOf'] = [{
        'if': {'properties': {'category': {'const': 'material'}}},
        'then': {'properties': {'effect': {'const': 'none'}}},
        'else': {'properties': {'effect': enum(('resource', 'action', 'level'))}},
    }]
    defs['careers'] = definition({
        'base_career': ID, 'parent_career': ID, 'required_level': LEVEL, 'max_level': LEVEL,
        'stats': number_map(STATS, {'type': 'integer', 'minimum': 1, 'maximum': 1000}),
        'formulas': number_map((*RESOURCES, 'Poise'), {'anyOf': [NONNEG, {**TEXT, 'maxLength': 512}]}),
        'proficiencies': array(enum(FAMILIES), uniqueItems=True), 'weapon_proficiencies': array(enum(FAMILIES), uniqueItems=True),
        'next_careers': array(ID, uniqueItems=True), 'skills': array(ID, uniqueItems=True), 'passives': array(ID, uniqueItems=True), 'preferred_skill': ID,
        'loadout_rule': enum(('sword_shield_pair', 'dual_sword_pair')),
        'default_sets': array(obj({'weapon': ID, 'skills': array(ID, minItems=3, maxItems=3)}, ('weapon', 'skills')), maxItems=2),
    }, ('base_career', 'required_level', 'max_level', 'stats', 'formulas', 'proficiencies', 'weapon_proficiencies', 'next_careers', 'skills', 'passives', 'default_sets'))
    defs['passives'] = definition({'event': enum(EVENTS), 'conditions': ref('conditions'), 'effects': ref('effects'), 'cooldown': NONNEG, 'min_level': LEVEL, 'action_rule': {'const': 'dual_sword_skill_repeat'}, 'behind_angle': {'const': 120}, 'reset_after_combat': {'const': 5}}, ('event', 'conditions', 'effects', 'cooldown', 'min_level'))
    # These families are audited as base content only; pack authoring is explicitly unavailable.
    defs['status_effects'] = definition({'duration': NUM, 'tick_interval': NONNEG, 'conditions': ref('conditions'), 'effects': ref('effects'), 'stack_rule': enum(('refresh', 'stack', 'ignore', 'replace')), 'max_stacks': {'type': 'integer', 'minimum': 1}, 'formula': ref('formula'), 'damage_type': enum(DAMAGE_TYPES), 'can_crit': BOOL, 'break_on_attack': BOOL, 'consume_on': TEXT, 'skill_only': BOOL, 'is_control': BOOL}, ('duration', 'effects'))
    defs['actions'] = ref('action')
    defs['reactions'] = ref('action')
    native_actions = obj({semantic: {'oneOf': [ref('action'), array(ref('action'), minItems=1)]}
                          for semantic in ('PRIMARY_TAP', 'PRIMARY_CHARGE', 'SECONDARY_TAP', 'SECONDARY_CHARGE')})
    defs['enemies'] = definition({'action': ref('action'), 'grab_action': ref('action'),
        'secondary_action': ref('action'), 'innate_actions': native_actions, 'shield': ID,
        'race_id': enum(RACE_IDS), 'faction_id': enum(FACTION_IDS), 'level': LEVEL,
        'innate_skills': array({'oneOf': [ID, ref('action')]}),
        'stats': number_map((*STATS, 'Armor')), 'resistance': number_map(DAMAGE_TYPES), 'resistances': number_map(DAMAGE_TYPES),
        **{k: NONNEG for k in ('HP', 'Armor', 'Poise', 'max_hp', 'max_poise', 'armor', 'hp', 'poise', 'damage', 'poise_damage', 'range', 'move_speed', 'attack_range', 'aggro_range', 'attack_cooldown', 'grab_every', 'stamina', 'Stamina', 'Energy')},
        **{k: BOOL for k in ('immune_to_launch', 'immune_to_knockdown', 'is_boss')}, 'color': TEXT, 'boss_title': TEXT}, ('action',))
    defs['combat_feel'] = obj({'id': ID, **{k: NONNEG for k in ('charge_duration', 'charge_move_multiplier', 'charge_release_startup', 'cycle_multiplier', 'dodge_buffer', 'minimum_recovery', 'skill_buffer', 'skill_chain_window', 'weapon_buffer', 'combo_reset_delay', 'startup_multiplier', 'strike_active_multiplier', 'strike_gap', 'tap_threshold')}, **{k: {'type': 'number', 'minimum': 0, 'maximum': .14} for k in ('quick_stop', 'light_stop', 'finish_stop', 'heavy_stop', 'guard_stop')}, 'strike_order': array(enum((0, 1)), minItems=2, maxItems=2), 'skill_templates': obj({x: obj({'strike_active': POSITIVE, 'strike_gap': POSITIVE}, ('strike_active', 'strike_gap')) for x in ('spin', 'thrust', 'slash')})}, ('id',))
    amounts = {'type': 'object', 'additionalProperties': {'type': 'integer', 'minimum': 1}}
    defs['progression'] = obj({'id': ID, 'max_level': LEVEL, 'first_map_max_level': LEVEL, 'xp_to_next': amounts, 'items': amounts, 'drops': amounts, 'experience': NONNEG, 'equipment_rotation': array(ID), 'quickslots': array(ID, minItems=4, maxItems=4), 'equipment': obj({k: ID for k in ('head', 'torso', 'legs', 'feet', 'belt', 'neck', 'ring1', 'ring2')})}, ('id',))
    defs['asset'] = obj({'kind': enum(('icon', 'portrait', 'texture', 'model', 'animation', 'audio', 'vfx')), 'path': TEXT, 'sha256': {'type': 'string', 'pattern': '^[a-f0-9]{64}$'}, 'width': {'type': 'integer', 'minimum': 1, 'maximum': 16384}, 'height': {'type': 'integer', 'minimum': 1, 'maximum': 16384}, 'license': TEXT, 'source': TEXT}, ('kind', 'path'))
    defs['binding'] = obj({'catalog': enum(AUTHORABLE), 'id': ID, 'assets': obj({k: ID for k in ('icon', 'portrait', 'texture', 'model', 'animation', 'audio', 'vfx')}, additional=False)}, ('catalog', 'id', 'assets'))
    # Acquisition is an additive declaration over existing world definitions.
    # The pack must still prove ownership and base-target validity in validate.py.
    item_ref = {'type': 'string', 'maxLength': 96,
                'pattern': r'^[a-z][a-z0-9_]{1,47}:[a-z][a-z0-9_]{0,95}$'}
    world_shop_id = {'type': 'string', 'maxLength': 96, 'pattern': r'^[A-Za-z0-9_.:-]+$'}
    world_quest_id = {'type': 'string', 'maxLength': 96, 'pattern': r'^[A-Za-z0-9_.:/-]+$'}
    enemy_id = {'type': 'string', 'maxLength': 96,
                'pattern': r'^[A-Za-z][A-Za-z0-9_]*(?::[a-z][a-z0-9_]*)?$'}
    quantity = {'type': 'integer', 'minimum': 1, 'maximum': 1000000}
    shop_goods = {
        'type': 'object',
        'properties': {
            'stock': {'type': 'integer', 'minimum': 0, 'maximum': 1000000},
            'buy_price': {'type': 'integer', 'minimum': 1, 'maximum': 2147483647},
            'sell_price': {'type': 'integer', 'minimum': 1, 'maximum': 2147483647},
        },
        'required': ['stock'],
        'additionalProperties': False,
        'anyOf': [{'required': ['buy_price']}, {'required': ['sell_price']}],
    }
    shop_goods_map = {'type': 'object', 'propertyNames': item_ref,
                      'patternProperties': {item_ref['pattern']: shop_goods},
                      'additionalProperties': False, 'minProperties': 1, 'maxProperties': 128}
    item_quantity_map = {'type': 'object', 'propertyNames': item_ref,
                         'patternProperties': {item_ref['pattern']: quantity},
                         'additionalProperties': False, 'minProperties': 1, 'maxProperties': 32}
    target_map = lambda target, value, maximum: {
        'type': 'object', 'propertyNames': target,
        'patternProperties': {target['pattern']: value},
        'additionalProperties': False, 'minProperties': 1, 'maxProperties': maximum,
    }
    acquisition = obj({
        'shops': target_map(world_shop_id, shop_goods_map, 64),
        'quests': target_map(world_quest_id, item_quantity_map, 128),
        'enemy_drops': target_map(enemy_id, item_quantity_map, 16384),
    }, additional=False)
    acquisition['minProperties'] = 1
    schema = obj({
        'format_version': {'const': VERSION}, 'pack_id': {'type': 'string', 'pattern': '^[a-z][a-z0-9_]{1,47}$'},
        'version': {'type': 'string', 'pattern': r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'},
        'description': TEXT,
        'catalogs': obj({k: {'type': 'object', 'additionalProperties': ref(k)} for k in AUTHORABLE}),
        'assets': {'type': 'object', 'additionalProperties': ref('asset')}, 'bindings': array(ref('binding')),
        # Explicit additions; never arbitrary patches or replacements of base definitions.
        'career_grants': array(obj({'career': ID, 'skills': array(ID, uniqueItems=True), 'passives': array(ID, uniqueItems=True)}, ('career',))),
        'career_links': array(obj({'parent': ID, 'child': ID}, ('parent', 'child'))),
        'acquisition': acquisition,
    }, ('format_version', 'pack_id', 'version', 'catalogs', 'assets', 'bindings'))
    schema.update({'$schema': 'https://json-schema.org/draft/2020-12/schema', '$id': 'https://mosslight.invalid/schemas/content-pack-v1.schema.json', '$defs': defs,
                   'x-melee-clip-lengths': MELEE_CLIP_LENGTHS})
    return schema


SCHEMA = build_schema()


def catalog_schema(name):
    return {'$schema': SCHEMA['$schema'], '$defs': SCHEMA['$defs'], 'type': 'object', 'minProperties': 1, 'additionalProperties': ref(name)}


if __name__ == '__main__':
    directory = Path(__file__).parent / 'schemas'
    directory.mkdir(exist_ok=True)
    (directory / 'content-pack-v1.schema.json').write_text(json.dumps(SCHEMA, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
