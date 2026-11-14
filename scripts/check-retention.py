#!/usr/bin/env python3
"""Actual owned native editing/retention; model and picker callbacks are fixtures."""
import json
import subprocess
import sys
from environment import APP, ROOT, tool_environment

subprocess.run([sys.executable, str(ROOT/'scripts/check-bridge.py')], cwd=ROOT, check=True)
environment, tools = tool_environment()
result = subprocess.run([str(tools['flutter']), '--suppress-analytics', 'test', 'integration_test/retention_test.dart', '-d', 'macos', '--no-pub'], cwd=APP, env=environment, capture_output=True, text=True, timeout=900)
print(result.stdout, end='', flush=True)
print(result.stderr, end='', flush=True)
result.check_returncode()
records = []
for line in result.stdout.replace('\r', '\n').splitlines():
    needle = '{"nativeRetention":'
    if needle in line:
        value, _ = json.JSONDecoder().raw_decode(line[line.index(needle):])
        records.append(value)
if len(records) != 1 or 'All tests passed!' not in result.stdout:
    raise SystemExit('Actual native retention acceptance did not complete')
r = records[0]
if any(r.get(k) is not True for k in ['nativeRetention','actualEditAndArchive','archiveConfirmedAfterReopen','closedBeforeNativeRelease']) or r.get('approvalCalls') != 1 or r.get('lostReplyLookups') != 1 or r.get('retainedFiles') != 2 or r.get('ordinaryAccessRestored') is not False:
    raise SystemExit('Native authority, exactly-once archival or retained-file evidence differs')
print('PASS actual native retained-file selection, exact archive confirmation, reservations, unchanged files, lost-reply query and reopened receipt; model/picker callbacks fixtures, no export/deletion/manual-picker or other-OS certificate')
