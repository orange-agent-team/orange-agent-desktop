#!/usr/bin/env python3
"""Exercise a real sandboxed app and explicitly supplied local 7B weights, without shipping them."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import selectors
import signal
import sys
import time
import tempfile
from environment import APP,ROOT,tool_environment
from model_bundle import verify_bundle,STAGED

def run_native(command, env):
    # Stream the real test output to the caller so interruption preserves the observed phases.
    with subprocess.Popen(command,cwd=APP,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
                          start_new_session=True) as child, selectors.DefaultSelector() as ready:
        ready.register(child.stdout,selectors.EVENT_READ)
        deadline=time.monotonic()+1500
        observed=set()
        line=b""
        def inspect(data):
            for marker in (b'"approved7bDesktopPatch":true',b'"persistedSelection":true',b'All tests passed!'):
                if marker in data:observed.add(marker)
        try:
            while ready.get_map():
                remaining=deadline-time.monotonic()
                if remaining<=0:raise TimeoutError('Desktop model verification exceeded its deadline')
                for key,_ in ready.select(min(5,remaining)):
                    chunk=os.read(key.fd,65536)
                    if not chunk:
                        ready.unregister(key.fileobj)
                        break
                    sys.stdout.buffer.write(chunk);sys.stdout.buffer.flush()
                    data=line+chunk
                    inspect(data)
                    line=data[-64:]
            code=child.wait(timeout=max(0.1,deadline-time.monotonic()))
            if code:raise RuntimeError(f'Actual desktop qualification exited with status {code}')
            if len(observed)!=3:raise RuntimeError('Native selection and editing proof missing')
        finally:
            if child.poll() is None:
                os.killpg(child.pid,signal.SIGTERM)
                try:child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid,signal.SIGKILL)
                    child.wait(timeout=10)


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
        run_native([tools['flutter'],'--suppress-analytics','test','integration_test/model_profiles_test.dart',
                    '-d','macos','--no-pub','--dart-define=ORANGE_SELECTED_7B='+str(file)],env)
    print('PASS sandboxed macOS alternate model, stale selection denial and approved real 7B edit',flush=True)

if __name__=='__main__':main()
