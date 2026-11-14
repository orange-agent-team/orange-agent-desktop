#!/usr/bin/env python3
"""Actual native recovery copies with explicit picker/model fixtures."""
import json,subprocess,sys
from environment import ROOT
r=subprocess.run([sys.executable,str(ROOT/'scripts/check-export-retirement.py')],cwd=ROOT,capture_output=True,text=True,timeout=1800)
print(r.stdout,end='',flush=True);print(r.stderr,end='',flush=True);r.check_returncode()
rows=[]
for line in r.stdout.replace('\r','\n').splitlines():
    needle='{"nativeExportRestoration":'
    if needle in line:
        v,_=json.JSONDecoder().raw_decode(line[line.index(needle):]);rows.append(v)
if len(rows)!=1:raise SystemExit('Native restoration evidence missing')
v=rows[0]
for key in ['nativeExportRestoration','independentWriteSelection','exactApproval','actualRestoredBytes','capsuleRetained','occupiedTargetUnchanged','receiptFailureUnknown','reopenWithoutReplay','freshTargetInspection','oldExportUnknownPreserved']:
    if v.get(key) is not True:raise SystemExit('Missing restoration assertion: '+key)
if v.get('nativeReleaseChecks')!=3 or v.get('restorationRecords')!=2 or v.get('permanentDeletion') is not False:raise SystemExit('Restoration scope differs')
print('PASS actual signed macOS recovery copies, preserved capsule, no overwrite, failed receipt unknown, fresh read inspection and reopen without replay. Picker/model callbacks fixtures; no erasure, budget release, manual-picker or other OS certification.')
