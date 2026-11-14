#!/usr/bin/env python3
"""Real Rust/SQLite checks and optional packaged macOS Flutter/FFI execution."""
import argparse
import hashlib
import json
from pathlib import Path
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
metadata=json.loads(subprocess.check_output([str(tools['cargo']),'metadata','--locked','--offline','--format-version','1'],cwd=ROOT,env=environment,text=True))
runtime=json.loads((ROOT/'config/runtime.lock.json').read_text())
expected={'orange-domain':'domain','orange-protocol':'protocol','orange-agent-runtime':'agent-runtime','orange-model-runtime':'model-runtime','orange-platform-files':'platform-files'}
seen=set()
for package in metadata['packages']:
    if package['name'] in expected:
        wanted=(ROOT/runtime['vendor_directory']/'crates'/expected[package['name']]/'Cargo.toml').resolve()
        if Path(package['manifest_path']).resolve()!=wanted:raise SystemExit('Shared core escaped fixed local artifact')
        seen.add(package['name'])
if not set(expected)<=seen:raise SystemExit('Required shared Runtime dependencies missing')
for arguments in [ ['fmt','-p','orange-desktop-bridge','--check'],['test','-p','orange-desktop-bridge','--locked','--offline'],['clippy','-p','orange-desktop-bridge','--all-targets','--locked','--offline','--','-D','warnings'] ]:
    subprocess.run([str(tools['cargo']),*arguments],cwd=ROOT,env=environment,check=True)
subprocess.run([str(tools['flutter']),'--suppress-analytics','pub','get','--offline','--enforce-lockfile'],cwd=APP,env=environment,check=True)
subprocess.run([str(tools['dart']),'--suppress-analytics','format','--output=none','--set-exit-if-changed','lib','test','integration_test','hook'],cwd=APP,env=environment,check=True)
subprocess.run([str(tools['flutter']),'--suppress-analytics','analyze','--no-pub'],cwd=APP,env=environment,check=True)
subprocess.run([str(tools['flutter']),'--suppress-analytics','test','--no-pub','test'],cwd=APP,env=environment,check=True,timeout=300)
if args.native:
    subprocess.run([str(tools['flutter']),'--suppress-analytics','test','integration_test/native_host_test.dart','-d','macos','--no-pub'],cwd=APP,env=environment,check=True,timeout=900)
    print('PASS actual macOS Flutter/FRB/private Unix IPC/SQLite/file-tool approval UI and scoped access cleanup; exact integer strings and stale handles. Model protocol and OS selection callbacks are explicit fixtures. Real API inference is check-real-run.py; actual managed model lifecycle/UI is check-managed-model.py. No cloud, GPU or persistent OS-bookmark certificate')
else:
    print('PASS Rust host and Dart static checks; native FFI application not exercised without --native')
