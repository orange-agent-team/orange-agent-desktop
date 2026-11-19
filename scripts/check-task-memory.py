#!/usr/bin/env python3
"""Verify shipped memory permissions, storage, actual CPU inference and default build."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
from environment import APP, ROOT, tool_environment
from model_bundle import STAGED, verify_bundle

parser = argparse.ArgumentParser()
parser.add_argument('--model', type=Path, required=True, help='Explicit pinned local GGUF for the packaged acceptance run')
args = parser.parse_args()
bundle = verify_bundle(STAGED)
if bundle['test_model_included']:
    raise SystemExit('Begin with the default component bundle without test weights')
env, tools = tool_environment()
try:
    subprocess.run([sys.executable, str(ROOT/'scripts/check-memory-ui.py')], cwd=ROOT, check=True, timeout=900)
    subprocess.run([str(tools['flutter']), '--suppress-analytics', 'test', 'integration_test/task_memory_test.dart', '-d', 'macos', '--no-pub'], cwd=APP, env=env, check=True, timeout=900)
    subprocess.run([sys.executable, str(ROOT/'scripts/check-managed-model.py'), '--ui-memory-only', '--model', str(args.model.resolve())], cwd=ROOT, check=True, timeout=1000)
finally:
    subprocess.run([sys.executable, str(ROOT/'scripts/check-flutter.py')], cwd=ROOT, check=True, timeout=1000)
report=json.loads((ROOT/'.local/build-evidence/flutter-macos.json').read_text())
app=ROOT/report['app']
if any(app.rglob('*.gguf')) or report['model_bundle']['runtime_commit']!=bundle['runtime_commit']:
    raise SystemExit('Default bundle restoration failed')
print('PASS memory management, scoped Agent approvals, real packaged CPU model and restored default executable')
