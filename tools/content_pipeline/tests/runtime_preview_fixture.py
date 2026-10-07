"""Compile the published example with procedural integration-test art only.

No generated file is production art. Every run uses a fresh input/output pair;
this script never activates content and never reads the player's save directory.
"""
from pathlib import Path
import json
import struct
import sys
import time
import zlib

PROJECT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(PROJECT / 'tools' / 'content_pipeline'))
from build import build


def png(path: Path, index: int) -> None:
    colors = [(44, 174, 143), (228, 164, 62), (58, 128, 210),
              (185, 85, 183), (104, 159, 70), (211, 89, 80), (74, 182, 197)]
    fill = colors[index % len(colors)]
    rows = bytearray()
    for y in range(64):
        rows.append(0)
        for x in range(64):
            border = x < 5 or y < 5 or x >= 59 or y >= 59
            mark = abs(x - y) < 4 or abs(x + y - 63) < 4
            color = (244, 235, 210) if mark else ((28, 35, 40) if border else fill)
            rows.extend((*color, 255))
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    data = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>2I5B', 64, 64, 8, 6, 0, 0, 0))
    path.write_bytes(data + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


def main():
    workspace = PROJECT / '.work' / 'rpg_content_runtime_20260930'
    run = workspace / ('run_' + str(time.time_ns()))
    source = run / 'input'
    assets = source / 'assets'
    assets.mkdir(parents=True)
    pack = json.loads((PROJECT / 'tools/content_pipeline/examples/trail_guard/pack.json').read_text('utf-8'))
    pack['description'] = 'TEST FIXTURE ONLY: six content families and procedural colored icon routing.'
    pack['catalogs']['items']['trail_guard:energy_token'] = {
        'id': 'trail_guard:energy_token', 'name': '测试蓄能符',
        'description': '仅用于联合测试的动作消耗品和测试图标。',
        'category': 'consumable', 'effect': 'action', 'cooldown': 120,
        'action': {
            'id': 'trail_guard:energy_token_action', 'name': '测试蓄能', 'is_skill': False,
            'presentation_type': 'VFX_ONLY', 'startup': 0.05, 'active': 0.08,
            'recovery': 0.1, 'cooldown': 90, 'costs': {}, 'gains': {},
            'targeting': 'SELF', 'conditions': [],
            'effects': [{'type': 'resource', 'resource': 'Energy', 'amount': 15, 'target': 'self'}],
        },
    }
    pack['assets'] = {}
    pack['bindings'] = []
    for index, (catalog, entry) in enumerate((catalog, entry)
            for catalog, definitions in pack['catalogs'].items() for entry in definitions):
        asset = 'trail_guard:test_icon_' + str(index)
        filename = 'assets/test_icon_' + str(index) + '.png'
        png(source / filename, index)
        pack['assets'][asset] = {
            'kind': 'icon', 'path': filename, 'width': 64, 'height': 64,
            'license': 'CC0-1.0',
            'source': 'Procedural colored X integration-test fixture; not production art',
        }
        pack['bindings'].append({'catalog': catalog, 'id': entry, 'assets': {'icon': asset}})
    pack_path = source / 'pack.json'
    pack_path.write_text(json.dumps(pack, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    output = run / 'compiled'
    report = build(PROJECT, [pack_path], output)
    (run / 'build-report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({'ok': report['ok'], 'bundle': str(output), 'errors': report.get('errors', [])}, ensure_ascii=False))
    if report['ok']:
        (workspace / 'latest-bundle.txt').write_text(str(output), encoding='utf-8')
    return 0 if report['ok'] else 1


if __name__ == '__main__':
    sys.exit(main())
