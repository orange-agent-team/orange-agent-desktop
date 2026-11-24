"""Exercise the typed macOS bridge, document selection, app controls and revocation."""
import argparse
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
from environment import APP,ROOT,tool_environment
from model_bundle import digest

def main():
    cli=argparse.ArgumentParser()
    cli.add_argument("--bridge-library",type=Path,help="Verify a previously extracted framework by its actual path")
    cli.add_argument("--native-app",action="store_true")
    args=cli.parse_args()
    if (platform.system(),platform.machine())!=("Darwin","arm64"):raise SystemExit("macOS arm64 native qualification required")
    env,tools=tool_environment()
    subprocess.run([sys.executable,ROOT/"scripts/import-runtime.py","--verify"],env=env,check=True)
    subprocess.run([tools["flutter"],"--suppress-analytics","pub","get","--offline","--enforce-lockfile"],cwd=APP,env=env,check=True)
    if args.bridge_library:lib=args.bridge_library.resolve(strict=True)
    else:
        subprocess.run([tools["cargo"],"build","--offline","--locked","-p","orange-desktop-bridge"],env=env,cwd=ROOT,check=True)
        meta=json.loads(subprocess.check_output([tools["cargo"],"metadata","--locked","--no-deps","--format-version","1"],env=env,cwd=ROOT))
        lib=Path(meta["target_directory"])/"debug/liborange_desktop_bridge.dylib"
    subprocess.run([tools["flutter"],"--suppress-analytics","test","--no-pub","acceptance/selected_knowledge_test.dart"],cwd=APP,env=dict(env,ORANGE_KNOWLEDGE_BRIDGE=str(lib)),check=True)
    if args.native_app:
        subprocess.run([tools["flutter"],"--suppress-analytics","drive","--no-pub","-d","macos",
                        "--target=test_driver/knowledge_app.dart","--driver=test_driver/knowledge_driver.dart"],cwd=APP,env=env,check=True,timeout=900)
    print(json.dumps({"runtime_source":json.loads((ROOT/"config/runtime.lock.json").read_bytes())["origin_commit"],"bridge_sha256":digest(lib),
                      "supplied_library":bool(args.bridge_library),"native_window":args.native_app,"workspace_selection":"owned development fixture",
                      "typed_native_calls":True,"old_content_hidden":True,"closed_selection_replay_denied":True}))
    print("PASS Flutter knowledge selection, live Rust retrieval, hidden stale content and enforced OS grant")
if __name__=="__main__":main()
