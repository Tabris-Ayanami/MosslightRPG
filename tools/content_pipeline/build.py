"""Compile reviewed JSON packs into a reproducible, immutable preview directory.

No activation, game data changes, generated code execution or save writes occur.
The receipt detects accidental changes; it is not a signature/trust boundary.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile

from PIL import Image

try:
    from .schema import CATALOGS
    from .validate import validate
except ImportError:
    from schema import CATALOGS
    from validate import validate

CONTRACT = 'mosslight-energy-v1'
FORMAT = 1
MAX_BUNDLE_BYTES = 256 * 1024 * 1024
MAX_CATALOG_BYTES = 16 * 1024 * 1024
MAX_MANIFEST_BYTES = 4 * 1024 * 1024
MAX_IMAGE_SIDE = 4096
MAX_IMAGE_PIXELS = 4194304
MAX_IMAGE_MEMORY = 128 * 1024 * 1024
MAX_ICON_SIDE = 512


def display_size(width, height, kind):
    """Only the runtime icon cache is reduced; compiled image bytes stay intact."""
    longest = max(width, height)
    if kind != 'icon' or longest <= MAX_ICON_SIDE:
        return width, height
    return max(1, width * MAX_ICON_SIDE // longest), max(1, height * MAX_ICON_SIDE // longest)


def cache_memory_bytes(width, height):
    base_pixels = width * height
    mip_pixels = base_pixels
    while width > 1 or height > 1:
        width, height = max(1, width // 2), max(1, height // 2)
        mip_pixels += width * height
    # Narrow images can approach twice the base pixels in their mip chain.
    # Cover retained CPU and GPU RGBA8 copies without reducing normal capacity.
    return max(base_pixels * 12, mip_pixels * 8)


def check_png_end(raw):
    # Pillow validates CRC/pixels but permits trailing bytes. Godot's bundle
    # contract requires the complete PNG chunk stream to end at its first IEND.
    offset = 8
    while offset + 12 <= len(raw):
        length = int.from_bytes(raw[offset:offset + 4], 'big')
        end = offset + length + 12
        if end > len(raw):
            break
        if raw[offset + 4:offset + 8] == b'IEND':
            if length == 0 and end == len(raw):
                return
            break
        offset = end
    raise ValueError('PNG chunks are truncated or have trailing bytes after IEND')


def check_json_budget(value, depth=0, budget=None):
    budget = [0] if budget is None else budget
    budget[0] += 1
    if depth > 32 or budget[0] > 500000:
        raise ValueError('Runtime JSON depth or node budget exceeded')
    children = value.values() if isinstance(value, dict) else value if isinstance(value, list) else ()
    for child in children:
        check_json_budget(child, depth + 1, budget)


def check_preview_contract(merged, packs, frozen):
    """Bounds consumed by ContentBundle; semantic validation already ran."""
    if len(packs) > 128 or len(merged['assets']) > 2048 or len(merged['bindings']) > 16384:
        raise ValueError('Runtime pack, asset or binding count budget exceeded')
    def check_id(content_id):
        if len(content_id) > 160 or not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*(?::[a-z][a-z0-9_]{0,95})?', content_id):
            raise ValueError('Runtime content ID length or syntax is unsupported: ' + content_id)
    for name, catalog in merged['catalogs'].items():
        if not catalog or len(catalog) > 16384:
            raise ValueError('Runtime catalog count budget exceeded: ' + name)
        for content_id in catalog:
            check_id(content_id)
    bindings = set()
    for binding in merged['bindings']:
        key = (binding['catalog'], binding['id'])
        if not binding['assets'] or key in bindings:
            raise ValueError('Runtime bindings must be nonempty and unique per catalog/id')
        bindings.add(key)
    pack_roots = {entry['pack_id']: Path(entry['path']).parent for entry in packs}
    image_memory = 0
    decode_workspace = 0
    for asset_id, metadata in merged['assets'].items():
        check_id(asset_id)
        source = (pack_roots[asset_id.split(':', 1)[0]] / metadata['path']).resolve()
        if 'sha256' in metadata and metadata['sha256'] != digest(frozen[source]):
            raise ValueError('Pinned asset digest differs from frozen bytes: ' + asset_id)
        if source.suffix.lower() != '.png':
            continue
        raw = frozen[source]
        check_png_end(raw)
        try:
            with Image.open(io.BytesIO(raw)) as picture:
                width, height = picture.size
                if width > MAX_IMAGE_SIDE or height > MAX_IMAGE_SIDE or width * height > MAX_IMAGE_PIXELS:
                    raise ValueError('PNG dimensions exceed the runtime preview budget: ' + asset_id)
                cached_width, cached_height = display_size(width, height, metadata['kind'])
                image_memory += cache_memory_bytes(cached_width, cached_height)
                if (cached_width, cached_height) != (width, height):
                    # One source at a time: decode, RGBA conversion and resize
                    # may coexist. Reserve this in addition to all caches.
                    decode_workspace = max(decode_workspace, width * height * 16)
                if image_memory + decode_workspace > MAX_IMAGE_MEMORY:
                    raise ValueError('PNG decoded memory exceeds the runtime 128 MiB budget')
                if picture.format != 'PNG' or getattr(picture, 'is_animated', False):
                    raise ValueError('Preview image must be a static PNG: ' + asset_id)
                picture.verify()
            # verify checks chunks/CRC; load separately exercises pixel decoding.
            with Image.open(io.BytesIO(raw)) as picture:
                picture.load()
        except (OSError, SyntaxError, Image.DecompressionBombError) as exc:
            raise ValueError('PNG decode failed for ' + asset_id + ': ' + str(exc)) from exc
    check_json_budget(merged['catalogs'])


def digest(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def encode(value) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'),
                       allow_nan=False) + '\n').encode('utf-8')


def build(project: Path, pack_paths, output: Path) -> dict:
    """Create a new bundle directory, or leave the destination absent on failure."""
    project = Path(project).resolve()
    packs = sorted((Path(path).resolve() for path in pack_paths), key=str)
    output = Path(output).absolute()
    result = validate(project, packs)
    if result.report['ok']:
        canonical_paths = [Path(entry['path']) for entry in sorted(result.report['packs'], key=lambda entry: entry['pack_id'])]
        if canonical_paths != packs:
            # Grant/branch list order must be independent of filesystem layout
            # and of the scheduler's arrival order for parallel AI jobs.
            result = validate(project, canonical_paths)
    report = copy.deepcopy(result.report)
    report.update(mode='build', output=str(output), bundle_sha256='')
    for warning in report.get('warnings', []):
        if warning.get('code') == 'pack.offline_only':
            warning['message'] = 'The bundle is compiled for review but is not activated or released by this command.'
    if not report['ok']:
        return report
    staging = None
    try:
        if not packs:
            raise ValueError('Provide at least one reviewed content pack')
        # Do not follow an existing output link, overwrite a build, or place a
        # build inside its own source. The caller chooses a separate directory.
        if output.exists() or output.is_symlink():
            raise ValueError('Output must be a new directory; existing builds are immutable')
        if not output.parent.is_dir():
            raise ValueError('Output parent must already exist')
        output = output.parent.resolve() / output.name
        forbidden = [project / 'data', *(path.parent for path in packs)]
        if any(output.is_relative_to(root) or root.is_relative_to(output) for root in forbidden):
            raise ValueError('Output must not overlap game data or pack sources')
        inputs = report['input_sha256']
        # Freeze the bytes actually validated. A concurrent generator editing a
        # draft must cause a rebuild, not a partially old / partially new bundle.
        frozen = {}
        total = 0
        for name, expected in inputs.items():
            path = Path(name)
            if path.stat().st_size > MAX_BUNDLE_BYTES - total:
                raise ValueError('Bundle sources exceed the 256 MiB limit')
            raw = path.read_bytes()
            if digest(raw) != expected:
                raise ValueError('Input changed during validation: ' + str(path))
            total += len(raw)
            if total > MAX_BUNDLE_BYTES:
                raise ValueError('Bundle sources exceed the 256 MiB limit')
            frozen[path.resolve()] = raw
        check_preview_contract(result.merged, report['packs'], frozen)
        catalogs_raw = encode(result.merged['catalogs'])
        if len(catalogs_raw) > MAX_CATALOG_BYTES:
            raise ValueError('Merged catalogs exceed the 16 MiB limit')
        staging = Path(tempfile.mkdtemp(prefix='.' + output.name + '-build-', dir=output.parent))
        (staging / 'assets').mkdir()
        (staging / 'catalogs.json').write_bytes(catalogs_raw)
        assets = {}
        pack_roots = {entry['pack_id']: Path(entry['path']).parent for entry in report['packs']}
        for asset_id, metadata in sorted(result.merged['assets'].items()):
            root = pack_roots[asset_id.split(':', 1)[0]]
            source = (root / metadata['path']).resolve()
            raw = frozen[source]
            sha = digest(raw)
            relative = 'assets/' + sha + source.suffix.lower()
            (staging / relative).write_bytes(raw)
            assets[asset_id] = {**metadata, 'path': relative, 'sha256': sha, 'bytes': len(raw)}
        bundle = {
            'format_version': FORMAT,
            'contract': CONTRACT,
            'catalogs_file': 'catalogs.json',
            'catalogs_sha256': digest(catalogs_raw),
            'base_sha256': {name: inputs[str((project / 'data/combat' / (name + '.json')).resolve())]
                            for name in CATALOGS},
            'packs': sorted(({'pack_id': entry['pack_id'], 'version': entry['version'],
                              'sha256': inputs[str(Path(entry['path']).resolve())]}
                             for entry in report['packs']), key=lambda entry: entry['pack_id']),
            'assets': assets,
            'bindings': sorted(result.merged['bindings'], key=lambda entry: (entry['catalog'], entry['id'])),
        }
        acquisition = result.merged.get('acquisition')
        if acquisition is not None:
            # These references must name the exact world JSON bytes included in
            # this compiler's frozen inputs. Keep additions out of the twelve
            # combat catalogs; runtime derives shops/quests/drop tables once.
            for name in ('shops', 'quests'):
                source_path = str((project / 'data/world' / (name + '.json')).resolve())
                if acquisition.get('world_base_sha256', {}).get(name) != inputs.get(source_path):
                    raise ValueError('Acquisition world fingerprint differs from frozen input: ' + name)
            bundle['acquisition'] = copy.deepcopy(acquisition)
        bundle_raw = encode(bundle)
        check_json_budget(bundle)
        if len(bundle_raw) > MAX_MANIFEST_BYTES:
            raise ValueError('Manifest exceeds the runtime 4 MiB limit')
        payload_bytes = sum(path.stat().st_size for path in (staging / 'assets').iterdir())
        if payload_bytes + len(bundle_raw) + len(catalogs_raw) + 4096 > MAX_BUNDLE_BYTES:
            raise ValueError('Compiled files exceed the runtime 256 MiB budget')
        sha = digest(bundle_raw)
        (staging / 'bundle.json').write_bytes(bundle_raw)
        (staging / 'receipt.json').write_bytes(encode({'format_version': FORMAT, 'bundle_sha256': sha}))
        # The audit report is informational, not consumed by the game. Avoid
        # embedding host-specific paths/timestamps in the reproducible payload.
        report.update(ok=True, output=str(output), bundle_sha256=sha)
        for name, expected in inputs.items():
            if digest(Path(name).read_bytes()) != expected:
                raise ValueError('Input changed before publication: ' + name)
        if output.exists() or output.is_symlink():
            raise ValueError('Output appeared during build; refusing to replace it')
        os.rename(staging, output)
        staging = None
    except (OSError, ValueError, KeyError) as exc:
        report['ok'] = False
        report['bundle_sha256'] = ''
        report['errors'].append({'code': 'build.failed', 'path': str(output), 'message': str(exc)})
    finally:
        if staging is not None:
            # Only the exact temporary child returned above is removed.
            assert staging.parent.resolve() == output.parent.resolve()
            shutil.rmtree(staging)
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--pack', type=Path, action='append', required=True)
    parser.add_argument('--output', type=Path, required=True, help='New directory under an existing parent')
    args = parser.parse_args(argv)
    report = build(args.project, args.pack, args.output)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report['ok'] else 1


if __name__ == '__main__':
    sys.exit(main())
