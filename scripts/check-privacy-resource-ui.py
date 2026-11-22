#!/usr/bin/env python3
"""Run the pinned Flutter resource-state interaction in this checkout."""
import subprocess
from environment import APP, tool_environment

env,tools=tool_environment()
subprocess.run([tools['flutter'],'pub','get','--offline','--enforce-lockfile'],cwd=APP,env=env,check=True)
done=subprocess.run([tools['flutter'],'test','--no-pub','test/privacy_budget_test.dart'],cwd=APP,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=300)
print(done.stdout,end='');done.check_returncode()
if 'resource choices leave an uninstalled local-only model idle' not in done.stdout or 'All tests passed!' not in done.stdout:
    raise SystemExit('Expected local-only interaction proof')
