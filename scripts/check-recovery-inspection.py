#!/usr/bin/env python3
"""Native receipt fault -> reopened Host -> inspection UI; never a write recovery.

SQLite injection is confined to test-created private application temp directories.
The production Host has no fault-injection API. Model/OS-picker callbacks are
explicit substitutes; Rust/FRB/SQLite/files/lease drain execute on actual macOS.
"""
from pathlib import Path
import subprocess
import sys

from environment import APP, ROOT, tool_environment

subprocess.run([sys.executable, str(ROOT / 'scripts/check-bridge.py')], cwd=ROOT, check=True)
environment, tools = tool_environment()
result = subprocess.run([
    str(tools['flutter']), '--suppress-analytics', 'test',
    'integration_test/recovery_inspection_test.dart', '-d', 'macos', '--no-pub',
], cwd=APP, env=environment, capture_output=True, text=True, timeout=900)
print(result.stdout, end='', flush=True)
if result.stderr:
    print(result.stderr, end='', flush=True)
result.check_returncode()
if '"nativeRecoveryInspection":true' not in result.stdout or 'All tests passed!' not in result.stdout:
    raise SystemExit('Actual native inspection acceptance did not complete')
print('PASS owned actual file/SQLite receipt fault, Host reopen, independent recovery inspection, no execution restoration and drain before native release; no recovery-write, real-model or manual-picker certification')
