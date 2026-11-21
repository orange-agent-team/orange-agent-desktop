#!/usr/bin/env python3
"""Check the desktop-owned product matrix and its explicitly selected producer, independent of application builds."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
root=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser()
p.add_argument('--server-repo',type=Path,required=True)
p.add_argument('--step',choices=['entries','normal','exits'],required=True)
args=p.parse_args()
source=args.server_repo.resolve()
folder=root/'docs/product-journeys'
release=json.loads((folder/'source.json').read_bytes())
if release['producer']!='orange-agent-server' or release['requirement']!='PRD-002':
    raise SystemExit('Wrong workflow producer or requirement')
for name in ['README.md','flows.json','surfaces.md']:
    entry=release['files'][name]
    if entry['source']!='docs/product-journeys/'+name:raise SystemExit('Unexpected source location')
    fixed=subprocess.check_output(['git','show',release['source_commit']+':'+entry['source']],cwd=source)
    if (folder/name).read_bytes()!=fixed or hashlib.sha256(fixed).hexdigest()!=entry['sha256']:
        raise SystemExit('Desktop workflow snapshot differs from fixed source: '+name)
    if (source/entry['source']).read_bytes()!=fixed:raise SystemExit('Working integration matrix needs compatibility review: '+name)
subprocess.run([sys.executable,source/'scripts/check-product-journeys.py','--step',args.step],cwd=source,check=True)
print('PASS desktop fixed journey snapshot and selected server contract phase '+args.step)
