#!/usr/bin/env python3
"""Exercise a real sandboxed app and explicitly supplied local 7B weights, without shipping them."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile
from environment import APP,ROOT,tool_environment
from model_bundle import verify_bundle,STAGED

def main():
    cl=argparse.ArgumentParser();cl.add_argument('--model',type=Path,required=True);args=cl.parse_args()
    if platform.system()!='Darwin' or platform.machine()!='arm64':
        raise RuntimeError('This test qualifies the native macOS ARM64 app')
    bundle=verify_bundle(STAGED)
    if bundle['test_model_included']:raise RuntimeError('Expected the ordinary weight-free application')
    lock=json.loads((ROOT/'config/runtime.lock.json').read_bytes())
    pin=json.loads((ROOT/lock['vendor_directory']/'config/local-code-review-model.lock.json').read_bytes())
    with args.model.open('rb') as stream:
        if os.fstat(stream.fileno()).st_size!=pin['bytes'] or hashlib.file_digest(stream,'sha256').hexdigest()!=pin['sha256']:
            raise RuntimeError('Approved local merged 7B model required')
    container=Path.home()/'Library/Containers/dev.orangeagent.orangeDesktop/Data/tmp'
    if not container.is_dir() or container.stat().st_uid!=os.getuid():
        raise RuntimeError('A previously bootstrapped local macOS app container is required')
    env,tools=tool_environment()
    with tempfile.TemporaryDirectory(prefix='orange-selected-weight-',dir=container) as tmp:
        file=Path(tmp)/'selected.gguf'
        subprocess.run(['/bin/cp','-c',args.model.resolve(),file],check=True)
        result=subprocess.run([tools['flutter'],'--suppress-analytics','test','integration_test/model_profiles_test.dart',
                            '-d','macos','--no-pub','--dart-define=ORANGE_SELECTED_7B='+str(file)],
                           cwd=APP,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=1500)
        print(result.stdout,end='',flush=True);result.check_returncode()
        if '"approved7bDesktopPatch":true' not in result.stdout or '"persistedSelection":true' not in result.stdout or 'All tests passed!' not in result.stdout:
            raise RuntimeError('Native selection and editing proof missing')
    print('PASS sandboxed macOS alternate model, stale selection denial and approved real 7B edit',flush=True)

if __name__=='__main__':main()
