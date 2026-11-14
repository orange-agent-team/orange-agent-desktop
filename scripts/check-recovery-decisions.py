#!/usr/bin/env python3
"""Owned actual native recovery: independent authority, exact decisions, no replay.

Model and native-picker callbacks are explicit fixtures. SQLite faults touch
only test-created journals; file effects, reopen, scopes and receipts are real.
"""
import json
import subprocess
import sys
from environment import APP, ROOT, tool_environment

subprocess.run([sys.executable, str(ROOT / 'scripts/check-bridge.py')], cwd=ROOT, check=True)
environment, tools = tool_environment()
for name, marker in [
    ('recovery_inspection_test.dart', 'nativeRecoveryInspection'),
    ('recovery_decision_test.dart', 'nativeRecoveryDecision'),
]:
    result = subprocess.run([
        str(tools['flutter']), '--suppress-analytics', 'test',
        'integration_test/' + name, '-d', 'macos', '--no-pub',
    ], cwd=APP, env=environment, capture_output=True, text=True, timeout=900)
    print(result.stdout, end='', flush=True)
    print(result.stderr, end='', flush=True)
    result.check_returncode()
    records = []
    for line in result.stdout.replace('\r', '\n').splitlines():
        needle = '{"' + marker + '":'
        if needle in line:
            value, _ = json.JSONDecoder().raw_decode(line[line.index(needle):])
            if value.get(marker) is True:
                records.append(value)
    if not records or 'All tests passed!' not in result.stdout:
        raise SystemExit('Actual native acceptance did not complete: ' + name)
    if marker == 'nativeRecoveryDecision':
        expected = {'keep_current_target', 'restore_original_to_missing_target', 'publish_staged_to_missing_target'}
        if len(records) != 3 or {r.get('choice') for r in records} != expected:
            raise SystemExit('All three actual choices are required')
        if any(r.get('approvalCalls') != 1 or r.get('ordinaryAccessRestored') is not False
               or r.get('operationStillUnknown') is not True for r in records):
            raise SystemExit('Authority/no-replay evidence differs')
        if next(r for r in records if r['choice'] == 'restore_original_to_missing_target')['lostReplyLookups'] != 1:
            raise SystemExit('Actual committed result must be reconciled without resending approval')
print('PASS actual native inspection plus all3 recovery decisions, separate write consent, exact preview approval, retained versions, unchanged original unknown state and lost-reply metadata-only reconciliation; no manual-picker, real-model or other-OS certificate')
