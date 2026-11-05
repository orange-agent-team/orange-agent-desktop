#!/usr/bin/env python3
"""Verify actual prepared binaries and reject tamper/version/signature claims.

No process execution or production-signing claim follows from bundle integrity.
"""
import json
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from model_bundle import ROOT, STAGED, digest, verify_bundle
from environment import APP, tool_environment

parser=argparse.ArgumentParser();parser.add_argument('--native',action='store_true');args=parser.parse_args()

manifest = verify_bundle(STAGED)
def rejects(directory):
    try:
        verify_bundle(directory)
    except (RuntimeError, subprocess.CalledProcessError):
        return
    raise AssertionError('Unsafe bundle was accepted')

with tempfile.TemporaryDirectory(prefix='model-bundle-check-', dir=ROOT / '.local') as temporary:
    sample = Path(temporary) / 'sample'
    shutil.copytree(STAGED, sample)
    record = sample / 'manifest.json'
    original = record.read_bytes()
    changed = json.loads(original); changed['runtime_commit'] = '0' * 40
    record.write_text(json.dumps(changed)); rejects(sample); record.write_bytes(original)
    changed = json.loads(original); changed['minimum_macos'] = '1.0'
    record.write_text(json.dumps(changed)); rejects(sample); record.write_bytes(original)
    (sample / 'unexpected-data').write_bytes(b'not in inventory'); rejects(sample)
    (sample / 'unexpected-data').unlink()
    backend = sample / 'llama-server'
    backend.unlink(); backend.symlink_to(STAGED / 'llama-server'); rejects(sample)
    backend.unlink(); shutil.copy2(STAGED / 'llama-server', backend)
    # Even if an edited inventory claims the new hash, absence of the actual
    # inherited-sandbox signature cannot pass this development-bundle gate.
    subprocess.run(['codesign', '--remove-signature', str(backend)], check=True)
    changed = json.loads(original)
    changed['files']['llama-server'].update(sha256=digest(backend), bytes=backend.stat().st_size)
    record.write_text(json.dumps(changed)); rejects(sample)
    build_root=ROOT/'apps/desktop/build/macos';build_root.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='model-embed-check-',dir=build_root) as output:
        contents=Path(output)/'Guard.app/Contents';contents.mkdir(parents=True)
        external=Path(temporary)/'external';external.mkdir();(external/'sentinel').write_text('preserve')
        (contents/'Helpers').symlink_to(external,target_is_directory=True)
        rejected=subprocess.run([sys.executable,str(ROOT/'scripts/embed-model-service.py'),str(contents),'Debug'],capture_output=True,text=True)
        if rejected.returncode==0 or sorted(p.name for p in external.iterdir())!=['sentinel']:
            raise AssertionError('Linked application namespace was modified')
if args.native:
    environment,tools=tool_environment()
    subprocess.run([str(tools['flutter']),'--suppress-analytics','test','integration_test/model_bundle_test.dart','-d','macos','--no-pub'],cwd=APP,env=environment,check=True,timeout=900)
print(json.dumps({'passed': True, 'native_helper_probe':args.native,'runtime_commit': manifest['runtime_commit'], 'minimum_macos': manifest['minimum_macos'],
                  'manifest_sha256': digest(STAGED / 'manifest.json'), 'scope': 'actual development binary inventory/architecture/system libraries/inherited-sandbox signature and tamper rejection; optional native probe executes backend version and rejects wrong parent before model startup. Not inference, managed lifecycle UI, production signing or full license review'}, indent=2))
