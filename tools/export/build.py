"""Export a version-pinned Windows PCK and smoke it outside the source checkout.

No downloads, template installation, source edits, player data access or GPU test.
An optional EXE uses one debug/release-template export, then verifies its exact companion
PCK. Native release startup is checked separately by release.py.
"""
from __future__ import annotations

import argparse
import configparser
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

PROJECT = Path(__file__).resolve().parents[2]
ENGINE_VERSION = '4.7.2.stable'
PRESET = 'Windows Debug'
SOURCE_ROOTS = ('addons', 'assets', 'combat', 'data', 'rpg', 'scenes', 'scripts', 'shaders')


def digest(path):
    with Path(path).open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def write_new(path, data):
    with Path(path).open('x', encoding='utf-8') as output:
        json.dump(data, output, ensure_ascii=False, indent=2)
        output.write('\n')


def source_manifest():
    preset = configparser.ConfigParser(interpolation=None)
    preset.read(PROJECT / 'export_presets.cfg', encoding='utf-8')
    excludes = preset['preset.0']['exclude_filter'].strip('"').split(',')
    files = [PROJECT / name for name in ('project.godot', 'export_presets.cfg', 'default_bus_layout.tres', 'icon.svg', 'icon.svg.import')]
    for name in SOURCE_ROOTS:
        files.extend(path for path in (PROJECT / name).rglob('*') if path.is_file()
                     and not any(part.startswith('.') for part in path.relative_to(PROJECT).parts)
                     and not any(fnmatch.fnmatchcase(path.relative_to(PROJECT).as_posix(), pattern) for pattern in excludes))
    return {path.relative_to(PROJECT).as_posix(): digest(path) for path in sorted(files)}


def templates(engine):
    data = Path(os.environ.get('APPDATA', str(Path.home() / 'AppData/Roaming'))) / 'Godot/export_templates'
    if any((engine.parent / name).exists() for name in ('_sc_', '._sc_')):
        data = engine.parent / 'editor_data/export_templates'
    directory = data / ENGINE_VERSION
    required = [directory / 'windows_debug_x86_64.exe', directory / 'windows_release_x86_64.exe']
    return {'directory': str(directory), 'directory_exists': directory.is_dir(),
            'windows_debug_x86_64': str(required[0]), 'debug_available': required[0].is_file(),
            'windows_release_x86_64': str(required[1]), 'release_available': required[1].is_file()}


def debug_template(report, mode="debug"):
    """Pin the actual non-embedded x86_64 template used by our fixed preset."""
    preset = configparser.ConfigParser(interpolation=None)
    preset.read(PROJECT / 'export_presets.cfg', encoding='utf-8')
    options = preset['preset.0.options']
    if options.get('binary_format/embed_pck', '').lower() != 'false':
        raise ValueError('Native EXE requires a separate companion PCK; embedded packs are not supported')
    if options.get('binary_format/architecture', '').strip('"') != 'x86_64':
        raise ValueError('Native EXE requires the Windows x86_64 preset')
    if options.get('custom_template/' + mode, '').strip('"'):
        raise ValueError('Native EXE requires the installed version-matched template, not a custom override')
    if not report['templates'][mode + '_available']:
        raise RuntimeError('Selected Windows x86_64 template is missing; no standalone EXE exported')
    path = Path(report['templates']['windows_' + mode + '_x86_64'])
    if not path.is_file() or path.stat().st_size == 0:
        raise RuntimeError('Selected Windows x86_64 template is missing or empty')
    return path, digest(path)


def run(argv, cwd, log_dir, label, timeout, env=None):
    started = time.monotonic()
    with (log_dir / (label + '.stdout.log')).open('xb') as stdout, (log_dir / (label + '.stderr.log')).open('xb') as stderr:
        process = subprocess.Popen(argv, cwd=cwd, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
                                   env=env, creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)
            raise RuntimeError(label + ' exceeded its finite timeout')
    return {'argv': [str(arg) for arg in argv], 'cwd': str(cwd), 'returncode': code,
            'seconds': round(time.monotonic() - started, 3)}


def errors_in(log_dir, label):
    result = []
    for suffix in ('.stdout.log', '.stderr.log'):
        path = log_dir / (label + suffix)
        for line in path.read_text('utf-8', errors='replace').splitlines():
            if any(marker in line for marker in ('SCRIPT ERROR:', 'ERROR:', 'Parse Error:')):
                result.append(line)
    return result


def smoke(engine, pck, destination, expected, bundle=None):
    expected_pck_sha = digest(pck)
    workspace = Path(tempfile.mkdtemp(prefix='mosslight-export-smoke-'))
    shutil.copy2(pck, workspace / pck.name)
    shutil.copy2(PROJECT / 'tests/export_smoke.gd', workspace / 'export_smoke.gd')
    write_new(workspace / 'expected-data.json', expected)
    argv = [str(engine), '--headless', '--path', str(workspace), '--main-pack', str(workspace / pck.name),
            '--log-file', str(workspace / 'smoke-engine.log'), '--script', str(workspace / 'export_smoke.gd'),
            '--', '--workspace=' + workspace.as_posix()]
    if bundle:
        copied_bundle = workspace / 'external-bundle'
        # Preserve prohibited links so the runtime validator can reject them;
        # never dereference a compiled bundle's links during the copy itself.
        shutil.copytree(bundle, copied_bundle, symlinks=True)
        argv.append('--bundle=' + copied_bundle.as_posix())
    result = run(argv, workspace, destination, 'smoke-external' if bundle else 'smoke', 180)
    result['workspace'] = str(workspace)
    result['pck_sha256'] = digest(workspace / pck.name)
    report = workspace / 'smoke-report.json'
    result['report'] = json.loads(report.read_text('utf-8')) if report.is_file() else None
    result['errors'] = errors_in(destination, 'smoke-external' if bundle else 'smoke')
    for name in ('smoke-report.json', 'pck-files.json'):
        if (workspace / name).is_file():
            shutil.copy2(workspace / name, destination / (('external-' if bundle else '') + name))
    if (result['returncode'] or not result['report'] or not result['report']['ok'] or result['errors']
            or result['pck_sha256'] != expected_pck_sha or digest(pck) != expected_pck_sha):
        raise RuntimeError('PCK smoke failed; inspect logs and isolated workspace ' + str(workspace))
    return result


