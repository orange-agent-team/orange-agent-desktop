#!/usr/bin/env python3
"""Xcode phase: copy only the verified staged bundle before outer app signing."""
import os
from pathlib import Path
import shutil
import sys
import tempfile
from model_bundle import ROOT, STAGED, verify_bundle, verify_embedded

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
print('Embedded fixed CPU model helper/backend with inherited sandbox; execution verification is separate')
