"""Fixed development model-service bundle inventory; no downloads or implicit peer source reads."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
STAGED = ROOT / '.local/model-bundle'
HELPER_ENTITLEMENTS = {'com.apple.security.app-sandbox': True, 'com.apple.security.inherit': True}


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def regular(path, allow_hardlinks=False):
    if path.is_symlink() or not path.is_file() or (not allow_hardlinks and path.stat().st_nlink != 1):
        raise RuntimeError('Regular unlinked bundle file required: ' + path.name)


def safe_name(name):
    path = PurePosixPath(name)
    if not path.parts or path.is_absolute() or path.as_posix() != name or any(p in ['.', '..'] for p in path.parts) or '\\' in name:
        raise RuntimeError('Invalid bundle entry')
    return path


def current_runtime():
    return json.loads((ROOT / 'config/runtime.lock.json').read_text())


def catalog():
    runtime = current_runtime()
    return json.loads((ROOT / runtime['vendor_directory'] / 'config/local-model.lock.json').read_text())


def binary_info(path):
    regular(path)
    architectures = subprocess.check_output(['xcrun', 'lipo', '-archs', str(path)], text=True).strip().split()
    if architectures != ['arm64']:
        raise RuntimeError('Only the explicitly verified macOS ARM64 bundle is supported')
    builds = subprocess.check_output(['xcrun', 'vtool', '-show-build', str(path)], text=True)
    versions = re.findall(r'^\s*minos ([0-9.]+)$', builds, re.M)
    if len(versions) != 1 or 'platform MACOS' not in builds:
        raise RuntimeError('Missing unambiguous macOS deployment target')
    dependencies = subprocess.check_output(['otool', '-L', str(path)], text=True).splitlines()[1:]
    libraries = [line.strip().split(' (compatibility version', 1)[0] for line in dependencies]
    if not libraries or any(not name.startswith(('/usr/lib/', '/System/Library/')) for name in libraries):
        raise RuntimeError('Unreviewed non-system dynamic dependency')
    return {'architectures': architectures, 'minimum_macos': versions[0], 'system_libraries': libraries}


def check_signature(path):
    subprocess.run(['codesign', '--verify', '--strict', str(path)], check=True, capture_output=True)
    result = subprocess.run(['codesign', '--display', '--entitlements', '-', '--xml', str(path)], check=True, capture_output=True)
    if plistlib.loads(result.stdout) != HELPER_ENTITLEMENTS:
        raise RuntimeError('Model helper must inherit only the parent static sandbox rights')


def verify_bundle(directory, signatures=True, executable_directory=None, require_current=True):
    if directory.is_symlink() or not directory.is_dir():
        raise RuntimeError('Model bundle directory is missing or linked')
    regular(directory / 'manifest.json')
    if (directory / 'manifest.json').stat().st_size > 256 * 1024:
        raise RuntimeError('Bundle manifest exceeds limit')
    manifest = json.loads((directory / 'manifest.json').read_text())
    if manifest['schema'] != 'orange-model-service-bundle-v1' or manifest['platform'] != 'macos-arm64' or manifest['development_only'] is not True or manifest['cpu_only'] is not True:
        raise RuntimeError('Unsupported bundle policy')
    runtime = current_runtime()
    approved = catalog()
    if (require_current and manifest['runtime_commit'] != runtime['origin_commit']) or not re.fullmatch('[0-9a-f]{40}', manifest['runtime_commit']) or manifest['backend_commit'] != approved['backend']['commit'] or manifest['model'] != approved['model']:
        raise RuntimeError('Bundle differs from fixed Runtime/model catalog')
    expected = {name for name, item in manifest['files'].items() if executable_directory is None or item['executable'] is not True} | {'manifest.json'}
    if executable_directory is not None and (executable_directory.is_symlink() or not executable_directory.is_dir()):
        raise RuntimeError('Invalid application helper directory')
    actual = set()
    for path in directory.rglob('*'):
        if path.is_symlink():
            raise RuntimeError('Linked bundle entry')
        if path.is_file():
            actual.add(path.relative_to(directory).as_posix())
    if actual != expected:
        raise RuntimeError('Bundle inventory differs from manifest')
    for name, item in manifest['files'].items():
        base = executable_directory if executable_directory is not None and item['executable'] is True else directory
        path = base / str(safe_name(name))
        regular(path)
        if path.stat().st_size != item['bytes'] or digest(path) != item['sha256']:
            raise RuntimeError('Bundle file integrity mismatch: ' + name)
        if item['executable'] is True:
            if name not in ['orange-model-host', 'llama-server'] or binary_info(path) != manifest['binaries'][name]:
                raise RuntimeError('Unexpected binary or target drift')
            if signatures:
                check_signature(path)
        elif item['executable'] is not False or not (name.startswith('licenses/') or name == 'test-model.gguf'):
            raise RuntimeError('Unsupported data entry in model bundle')
    for name in ['orange-model-host', 'llama-server']:
        if name not in manifest['files'] or manifest['files'][name]['executable'] is not True:
            raise RuntimeError('Required model executable missing')
    minimum = max((manifest['binaries'][name]['minimum_macos'] for name in ['orange-model-host', 'llama-server']), key=lambda value: tuple(map(int, value.split('.'))))
    if manifest['minimum_macos'] != minimum:
        raise RuntimeError('Bundle minimum OS does not cover every executable')
    test_model = manifest['files'].get('test-model.gguf')
    if manifest['test_model_included'] is True:
        if test_model is None or test_model['sha256'] != approved['model']['sha256'] or test_model['bytes'] != approved['model']['bytes']:
            raise RuntimeError('Test model differs from catalog')
    elif manifest['test_model_included'] is not False or test_model is not None:
        raise RuntimeError('Undeclared test model payload')
    return manifest


def verify_embedded(contents, require_current=True):
    return verify_bundle(contents / 'Resources/OrangeModelService', executable_directory=contents / 'Helpers', require_current=require_current)
