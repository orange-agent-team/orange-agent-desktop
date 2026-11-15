#!/usr/bin/env python3
"""Reject extra native exports using isolated copies of actual generated inputs."""
import json
from pathlib import Path
import shutil
import tempfile
from bridge_surface import verify_surface
from environment import ROOT, APP
contract=json.loads((ROOT/'config/bridge-tools.lock.json').read_text())
(ROOT/'.local').mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='bridge-surface-',dir=ROOT/'.local') as directory:
    root=Path(directory);app=root/'apps/desktop'
    shutil.copytree(APP/'lib/src/rust',app/'lib/src/rust')
    shutil.copytree(ROOT/'crates/desktop-bridge/src/api',root/'crates/desktop-bridge/src/api')
    verify_surface(root,app,contract)
    def rejected():
        try:verify_surface(root,app,contract)
        except SystemExit:return
        raise AssertionError('Unreviewed native export accepted')
    extra=app/'lib/src/rust/native_grant.dart';extra.write_text('class NativeGrant {}\n');rejected();extra.unlink()
    module=app/'lib/src/rust/api/memory.dart';original=module.read_bytes();module.write_bytes(original+b'\nclass NativeGrant {}\n');rejected();module.write_bytes(original)
    extra=root/'crates/desktop-bridge/src/api/native_grant.rs';extra.write_text('pub struct NativeGrant;\n');rejected();extra.unlink()
    verify_surface(root,app,contract)
print('PASS actual reviewed surface and isolated extra-module/DTO/Rust-input rejection')
