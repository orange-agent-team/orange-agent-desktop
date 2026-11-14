#!/usr/bin/env python3
"""Owned signed native export; chooser/model callbacks remain explicit fixtures."""
import json
import subprocess
import sys
from environment import ROOT,APP,tool_environment
subprocess.run([sys.executable,str(ROOT/'scripts/check-bridge.py')],cwd=ROOT,check=True)
env,tools=tool_environment()
r=subprocess.run([str(tools['flutter']),'--suppress-analytics','test','integration_test/export_test.dart','-d','macos','--no-pub'],cwd=APP,env=env,capture_output=True,text=True,timeout=900)
print(r.stdout,end='',flush=True);print(r.stderr,end='',flush=True);r.check_returncode()
records=[]
for line in r.stdout.replace('\r','\n').splitlines():
    needle='{"nativeRetentionExport":'
    if needle in line:
        record,_=json.JSONDecoder().raw_decode(line[line.index(needle):]);records.append(record)
if len(records)!=1 or 'All tests passed!' not in r.stdout:raise SystemExit('Native export acceptance incomplete')
a=records[0]
for key in ['nativeRetentionExport','actualArtifactVerified','receiptFailureUnknown','pendingNeverPublished','destinationClosedBeforeSource','recordsSurviveReopen']:
    if a.get(key) is not True:raise SystemExit('Missing native export evidence: '+key)
if any(a.get(k)!=v for k,v in {'approvalCalls':2,'lostReplyLookups':2,'sourceFilesRetained':2,'exportFiles':2,'ordinaryAccessRestored':False}.items()):raise SystemExit('Authority/no-replay evidence differs')
print('PASS actual signed macOS/FRB source inspection, independent destination, exact export confirmation, artifact bytes/SHA/mode, conflict/no overwrite, lost response query, real receipt fault unknown, cached permits drained before native release and restart index; no manual-picker/real-model/otherOS/disposal certificate')
