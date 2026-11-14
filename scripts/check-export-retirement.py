#!/usr/bin/env python3
"""Actual signed app capture/reopen; chooser/model callbacks are explicit fixtures."""
import json,subprocess,sys
from environment import ROOT
r=subprocess.run([sys.executable,str(ROOT/'scripts/check-export-inspection.py')],cwd=ROOT,capture_output=True,text=True,timeout=1500)
print(r.stdout,end='',flush=True);print(r.stderr,end='',flush=True);r.check_returncode()
rows=[]
for line in r.stdout.replace('\r','\n').splitlines():
    needle='{"nativeExportRetirement":'
    if needle in line:
        v,_=json.JSONDecoder().raw_decode(line[line.index(needle):]);rows.append(v)
if len(rows)!=1:raise SystemExit('Native retirement evidence missing')
v=rows[0]
for key in ['nativeExportRetirement','independentWriteSelection','exactApproval','actualBytesRetained','otherExportUnchanged','unknownExportNotRepaired','recordsSurviveReopen','freshCapsuleInspection','closedBeforeNativeRelease']:
    if v.get(key) is not True:raise SystemExit('Retirement assertion missing: '+key)
if v.get('automaticReplay') is not False or v.get('permanentDeletion') is not False:raise SystemExit('Incorrect retirement boundary')
print('PASS actual signed macOS/FRB reversible export retirement, current capsule inspection and reopen without replay. No erasure, quota release, manual picker, real model or other OS certificate.')
