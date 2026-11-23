"""Qualify the normal startup retry, keyboard control and a real FRB/SQLite Host on macOS."""
import argparse
import json
from pathlib import Path
import platform
import subprocess
from environment import ROOT,APP,tool_environment
from model_bundle import digest

def main():
    cli=argparse.ArgumentParser()
    cli.add_argument("--bridge-library",type=Path,help="Specific existing bridge library to test; its archive provenance is verified separately")
    args=cli.parse_args()
    if (platform.system(),platform.machine())!=("Darwin","arm64"):raise SystemExit("This native qualification requires macOS arm64")
    env,tools=tool_environment()
    subprocess.run([tools["flutter"],"--suppress-analytics","pub","get","--offline","--enforce-lockfile"],cwd=APP,env=env,check=True)
    if args.bridge_library:lib=args.bridge_library.resolve(strict=True)
    else:
        subprocess.run([tools["cargo"],"build","--locked","--offline","-p","orange-desktop-bridge"],cwd=ROOT,env=env,check=True)
        meta=json.loads(subprocess.check_output([tools["cargo"],"metadata","--no-deps","--locked","--format-version","1"],cwd=ROOT,env=env))
        lib=Path(meta["target_directory"])/"debug/liborange_desktop_bridge.dylib"
    subprocess.run([tools["flutter"],"--suppress-analytics","test","--no-pub","test/desktop_connection_test.dart",
        "acceptance/desktop_startup_retry_test.dart"],cwd=APP,env=dict(env,ORANGE_STARTUP_TEST_LIBRARY=str(lib)),check=True)
    print(json.dumps({"bridge_sha256":digest(lib),"source":subprocess.check_output(["git","rev-parse","HEAD"],cwd=ROOT,text=True).strip(),
        "supplied_library":bool(args.bridge_library),"platform":"macOS arm64","keyboard_retry":True,"concurrent_attempt_shared":True,
        "real_missing_library":True,"real_invalid_directory":True,"opened_and_inspected_real_host":True}))
    print("PASS keyboard startup retry, single bridge initialization after recovery, and real macOS FRB journal access")
if __name__=="__main__":main()
