#!/usr/bin/env python3
"""Real fixed-model product path with an explicit temporary test weight payload.

Restores the original staged component bundle after the test. No user data or
running model state is deleted by this build-artifact fixture helper.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from environment import APP,ROOT,tool_environment
from model_bundle import STAGED,digest,regular,verify_bundle

def invalidate_hook():
    cache=APP/'.dart_tool/hooks_runner'
    if cache.is_symlink():raise RuntimeError('Linked generated hook cache')
    if cache.exists():shutil.rmtree(cache)

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--model',type=Path,required=True);args=parser.parse_args()
    original=verify_bundle(STAGED);regular(args.model)
    if args.model.stat().st_size!=original['model']['bytes'] or digest(args.model)!=original['model']['sha256']:
        raise RuntimeError('Explicit fixed test model differs from catalog')
    temporary=Path(tempfile.mkdtemp(prefix='managed-model-bundle-',dir=ROOT/'.local'))
    backup=temporary/'original';fixture=temporary/'fixture'
    shutil.copytree(STAGED,fixture)
    shutil.copyfile(args.model,fixture/'test-model.gguf')
    manifest=json.loads((fixture/'manifest.json').read_text())
    manifest['test_model_included']=True
    manifest['files']['test-model.gguf']={'sha256':original['model']['sha256'],'bytes':original['model']['bytes'],'executable':False}
    (fixture/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    verify_bundle(fixture);expected=digest(fixture/'manifest.json')
    os.replace(STAGED,backup);os.replace(fixture,STAGED);invalidate_hook()
    try:
        environment,tools=tool_environment()
        subprocess.run([str(tools['flutter']),'--suppress-analytics','test','integration_test/managed_model_test.dart','-d','macos','--no-pub'],cwd=APP,env=environment,check=True,timeout=900)
    finally:
        # Preserve both sides if unexpected concurrent edits occurred, rather
        # than erasing unknown changes or claiming a successful restoration.
        verify_bundle(STAGED)
        if digest(STAGED/'manifest.json')!=expected:raise RuntimeError('Test bundle changed unexpectedly; original retained at '+str(backup))
        shutil.rmtree(STAGED);os.replace(backup,STAGED);invalidate_hook();shutil.rmtree(temporary)
    print('PASS actual packaged sandbox model import/start/35-second idle heartbeat and product UI approved file flow, instance fencing, Host-close cleanup, durable replay/cancel and unowned-process refusal. Native picker selections are explicit fixtures; no production signing, orphan reconciliation or broad hardware certificate')

if __name__=='__main__':
    path=ROOT/'.local/model-bundle.lock'
    fd=os.open(path,os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'a') as guard:
        if os.fstat(guard.fileno()).st_nlink!=1:raise RuntimeError('Linked bundle lock')
        fcntl.flock(guard,fcntl.LOCK_EX|fcntl.LOCK_NB);main()
