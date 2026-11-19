#!/usr/bin/env python3
"""Actual available macOS Flutter/FRB/SQLite user memory management; no model calls."""
import json,subprocess,sys
from environment import ROOT,APP,tool_environment
subprocess.run([sys.executable,str(ROOT/'scripts/check-bridge.py')],cwd=ROOT,check=True)
env,tools=tool_environment()
r=subprocess.run([str(tools['flutter']),'--suppress-analytics','test','integration_test/memory_management_test.dart','-d','macos','--no-pub'],cwd=APP,env=env,capture_output=True,text=True,timeout=900)
print(r.stdout,end='',flush=True);print(r.stderr,end='',flush=True);r.check_returncode()
records=[]
for line in r.stdout.replace('\r','\n').splitlines():
    marker='{"nativeMemory":'
    if marker in line:records.append(json.JSONDecoder().raw_decode(line[line.index(marker):])[0])
if len(records)!=1 or 'All tests passed!' not in r.stdout:raise SystemExit('Native memory acceptance did not complete')
v=records[0]
if any(v.get(k) is not True for k in ['nativeMemory','typedFrb','explicitUiApproval','closedSelectionRejected','reopenRequiredExplicitGrant','persistedAfterReopen','draftDiscoveredAndDiscardedAfterReopen','readonlyWriteRejected','removedFromDisabledScope']) or v.get('modelInference') is not False or v.get('fullUnicodeBytes',0)<=4096:raise SystemExit('Native memory evidence is incomplete')
print('PASS actual native manual memory creation/approval/complete Unicode read/close/reopen/readonly rejection; no model inference or other-platform certificate')
