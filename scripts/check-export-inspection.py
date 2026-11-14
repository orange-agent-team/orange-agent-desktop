#!/usr/bin/env python3
"""Actual destination-only inspection after lost receipt and source removal."""
import json
import subprocess
import sys
from environment import ROOT
r=subprocess.run([sys.executable,str(ROOT/'scripts/check-export.py')],cwd=ROOT,capture_output=True,text=True,timeout=1200)
print(r.stdout,end='',flush=True);print(r.stderr,end='',flush=True);r.check_returncode()
rows=[]
for line in r.stdout.replace('\r','\n').splitlines():
    needle='{"nativeExportInspection":'
    if needle in line:
        value,_=json.JSONDecoder().raw_decode(line[line.index(needle):]);rows.append(value)
if len(rows)!=1:raise SystemExit('Actual independent inspection did not complete')
a=rows[0]
for key in ['nativeExportInspection','sourceUnavailable','unknownStillUnknown','actualTargetMatches','closedBeforeNativeRelease']:
    if a.get(key) is not True:raise SystemExit('Missing inspection evidence: '+key)
if a.get('sourceAccessRestored') is not False or a.get('sourceFilesRetained')!=2 or a.get('exportFiles')!=2:raise SystemExit('Readonly/source isolation evidence differs')
print('PASS actual signed macOS destination-only inspection, no source restoration, unknown retained despite matching file, drain before native release and unchanged files; model/chooser callbacks fixtures, no manual-picker/cleanup/disposal/otherOS certificate')
