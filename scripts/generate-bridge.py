#!/usr/bin/env python3
"""Regenerate paired bindings and reject accidental private Host exports."""
import hashlib
import json
import re
import subprocess
import sys
from environment import ROOT,APP,tool_environment
from bridge_surface import verify_surface
subprocess.run([sys.executable,str(ROOT/'scripts/import-runtime.py'),'--verify'],check=True)
environment,tools=tool_environment(generators=True)
subprocess.run([str(tools['frb']),'generate','--stop-on-error'],cwd=APP,env=environment,check=True)
subprocess.run([str(tools['cargo']),'fmt','-p','orange-desktop-bridge'],cwd=ROOT,env=environment,check=True)
contract=json.loads((ROOT/'config/bridge-tools.lock.json').read_text())
verify_surface(ROOT,APP,contract)
rust_file=ROOT/'crates/desktop-bridge/src/frb_generated.rs';dart_file=APP/'lib/src/rust/frb_generated.dart'
rust_hash=re.search(r'FLUTTER_RUST_BRIDGE_CODEGEN_CONTENT_HASH: i32 = (-?\d+)',rust_file.read_text()).group(1)
dart_hash=re.search(r'rustContentHash => (-?\d+)',dart_file.read_text()).group(1)
if rust_hash!=dart_hash:raise SystemExit('Rust/Dart codegen hash mismatch')
files=[rust_file,*sorted((APP/'lib/src/rust').rglob('*.dart'))]
inputs=[ROOT/'Cargo.toml',ROOT/'Cargo.lock',ROOT/'config/runtime.lock.json',ROOT/'config/bridge-tools.lock.json',ROOT/'crates/desktop-bridge/Cargo.toml',ROOT/'crates/desktop-bridge/rust-toolchain.toml',ROOT/'crates/desktop-bridge/src/lib.rs',ROOT/'crates/desktop-bridge/src/host.rs',ROOT/'crates/desktop-bridge/src/actor.rs',ROOT/'crates/desktop-bridge/src/host/runs.rs',ROOT/'crates/desktop-bridge/src/api/mod.rs',ROOT/'crates/desktop-bridge/src/api/host.rs',APP/'flutter_rust_bridge.yaml',APP/'pubspec.lock']
inputs.extend(sorted((ROOT/'crates/desktop-bridge/src/api').rglob('*.rs')))
inputs.extend([ROOT/'scripts/bridge_surface.py',ROOT/'scripts/generate-bridge.py'])
inputs.extend(sorted((ROOT/'crates/desktop-bridge/src/service').rglob('*.rs')))
inputs.extend(sorted((ROOT/'crates/desktop-bridge/src/host').rglob('*.rs')))
inputs.extend(sorted((ROOT/'crates/desktop-bridge/src/actor').rglob('*.rs')))
manifest={'codegen_version':contract['flutter_rust_bridge'],'content_hash':rust_hash,'source_sha256':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs},'generated_sha256':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}}
(ROOT/'config/generated-bridge.lock.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('PASS reviewed DTO/command surface and paired Rust/Dart generation hash')
