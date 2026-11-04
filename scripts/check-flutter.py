#!/usr/bin/env python3
"""Certify the available macOS toolchain/build, never infer Windows/Linux runtime support."""
import datetime
import hashlib
import json
import platform
import plistlib
import subprocess
import sys
from environment import ROOT,APP,tool_environment
if platform.system()!='Darwin' or platform.machine()!='arm64':raise SystemExit('This evidence command is for the available macOS ARM64 host')
environment,tools=tool_environment()
lock=json.loads((ROOT/'config/flutter.lock.json').read_text())
version=json.loads(subprocess.check_output([str(tools['flutter']),'--suppress-analytics','--version','--machine'],cwd=ROOT,env=environment,text=True))
if version['frameworkVersion']!=lock['version'] or version['frameworkRevision']!=lock['framework_revision'] or version['dartSdkVersion']!=lock['dart_version']:
    raise SystemExit('SDK runtime version differs from fixed official artifact')
subprocess.run([sys.executable,str(ROOT/'scripts/import-runtime.py'),'--verify'],check=True)
subprocess.run([str(tools['flutter']),'--suppress-analytics','pub','get','--offline','--enforce-lockfile'],cwd=APP,env=environment,check=True)
subprocess.run([str(tools['flutter']),'--suppress-analytics','build','macos','--debug','--no-pub','--target','lib/main.dart'],cwd=APP,env=environment,check=True,timeout=900)
apps=list((APP/'build/macos/Build/Products/Debug').glob('*.app'))
if len(apps)!=1:raise SystemExit('Expected exactly one built development app')
app=apps[0];info=plistlib.loads((app/'Contents/Info.plist').read_bytes());binary=app/'Contents/MacOS'/info['CFBundleExecutable']
native=app/'Contents/Frameworks/orange_desktop_bridge.framework/Versions/A/orange_desktop_bridge'
if not native.is_file():raise SystemExit('Native bridge framework was not bundled')
architectures=subprocess.check_output(['xcrun','lipo','-archs',str(binary)],text=True).strip().split()
if 'arm64' not in architectures:raise SystemExit('Built app does not include the tested host architecture')
report={'at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'flutter':lock['version'],'dart':lock['dart_version'],'framework_revision':lock['framework_revision'],'rust':json.loads((ROOT/'config/bridge-tools.lock.json').read_text())['rust'],'platform':'macos-arm64','app':str(app.relative_to(ROOT)),'architectures':architectures,'executable_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'native_bridge_sha256':hashlib.sha256(native.read_bytes()).hexdigest(),'certification':'local development build only; no production signing/notarization, Windows/Linux or Agent feature certification'}
folder=ROOT/'.local/build-evidence';folder.mkdir(parents=True,exist_ok=True);(folder/'flutter-macos.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
