#!/usr/bin/env python3
"""Xcode phase: copy only the verified staged bundle before outer app signing."""
import os
import json
from pathlib import Path
import shutil
import sys
import tempfile
from model_bundle import ROOT, STAGED, verify_bundle, verify_embedded, current_runtime, digest

requested = Path(sys.argv[1]).absolute()
contents = requested.resolve()
configuration = sys.argv[2]
# Build products only; this hook never installs into /Applications or user data.
expected = (ROOT / 'apps/desktop/build/macos').resolve()
if not contents.is_relative_to(expected) or contents.name != 'Contents' or contents.parent.suffix != '.app' or requested.is_symlink():
    raise SystemExit('Expected this workspace macOS app build product')
helpers = contents / 'Helpers'
target = contents / 'Resources/OrangeModelService'
if helpers.is_symlink() or target.parent.is_symlink() or target.is_symlink() or STAGED.is_symlink():
    raise SystemExit('Linked application model namespace refused')

def record_build_output(model_manifest):
    # This declared bundle resource connects script-written payloads to Xcode's
    # final CodeSign task. Include Flutter/native framework content, so switching
    # integration-test kernels or native assets also changes the dependency.
    frameworks = {}
    for framework in sorted((contents / 'Frameworks').glob('*.framework')):
        binary = (framework / framework.stem).resolve(strict=True)
        seal = (binary.parent / '_CodeSignature/CodeResources').resolve(strict=True)
        if not binary.is_relative_to(contents) or not seal.is_relative_to(contents):
            raise SystemExit('Framework build output escaped this app')
        frameworks[framework.name] = {'binary_sha256': digest(binary), 'resource_seal_sha256': digest(seal)}
    marker = contents / 'Resources/orange-model-embed.json'
    if marker.is_symlink():
        raise SystemExit('Linked model embedding marker refused')
    if marker.exists():
        old = marker.read_bytes()
        if len(old) > 65536 or json.loads(old).get('schema') != 'orange-model-embed-v1':
            raise SystemExit('Unknown model embedding marker refused')
    value = {'schema': 'orange-model-embed-v1', 'configuration': configuration,
             'runtime_commit': current_runtime()['origin_commit'],
             'model_manifest_sha256': digest(target / 'manifest.json') if model_manifest else None,
             'frameworks': frameworks}
    payload = (json.dumps(value, sort_keys=True, indent=2) + '\n').encode()
    marker.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='orange-embed-', dir=marker.parent)
    try:
        os.fchmod(fd, 0o644)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(payload)
        os.replace(name, marker)
    finally:
        if os.path.exists(name): os.unlink(name)

# A development attempt placed data in Helpers, which codesign correctly
# refused. Migrate only that fully verified, owned build-output namespace.
legacy = helpers / 'OrangeModelService'
if legacy.exists():
    verify_bundle(legacy, require_current=False); shutil.rmtree(legacy)
if not STAGED.exists():
    if target.exists():
        verify_embedded(contents, require_current=False); shutil.rmtree(target)
        for name in ['orange-model-host', 'llama-server']:
            (helpers / name).unlink()
    print('Model service bundle absent; application must report not packaged')
    record_build_output(None)
    raise SystemExit(0)
manifest = verify_bundle(STAGED)
if configuration not in ['Debug', 'Profile', 'Release']:
    raise SystemExit('Unsupported Xcode build configuration')
# An optimized Release build can still be a development candidate. Retain the
# development_only marker; building never grants production publication status.
target.parent.mkdir(parents=True, exist_ok=True)
helpers.mkdir(parents=True, exist_ok=True)
if target.is_symlink():
    raise SystemExit('Linked app helper destination refused')
if target.exists():
    verify_embedded(contents, require_current=False)
elif any((helpers / name).exists() for name in ['orange-model-host', 'llama-server']):
    raise SystemExit('Unexplained model helper without its resource manifest')
with tempfile.TemporaryDirectory(prefix='orange-model-stage-', dir=contents) as folder:
    staged = Path(folder) / 'payload'
    shutil.copytree(STAGED, staged)
    verify_bundle(staged)
    for name in ['orange-model-host', 'llama-server']:
        destination = helpers / name
        if destination.is_symlink():
            raise SystemExit('Linked model helper destination')
        os.replace(staged / name, destination)
    if target.exists():
        shutil.rmtree(target)
    os.replace(staged, target)
verify_embedded(contents)
record_build_output(manifest)
print('Embedded fixed CPU model helper/backend with inherited sandbox; execution verification is separate')
