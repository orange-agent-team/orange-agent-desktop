#!/usr/bin/env python3
"""Real Rust/SQLite checks and optional packaged macOS Flutter/FFI execution."""
import argparse
import hashlib
import json
import subprocess
import sys
from environment import ROOT,APP,tool_environment
parser=argparse.ArgumentParser();parser.add_argument('--native',action='store_true');args=parser.parse_args()
subprocess.run([sys.executable,str(ROOT/'scripts/import-runtime.py'),'--verify'],check=True)
manifest=json.loads((ROOT/'config/generated-bridge.lock.json').read_text())
for group in ['source_sha256','generated_sha256']:
    for name,sha in manifest[group].items():
        if hashlib.sha256((ROOT/name).read_bytes()).hexdigest()!=sha:raise SystemExit('Stale bridge generation: '+name)
environment,tools=tool_environment()
for arguments in [ ['fmt','-p','orange-desktop-bridge','--check'],['test','-p','orange-desktop-bridge','--locked','--offline'],['clippy','-p','orange-desktop-bridge','--all-targets','--locked','--offline','--','-D','warnings'] ]:
    subprocess.run([str(tools['cargo']),*arguments],cwd=ROOT,env=environment,check=True)
subprocess.run([str(tools['flutter']),'--suppress-analytics','pub','get','--offline','--enforce-lockfile'],cwd=APP,env=environment,check=True)
subprocess.run([str(tools['dart']),'--suppress-analytics','format','--output=none','--set-exit-if-changed','lib','integration_test','hook'],cwd=APP,env=environment,check=True)
subprocess.run([str(tools['flutter']),'--suppress-analytics','analyze','--no-pub'],cwd=APP,env=environment,check=True)
if args.native:
    subprocess.run([str(tools['flutter']),'--suppress-analytics','test','integration_test/native_host_test.dart','-d','macos','--no-pub'],cwd=APP,env=environment,check=True,timeout=900)
    print('PASS actual macOS app/Flutter-to-Rust Host lifecycle, exact integer strings and stale handle rejection; no model/cloud/GPU feature certification')
else:
    print('PASS Rust host and Dart static checks; native FFI application not exercised without --native')