def build(engine, output, debug_exe=False, content_bundle=None, release_exe=False):
    if debug_exe and release_exe:
        raise ValueError("Choose only one executable template")
    native_exe = debug_exe or release_exe
    exe_field = "release_exe" if release_exe else "debug_exe"
    engine = Path(engine).resolve(strict=True)
    output = Path(output).absolute()
    if not output.parent.is_dir():
        raise ValueError('Output parent must exist; the output directory itself must be new')
    output.mkdir()
    report = {'ok': False, 'status': 'failed', 'pck_verified': False, 'independent_exe_verified': False,
              'project': str(PROJECT), 'output': str(output), 'errors': []}
    try:
        version = subprocess.check_output([str(engine), '--version'], timeout=15, text=True).strip()
        if not version.startswith(ENGINE_VERSION + '.'):
            raise ValueError('Use the tested Godot ' + ENGINE_VERSION + ' editor, got ' + version)
        engine_files = {str(engine): digest(engine)}
        host = engine.with_name(engine.name.replace('_console.exe', '.exe'))
        if host != engine and host.is_file(): engine_files[str(host)] = digest(host)
        report.update(engine_version=version, engine_sha256=digest(engine), engine_files=engine_files, templates=templates(engine),
                      smoke_script_sha256=digest(PROJECT / 'tests/export_smoke.gd'))
        before = source_manifest()
        write_new(output / 'source-manifest.json', before)
        pck = output / 'MosslightRPG.pck'
        exe = output / 'MosslightRPG.exe'
        template = None
        template_sha = None
        if native_exe:
            template, template_sha = debug_template(report, "release" if release_exe else "debug")
        argv = [str(engine), '--headless', '--path', str(PROJECT), '--log-file', str(output / 'export-engine.log'),
                '--export-release' if release_exe else ('--export-debug' if debug_exe else '--export-pack'), PRESET, str(exe if native_exe else pck)]
        report['export'] = run(argv, PROJECT, output, 'export', 600)
        export_errors = errors_in(output, 'export')
        # The installed Dialogue Manager editor UI checks GitHub for updates on
        # startup. Its TLS failure is retained explicitly, not mistaken for a
        # pack/build failure. Every other engine error fails, and this exception
        # is usable only after the real isolated runtime smoke passes below.
        report['editor_network_diagnostics'] = [line for line in export_errors if line.startswith('ERROR: TLS handshake error:')]
        fatal_errors = [line for line in export_errors if line not in report['editor_network_diagnostics']]
        if report['export']['returncode'] or not pck.is_file() or pck.stat().st_size == 0 or fatal_errors:
            raise RuntimeError('PCK export failed: ' + '; '.join(fatal_errors[:8]))
        if native_exe:
            if not exe.is_file() or exe.stat().st_size == 0:
                raise RuntimeError('Native template export omitted a nonempty MosslightRPG.exe')
            exe_sha = digest(exe)
            if exe_sha in engine_files.values():
                raise RuntimeError('Exported executable is the editor binary, not a template application')
            report[exe_field] = {'path': str(exe), 'sha256': exe_sha, 'bytes': exe.stat().st_size,
                                   'template_sha256': template_sha, 'runtime_verified': False}
        after = source_manifest()
        changed = sorted(path for path in before.keys() | after.keys() if before.get(path) != after.get(path))
        if changed:
            report['changed_sources'] = changed
            raise RuntimeError('Source files changed during export; preserve this build and rerun into a new directory')
        report.update(pck=str(pck), pck_sha256=digest(pck), pck_bytes=pck.stat().st_size)
        expected = {'res://' + path: value for path, value in before.items() if path.startswith('data/') and path.endswith('.json')}
        report['smoke'] = smoke(engine, pck, output, expected)
        report['pck_verified'] = True
        if content_bundle:
            report['external_bundle_smoke'] = smoke(engine, pck, output, expected, Path(content_bundle).resolve(strict=True))
        if digest(pck) != report['pck_sha256']:
            raise RuntimeError('Exported PCK changed during verification; refusing an unverified artifact')
        if native_exe:
            if digest(exe) != report[exe_field]['sha256'] or digest(template) != template_sha:
                raise RuntimeError('Native executable or installed template changed during verification')
        if source_manifest() != before:
            raise RuntimeError('Sources changed during verification; this is not the verified source snapshot')
        report.update(ok=True, status='pck_verified_with_editor_network_diagnostic' if report['editor_network_diagnostics'] else 'pck_verified')
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        report['errors'].append(str(exc))
    write_new(output / 'report.json', report)
    return report


def main(argv=None):
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--engine', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True, help='New directory under an existing parent')
    parser.add_argument('--debug-exe', action='store_true', help='Additionally export an EXE only if the matching template is installed')
    parser.add_argument('--release-exe', action='store_true', help='Export the version-matched release template for native performance/playtesting')
    parser.add_argument('--content-bundle', type=Path, help='Optional reviewed compiled directory, copied outside the project for a separate smoke process')
    args = parser.parse_args(argv)
    try:
        report = build(**vars(args))
    except (OSError, ValueError) as exc:
        report = {'ok': False, 'errors': [str(exc)]}
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report['ok'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
