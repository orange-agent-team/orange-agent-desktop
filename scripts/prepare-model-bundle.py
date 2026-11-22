#!/usr/bin/env python3
"""Prepare explicitly supplied fixed CPU backend plus independently built Runtime helper.

No sibling worktree lookup, downloads, production signing or public distribution.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
from environment import tool_environment
from model_bundle import ROOT, STAGED, binary_info, catalog, current_runtime, digest, regular, safe_name, verify_bundle


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--backend', type=Path, required=True)
    parser.add_argument('--build-manifest', type=Path, required=True)
    parser.add_argument('--backend-checkout', type=Path, required=True)
    parser.add_argument('--test-model', type=Path)
    parser.add_argument('--target-dir', type=Path, default=ROOT/'.local/model-host-target', help='Explicit Cargo build cache for the independently imported helper source')
    args = parser.parse_args()
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise RuntimeError('This preparer certifies only the available macOS ARM64 target')
    subprocess.run([sys.executable, str(ROOT / 'scripts/import-runtime.py'), '--verify'], check=True)
    approved = catalog()
    runtime = current_runtime()
    regular(args.backend); regular(args.build_manifest)
    build = json.loads(args.build_manifest.read_text())
    if build['backend_commit'] != approved['backend']['commit'] or build['gpu_enabled'] is not False or digest(args.backend) != build['executable_sha256']:
        raise RuntimeError('Fixed CPU backend build evidence does not match artifact')
    commit = approved['backend']['commit']
    subprocess.run(['git', '-C', str(args.backend_checkout), 'cat-file', '-e', commit + '^{commit}'], check=True)
    environment, tools = tool_environment()
    environment['CARGO_TARGET_DIR'] = str(args.target_dir.resolve())
    subprocess.run([str(tools['cargo']), 'build', '--manifest-path', str(ROOT / runtime['vendor_directory'] / 'Cargo.toml'), '-p', 'orange-model-runtime', '--bin', 'orange-model-host', '--locked', '--offline'], env=environment, check=True)
    host = args.target_dir.resolve() / 'debug/orange-model-host'
    STAGED.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='model-bundle-stage-', dir=STAGED.parent) as temporary:
        stage = Path(temporary) / 'payload'
        stage.mkdir(mode=0o700)
        inputs = {'orange-model-host': host, 'llama-server': args.backend}
        originals = {name: digest(source) for name, source in inputs.items()}
        for name, source in inputs.items():
            # Cargo may hard-link its own output into debug/. Copy immutable
            # bytes, then verify the copy before signing; bundle files are nlink1.
            regular(source, allow_hardlinks=name == 'orange-model-host')
            target = stage / name
            shutil.copyfile(source, target); target.chmod(0o755)
            if digest(target) != originals[name]:
                raise RuntimeError('Build artifact changed during copy')
            subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements', str(ROOT / 'config/model-helper.entitlements'), str(target)], check=True)
        names = subprocess.check_output(['git', '-C', str(args.backend_checkout), 'ls-tree', '-rz', '--name-only', commit]).split(b'\0')
        licenses = []
        for raw in filter(None, names):
            name = raw.decode('utf-8')
            if not Path(name).name.upper().startswith(('LICENSE', 'COPYING', 'NOTICE')):
                continue
            safe_name(name)
            data = subprocess.check_output(['git', '-C', str(args.backend_checkout), 'show', commit + ':' + name])
            relative = 'licenses/llama.cpp/' + name
            path = stage / relative; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(data)
            licenses.append(relative)
        if 'licenses/llama.cpp/LICENSE' not in licenses:
            raise RuntimeError('Pinned backend license missing')
        if args.test_model:
            regular(args.test_model)
            if args.test_model.stat().st_size != approved['model']['bytes'] or digest(args.test_model) != approved['model']['sha256']:
                raise RuntimeError('Explicit test model differs from fixed catalog')
            shutil.copyfile(args.test_model, stage / 'test-model.gguf')
        binaries = {name: binary_info(stage / name) for name in inputs}
        minimum = max((item['minimum_macos'] for item in binaries.values()), key=lambda value: tuple(map(int, value.split('.'))))
        files = {path.relative_to(stage).as_posix(): {'sha256': digest(path), 'bytes': path.stat().st_size, 'executable': path.name in inputs} for path in sorted(stage.rglob('*')) if path.is_file()}
        manifest = {'schema': 'orange-model-service-bundle-v1', 'platform': 'macos-arm64', 'development_only': True, 'cpu_only': True,
                    'runtime_commit': runtime['origin_commit'], 'backend_commit': commit, 'backend_source_tree_sha256': build['source_tree_sha256'],
                    'model': approved['model'], 'minimum_macos': minimum, 'binaries': binaries, 'unsigned_sha256': originals, 'files': files,
                    'test_model_included': args.test_model is not None, 'license_scope': 'fixed backend source license inventory; complete Rust dependency/license release review remains pending'}
        (stage / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        verify_bundle(stage)
        if STAGED.exists():
            # Only a previously valid owned staging bundle is replaced. Unknown
            # directories or user edits require explicit diagnosis, not deletion.
            verify_bundle(STAGED, require_current=False)
            backup = STAGED.with_name('model-bundle-previous')
            if backup.exists():
                verify_bundle(backup, require_current=False); shutil.rmtree(backup)
            os.replace(STAGED, backup)
        os.replace(stage, STAGED)
    # A first package can appear after a previous no-package hook was cached.
    # Invalidate only this app's generated native hook cache, never user data.
    hook_cache=ROOT/'apps/desktop/.dart_tool/hooks_runner'
    if hook_cache.is_symlink():
        raise RuntimeError('Linked generated hook cache refused')
    if hook_cache.exists():
        shutil.rmtree(hook_cache)
    print(json.dumps({'bundle': str(STAGED), 'manifest_sha256': digest(STAGED / 'manifest.json'), 'minimum_macos': minimum,
                      'test_model_included': args.test_model is not None, 'certification': 'ad-hoc development artifact integrity only; no production signing, packaged execution or lower-OS runtime certificate'}, indent=2))


if __name__ == '__main__':
    STAGED.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(STAGED.parent / 'model-bundle.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'a') as guard:
        if os.fstat(guard.fileno()).st_nlink != 1:
            raise RuntimeError('Linked bundle preparation lock')
        fcntl.flock(guard, fcntl.LOCK_EX | fcntl.LOCK_NB)
        main()
