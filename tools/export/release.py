"""Build a fixed-content PCK release into a new immutable directory.

This packages an author-reviewed compiled bundle beside the PCK. It does not
modify project data or promote preview saves. Release verification uses a copy
of the complete staged directory outside the source checkout.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sys
import tempfile
import uuid

try:
    from . import build as exporter
except ImportError:  # Direct script execution
    import build as exporter


RELEASE_FORMAT = 1
RELEASE_ID = re.compile(r'^[a-z][a-z0-9_]{0,47}$')
SEMVER = re.compile(
    r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
    r'(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?'
    r'(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$'
)
RELEASE_TEST = exporter.PROJECT / 'tests/content_release.gd'


def digest_file(path: Path) -> str:
    with Path(path).open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def valid_semver(value: str) -> bool:
    match = SEMVER.fullmatch(str(value))
    if not match:
        return False
    prerelease = match.group(4)
    if prerelease:
        return not any(part.isdigit() and len(part) > 1 and part.startswith('0')
                       for part in prerelease.split('.'))
    return True


def _json(path: Path) -> dict:
    raw = path.read_bytes()
    value = json.loads(raw.decode('utf-8'))
    if not isinstance(value, dict):
        raise ValueError(f'Expected a JSON object: {path.name}')
    return value


def _linklike(path: Path) -> bool:
    is_junction = getattr(path, 'is_junction', None)
    return path.is_symlink() or (callable(is_junction) and is_junction())


def _reject_links_and_special(root: Path) -> None:
    """Reject links before reading or copying any file in an input bundle."""
    if _linklike(root) or not root.is_dir():
        raise ValueError('Compiled bundle must be a real directory, not a link')
    for directory, names, files in os.walk(root, followlinks=False):
        parent = Path(directory)
        for name in [*names, *files]:
            path = parent / name
            if _linklike(path):
                raise ValueError('Compiled bundle cannot contain symbolic links: ' + str(path))
            if path.is_dir():
                continue
            if not path.is_file():
                raise ValueError('Compiled bundle contains a non-regular file: ' + str(path))


def inspect_bundle(root: Path) -> dict:
    """Validate the bytes declared by a compiled bundle and return runtime identity."""
    root = Path(root).absolute()
    _reject_links_and_special(root)
    required = {'receipt.json', 'bundle.json', 'catalogs.json', 'assets'}
    if {entry.name for entry in root.iterdir()} != required:
        raise ValueError('Compiled bundle must contain exactly receipt.json, bundle.json, catalogs.json and assets/')

    receipt = _json(root / 'receipt.json')
    manifest_path = root / 'bundle.json'
    manifest_raw = manifest_path.read_bytes()
    manifest = json.loads(manifest_raw.decode('utf-8'))
    if not isinstance(manifest, dict):
        raise ValueError('bundle.json must be a JSON object')
    bundle_sha = hashlib.sha256(manifest_raw).hexdigest()
    if receipt != {'format_version': 1, 'bundle_sha256': bundle_sha}:
        raise ValueError('Compiled bundle receipt does not match bundle.json')

    catalogs_raw = (root / 'catalogs.json').read_bytes()
    catalogs_sha = hashlib.sha256(catalogs_raw).hexdigest()
    if manifest.get('catalogs_sha256') != catalogs_sha:
        raise ValueError('Compiled bundle catalogs hash does not match catalogs.json')
    if manifest.get('format_version') != 1 or manifest.get('contract') != 'mosslight-energy-v1':
        raise ValueError('Unsupported compiled bundle format or runtime contract')
    if manifest.get('catalogs_file') != 'catalogs.json':
        raise ValueError('Unsupported compiled bundle catalogs path')
    base = manifest.get('base_sha256')
    packs = manifest.get('packs')
    assets = manifest.get('assets')
    if not isinstance(base, dict) or not isinstance(packs, list) or not isinstance(assets, dict):
        raise ValueError('Compiled bundle is missing identity fields')

    declared_paths = {'receipt.json', 'bundle.json', 'catalogs.json'}
    for asset_id, metadata in assets.items():
        if not isinstance(metadata, dict):
            raise ValueError('Invalid asset metadata: ' + str(asset_id))
        relative = PurePosixPath(str(metadata.get('path', '')))
        if relative.is_absolute() or not relative.parts or any(part in ('', '.', '..') for part in relative.parts):
            raise ValueError('Unsafe compiled asset path: ' + str(metadata.get('path', '')))
        rel = relative.as_posix()
        if not rel.startswith('assets/'):
            raise ValueError('Compiled assets must be under assets/: ' + rel)
        path = root.joinpath(*relative.parts)
        # Confirm every path component is a real directory/file, not a link.
        cursor = root
        for part in relative.parts:
            cursor = cursor / part
            if _linklike(cursor):
                raise ValueError('Compiled assets cannot traverse links: ' + rel)
        if not path.is_file():
            raise ValueError('Compiled asset is missing: ' + rel)
        raw = path.read_bytes()
        if len(raw) != metadata.get('bytes') or hashlib.sha256(raw).hexdigest() != metadata.get('sha256'):
            raise ValueError('Compiled asset bytes/hash mismatch: ' + str(asset_id))
        declared_paths.add(rel)
    actual_files = {path.relative_to(root).as_posix() for path in root.rglob('*') if path.is_file()}
    if actual_files != declared_paths:
        raise ValueError('Compiled bundle files differ from their manifest declarations')

    return {
        'format_version': 1,
        'contract': manifest['contract'],
        'bundle_sha256': bundle_sha,
        'catalogs_sha256': catalogs_sha,
        'base_sha256': base,
        'packs': packs,
    }


def _tree_hashes(root: Path) -> dict[str, str]:
    _reject_links_and_special(root)
    return {path.relative_to(root).as_posix(): digest_file(path)
            for path in sorted(root.rglob('*')) if path.is_file()}


def copy_bundle_verified(source: Path, destination: Path, expected_hashes: dict[str, str] | None = None) -> dict:
    source = Path(source).absolute()
    destination = Path(destination).absolute()
    source_identity = inspect_bundle(source)
    source_hashes = _tree_hashes(source)
    if expected_hashes is not None and source_hashes != expected_hashes:
        raise ValueError('Compiled bundle changed after release preflight')
    if destination.exists() or destination.is_symlink():
        raise ValueError('Bundle destination already exists')
    shutil.copytree(source, destination, symlinks=True)
    if _tree_hashes(source) != source_hashes or _tree_hashes(destination) != source_hashes:
        raise ValueError('Copied bundle file inventory or bytes differ from source')
    copied_identity = inspect_bundle(destination)
    if copied_identity != source_identity:
        raise ValueError('Copied bundle identity differs from source')
    return copied_identity


def smoke_release(engine: Path, release_root: Path, log_dir: Path) -> dict:
    """Run the release bootstrap against a full temporary copy of its directory."""
    if not RELEASE_TEST.is_file():
        raise ValueError('Release smoke script is missing: ' + str(RELEASE_TEST))
    workspace = Path(tempfile.mkdtemp(prefix='mosslight-release-smoke-'))
    runtime = workspace / 'release'
    shutil.copytree(release_root, runtime, symlinks=True)
    _reject_links_and_special(runtime)
    if _tree_hashes(runtime) != _tree_hashes(release_root):
        raise ValueError('Isolated release copy differs from staged release')
    shutil.copy2(RELEASE_TEST, workspace / 'content_release.gd')
    storage = workspace / 'storage'
    storage.mkdir()
    argv = [str(Path(engine).resolve(strict=True)), '--headless', '--path', str(runtime),
            '--main-pack', str(runtime / 'MosslightRPG.pck'), '--log-file', str(workspace / 'engine.log'),
            '--script', str((workspace / 'content_release.gd').resolve()), '--', '--release-root=' + runtime.as_posix(),
            '--mode=valid', '--storage-root=' + storage.as_posix()]
    result = exporter.run(argv, runtime, log_dir, 'release-smoke', 180)
    result['workspace'] = str(workspace)
    result['errors'] = exporter.errors_in(log_dir, 'release-smoke')
    result['runtime_report'] = None
    runtime_report = storage / 'release-smoke-report.json'
    if runtime_report.is_file():
        result['runtime_report'] = _json(runtime_report)
    # Explicit test report and exit status are both required; Godot ERROR
    # markers remain fatal even if the test reports success.
    report = result['runtime_report']
    report_ok = (isinstance(report, dict) and report.get('ok') is True
                 and type(report.get('checks')) is int and report['checks'] > 0
                 and isinstance(report.get('failures'), list)
                 and not report['failures'])
    if result['returncode'] != 0 or not report_ok or result['errors']:
        raise RuntimeError('Release bootstrap smoke failed; inspect ' + str(workspace))
    return result


def smoke_native_release(release_root: Path, log_dir: Path) -> dict:
    """Exercise natural EXE startup with no path overrides or game test flags.

    Windows Godot uses APPDATA for user data and LOCALAPPDATA for caches. These
    overrides exist only in this child process; no real player directory is
    inspected or modified. This checks local headless title/bootstrap startup,
    not gameplay, GPU output, or compatibility with another Windows machine.
    """
    if os.name != 'nt':
        raise RuntimeError('Native Windows release smoke must run on Windows')
    source_hashes = _tree_hashes(release_root)
    required = {'MosslightRPG.exe', 'MosslightRPG.pck', 'release.json', 'source-manifest.json'}
    if not required.issubset(source_hashes):
        raise ValueError('Native release is missing its adjacent executable, pack or manifests')
    workspace = Path(tempfile.mkdtemp(prefix='mosslight-native-release-'))
    runtime = workspace / 'release with spaces'
    shutil.copytree(release_root, runtime, symlinks=True)
    if _tree_hashes(runtime) != source_hashes:
        raise ValueError('Native isolated release copy differs from staged release')
    cwd = workspace / 'unrelated working directory'
    cwd.mkdir()
    environment = os.environ.copy()
    isolated_environment = {}
    for key, directory in [('APPDATA', 'roaming'), ('LOCALAPPDATA', 'local'),
                           ('USERPROFILE', 'profile'), ('TEMP', 'temp'), ('TMP', 'temp')]:
        path = workspace / directory
        path.mkdir(exist_ok=True)
        environment[key] = str(path)
        isolated_environment[key] = str(path)
    engine_log = workspace / 'native-engine.log'
    executable = runtime / 'MosslightRPG.exe'
    argv = [str(executable), '--headless', '--quit-after', '120', '--log-file', str(engine_log)]
    result = exporter.run(argv, cwd, log_dir, 'native-release-smoke', 180, env=environment)
    result.update(workspace=str(workspace), executable_sha256=digest_file(executable),
                  pck_sha256=digest_file(runtime / 'MosslightRPG.pck'),
                  isolated_environment=isolated_environment,
                  verification_scope='local_headless_native_bootstrap')
    traces = [(log_dir / ('native-release-smoke' + suffix)).read_text('utf-8', errors='replace')
              for suffix in ('.stdout.log', '.stderr.log')]
    # The GUI-subsystem executable need not attach stdout. The engine log is
    # the primary trace, with stdout as a fallback; do not count both copies.
    primary_trace = engine_log.read_text('utf-8', errors='replace') if engine_log.is_file() else traces[0]
    traces.append(primary_trace)
    result['errors'] = sorted({line for trace in traces for line in trace.splitlines()
                               if any(marker in line for marker in ('SCRIPT ERROR:', 'ERROR:', 'Parse Error:', 'GAME_STARTUP_REFUSED'))})
    result['warnings'] = sorted({line for trace in traces for line in trace.splitlines() if 'WARNING:' in line})
    events = []
    for line in primary_trace.splitlines():
        if line.startswith('GAME_STARTUP '):
            try:
                events.append(json.loads(line.removeprefix('GAME_STARTUP ')))
            except json.JSONDecodeError:
                result['errors'].append('Malformed GAME_STARTUP report')
    manifest = _json(runtime / 'release.json')
    expected_identity = manifest['content'].get('identity', {})
    startup_ok = (len(events) == 1 and isinstance(events[0], dict)
                  and events[0].get('formal') is True and events[0].get('identity') == expected_identity)
    result['startup'] = events[0] if len(events) == 1 else None
    namespace = Path('releases') / manifest['release_id'] / expected_identity.get('bundle_sha256', 'builtin')
    # Bootstrap creates its preferences parent before constructing App. Discover
    # it only inside our child APPDATA; never query the machine's user location.
    profiles = Path(isolated_environment['APPDATA'])
    formal_directories = [path for path in profiles.rglob(namespace.name)
                          if path.is_dir() and path.parts[-3:] == namespace.parts]
    result['formal_directories'] = [str(path) for path in formal_directories]
    unchanged = _tree_hashes(runtime) == source_hashes
    # Harness logs are new files in stage; all previously staged bytes must stay
    # fixed and will be checked again before final publication.
    current_hashes = _tree_hashes(release_root)
    unchanged = unchanged and all(current_hashes.get(name) == value for name, value in source_hashes.items())
    result['release_bytes_unchanged'] = unchanged
    result['ok'] = (result['returncode'] == 0 and not result['errors'] and startup_ok
                    and len(formal_directories) == 1 and unchanged)
    _write_json_new(log_dir / 'native-release-smoke-report.json', result)
    if not result['ok']:
        raise RuntimeError('Native release bootstrap smoke failed; inspect ' + str(workspace))
    return result


def _write_json_new(path: Path, value: dict) -> None:
    with path.open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write('\n')


def build(engine, output, release_id, version, bundle=None, debug_exe=False, release_exe=False) -> dict:
    native_exe = debug_exe or release_exe
    exe_field = "release_exe" if release_exe else "debug_exe"
    output = Path(output).absolute()
    result = {'ok': False, 'status': 'failed', 'release_id': release_id, 'version': version,
              'output': str(output), 'staging': '', 'errors': []}
    stage = None
    try:
        if debug_exe and release_exe:
            raise ValueError('Choose only one executable template')
        if not RELEASE_ID.fullmatch(str(release_id)):
            raise ValueError('release_id must match ^[a-z][a-z0-9_]{0,47}$')
        if not valid_semver(version):
            raise ValueError('version must be semantic versioning with optional prerelease/build metadata')
        if _linklike(output):
            raise ValueError('Output cannot be a symbolic link or junction')
        if output.exists():
            raise ValueError('Output must be a new directory; existing releases are immutable')
        if not output.parent.is_dir():
            raise ValueError('Output parent must already exist')
        output = output.parent.resolve() / output.name
        project = exporter.PROJECT.resolve()
        input_bundle = None
        bundle_hashes = None
        if bundle is not None:
            input_bundle = Path(bundle).absolute()
            _reject_links_and_special(input_bundle)
            input_bundle = input_bundle.resolve(strict=True)
            bundle_hashes = _tree_hashes(input_bundle)
            if output == input_bundle or output.is_relative_to(input_bundle) or input_bundle.is_relative_to(output):
                raise ValueError('Release output must not overlap the compiled bundle source')
        for root_name in exporter.SOURCE_ROOTS:
            source_root = (project / root_name).resolve()
            if output == source_root or output.is_relative_to(source_root) or source_root.is_relative_to(output):
                raise ValueError('Release output must not overlap a project source root: ' + root_name)
        stage = output.parent / ('.' + output.name + '.staging-' + uuid.uuid4().hex)
        result['staging'] = str(stage)

        bundle_path = input_bundle
        bundle_identity = inspect_bundle(bundle_path) if bundle_path is not None else {}
        template_options = {"release_exe": True} if release_exe else {}
        exported = exporter.build(engine, stage, debug_exe=debug_exe, content_bundle=bundle_path, **template_options)
        result['export'] = exported
        if not exported.get('ok') or not exported.get('pck_verified'):
            raise RuntimeError('Base PCK export and smoke did not pass')
        if bundle_path is not None and not exported.get('external_bundle_smoke', {}).get('report', {}).get('ok'):
            raise RuntimeError('Compiled bundle smoke against the exported PCK did not pass')

        if bundle_path is not None:
            copied_identity = copy_bundle_verified(bundle_path, stage / 'content', bundle_hashes)
            if copied_identity != bundle_identity:
                raise RuntimeError('Bundle changed between preflight and release copy')
            content_field = {'path': 'content', 'identity': copied_identity}
        else:
            content_field = {}
        pck_path = stage / 'MosslightRPG.pck'
        source_manifest_path = stage / 'source-manifest.json'
        if not pck_path.is_file() or not source_manifest_path.is_file():
            raise RuntimeError('Export omitted the PCK or source manifest')
        if digest_file(pck_path) != exported.get('pck_sha256'):
            raise RuntimeError('Staged PCK differs from the bytes verified by the export smoke')
        exe_path = stage / 'MosslightRPG.exe'
        if native_exe:
            executable = exported.get(exe_field, {})
            if (not exe_path.is_file() or exe_path.stat().st_size == 0
                    or digest_file(exe_path) != executable.get('sha256')):
                raise RuntimeError('Staged native executable is missing or differs from the exported binary')
        release = {
            'format_version': RELEASE_FORMAT,
            'release_id': release_id,
            'version': version,
            'engine_version': exported['engine_version'],
            'source_manifest_sha256': digest_file(source_manifest_path),
            'pck': {'path': 'MosslightRPG.pck', 'sha256': digest_file(pck_path)},
            'content': content_field,
        }
        _write_json_new(stage / 'release.json', release)

        runtime = smoke_release(Path(engine), stage, stage)
        native_runtime = smoke_native_release(stage, stage) if native_exe else None
        if native_exe and (not native_runtime or native_runtime.get('ok') is not True):
            raise RuntimeError('Native release startup did not pass')
        if digest_file(pck_path) != release['pck']['sha256']:
            raise RuntimeError('Staged PCK changed after release verification')
        if native_exe and digest_file(exe_path) != exported[exe_field]['sha256']:
            raise RuntimeError('Staged native executable changed after release verification')
        expected_sources = _json(stage / 'source-manifest.json')
        if exporter.source_manifest() != expected_sources:
            raise RuntimeError('Project source inputs changed before final release publication')
        if bundle_path is not None and _tree_hashes(bundle_path) != bundle_hashes:
            raise RuntimeError('Compiled bundle source changed before final release publication')
        result['release'] = release
        result['release_smoke'] = runtime
        exported['release'] = release
        exported['release_smoke'] = runtime
        exported['output'] = str(output)
        exported['pck'] = str(output / 'MosslightRPG.pck')
        if native_exe:
            result['native_release_smoke'] = native_runtime
            exported['native_release_smoke'] = native_runtime
            exported[exe_field].update(path=str(output / 'MosslightRPG.exe'), runtime_verified=True,
                                         verification_scope='local_headless_native_bootstrap')
            exported['native_bootstrap_verified'] = True
            exported['native_bootstrap_verification_scope'] = 'local_headless_native_bootstrap'
            # The existing broad EXE acceptance flag includes GPU, input,
            # audio, storage, gameplay and longer target-machine testing.
            exported['independent_exe_verified'] = False
            exported['target_machine_and_long_term_verified'] = False
        (stage / 'report.json').write_text(json.dumps(exported, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        if _linklike(output) or output.exists():
            raise ValueError('Output appeared during release build; refusing to replace it')
        os.rename(stage, output)
        stage = None
        result.update(ok=True, status='release_verified', output=str(output), staging='')
        result['export'] = exported
    except (OSError, ValueError, RuntimeError, KeyError, json.JSONDecodeError) as exc:
        result['errors'].append(str(exc))
        if stage is not None:
            if not stage.exists() and not stage.is_symlink():
                stage.mkdir()
            if stage.is_dir() and not stage.is_symlink():
                result['staging'] = str(stage)
            else:
                stage = None
        if stage is not None:
            diagnostic = stage / 'release-build-report.json'
            if not diagnostic.exists():
                try:
                    _write_json_new(diagnostic, result)
                except OSError as write_error:
                    result['errors'].append('Could not write staging diagnostic: ' + str(write_error))
    return result


def main(argv=None) -> int:
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--engine', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--release-id', required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--bundle', type=Path, help='Reviewed compiled content bundle directory')
    parser.add_argument('--debug-exe', action='store_true', help='Export the installed debug template and verify native startup before publication')
    parser.add_argument('--release-exe', action='store_true', help='Export the Release template and verify native startup before publication')
    args = parser.parse_args(argv)
    result = build(args.engine, args.output, args.release_id, args.version, args.bundle, args.debug_exe, args.release_exe)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result['ok'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
