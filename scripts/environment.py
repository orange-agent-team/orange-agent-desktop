"""Task-local tool paths; no mutation of HOME, default Rust toolchain or global PATH."""
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
ROOT=Path(__file__).resolve().parents[1]
APP=ROOT/'apps/desktop'
def tool_environment(generators=False):
    flutter=json.loads((ROOT/'config/flutter.lock.json').read_text())
    tools=json.loads((ROOT/'config/bridge-tools.lock.json').read_text())
    channel=re.search(r'^channel\s*=\s*"([^"]+)"$',(ROOT/'crates/desktop-bridge/rust-toolchain.toml').read_text(),re.M)
    if channel is None or channel.group(1)!=tools['rust']:raise SystemExit('Native Assets Rust toolchain differs from generator lock')
    rustup=Path(shutil.which('rustup') or '/opt/homebrew/opt/rustup/bin/rustup')
    cargo=Path(subprocess.check_output([str(rustup),'which','--toolchain',tools['rust'],'cargo'],text=True).strip())
    sdk=ROOT/'.local/toolchains'/('flutter-'+flutter['version'])/'flutter'
    frb=ROOT/'.local/tools'/('frb-'+tools['flutter_rust_bridge'])/'bin/flutter_rust_bridge_codegen'
    expand=ROOT/'.local/tools'/('cargo-expand-'+tools['cargo_expand'])/'bin/cargo-expand'
    environment=os.environ.copy()
    paths=[sdk/'bin',cargo.parent,rustup.parent]
    if generators:paths=[frb.parent,expand.parent,*paths]
    environment['PATH']=os.pathsep.join(map(str,paths))+os.pathsep+environment.get('PATH','')
    environment['PUB_CACHE']=str(ROOT/'.local/pub-cache')
    environment['PUB_HOSTED_URL']='https://pub.dev'
    environment['FLUTTER_STORAGE_BASE_URL']='https://storage.googleapis.com'
    environment['FLUTTER_SUPPRESS_ANALYTICS']='true'
    environment['DASH__SUPPRESS_ANALYTICS']='true'
    environment['XDG_CONFIG_HOME']=str(ROOT/'.local/flutter-config')
    actual=subprocess.check_output([str(cargo.parent/'rustc'),'--version'],env=environment,text=True)
    if not actual.startswith('rustc '+tools['rust']+' '):raise SystemExit('Rust version mismatch')
    revision=subprocess.check_output(['git','-C',str(sdk),'rev-parse','HEAD'],text=True).strip()
    if revision!=flutter['framework_revision']:raise SystemExit('Flutter revision mismatch')
    if generators:
        for binary,expected in [(frb,tools['flutter_rust_bridge']),(expand,tools['cargo_expand'])]:
            actual=subprocess.check_output([str(binary),'--version'],env=environment,text=True).strip().split()[-1]
            if actual!=expected:raise SystemExit('Generator version mismatch')
    return environment,{'cargo':cargo,'flutter':sdk/'bin/flutter','dart':sdk/'bin/dart','frb':frb}
