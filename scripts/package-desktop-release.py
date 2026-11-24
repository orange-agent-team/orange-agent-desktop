#!/usr/bin/env python3
"""Build two private Apple Silicon release apps, inspect signatures/ABI, compare and archive."""
import argparse
import gzip
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import stat
import shutil
import subprocess
import sys
import tarfile
import tempfile

from environment import APP,ROOT,tool_environment
from model_bundle import STAGED,digest,verify_bundle,verify_embedded


def build():
    env,tools=tool_environment()
    env.update(FLUTTER_MACOS_ARM64_ONLY="true",CARGO_NET_OFFLINE="true",CARGO_INCREMENTAL="0",ZERO_AR_DATE="1",TZ="UTC",
               RUSTFLAGS="--remap-path-prefix="+str(ROOT)+"=/orange-desktop",
               CFLAGS="-ffile-prefix-map="+str(ROOT)+"=/orange-desktop",
               CXXFLAGS="-ffile-prefix-map="+str(ROOT)+"=/orange-desktop")
    lock=json.loads((ROOT/"config/flutter.lock.json").read_bytes())
    found=json.loads(subprocess.check_output([tools["flutter"],"--suppress-analytics","--version","--machine"],env=env,cwd=ROOT))
    if any(found[field]!=lock[key] for field,key in [("frameworkVersion","version"),("frameworkRevision","framework_revision"),("dartSdkVersion","dart_version")]):
        raise ValueError("Flutter SDK does not match the pinned release")
    verify_bundle(STAGED)
    subprocess.run([sys.executable,ROOT/"scripts/import-runtime.py","--verify"],cwd=ROOT,check=True)
    for args in (["pub","get","--enforce-lockfile","--offline"],["build","macos","--release","--no-pub","--target","lib/main.dart"]):
        subprocess.run([tools["flutter"],"--suppress-analytics",*args],cwd=APP,env=env,timeout=1200,check=True)


def inspect(app):
    contents=app/"Contents";info=plistlib.loads((contents/"Info.plist").read_bytes())
    exe=contents/"MacOS"/info["CFBundleExecutable"]
    subprocess.run(["codesign","--verify","--deep","--strict",app],check=True)
    ent=plistlib.loads(subprocess.check_output(["codesign","-d","--entitlements",":-",app],stderr=subprocess.DEVNULL))
    expected={"com.apple.security.app-sandbox","com.apple.security.network.client","com.apple.security.files.user-selected.read-write"}
    if any(ent.get(k) is not True for k in expected) or ent.get("com.apple.security.get-task-allow"):
        raise ValueError("Unexpected desktop release entitlements")
    model=verify_embedded(contents)
    marker=json.loads((contents/"Resources/orange-model-embed.json").read_bytes())
    if marker["configuration"]!="Release":raise ValueError("Release build required")
    archs=subprocess.check_output(["xcrun","lipo","-archs",exe],text=True).split()
    if archs!=["arm64"]:raise ValueError("Only the qualified arm64 build may use this package")
    if any(p.is_file() for p in app.rglob("*.gguf")):raise ValueError("Weights are separate from the desktop distribution")
    result=subprocess.run([exe,"--verify-installation"],capture_output=True,text=True,timeout=35,check=True)
    receipt=json.loads(result.stdout)
    dart=(APP/"lib/src/rust/frb_generated.dart").read_text()
    pin=int(re.search(r"int get rustContentHash => (-?\d+);",dart)[1])
    if receipt!={"bundle_id":info["CFBundleIdentifier"],"bridge_content_hash":pin}:raise ValueError("Installed bridge ABI mismatch")
    return {"app_bundle_id":info["CFBundleIdentifier"],"version":info["CFBundleShortVersionString"],
            "architectures":archs,"app_minimum_macos":info.get("LSMinimumSystemVersion"),"model_backend_minimum_macos":model["minimum_macos"],
            "runtime_commit":model["runtime_commit"],"sandboxed":True,"bridge_probe":receipt,"local_signature_verified":True}


def archive(app,output):
    index={}
    with output.open("xb") as raw,gzip.GzipFile(fileobj=raw,mode="wb",mtime=0,filename="") as gz,tarfile.open(fileobj=gz,mode="w") as tar:
        for path in [app,*sorted(app.rglob("*"))]:
            relative=path.relative_to(app.parent).as_posix()
            info=tarfile.TarInfo(relative);mode=path.lstat().st_mode
            if stat.S_ISLNK(mode):
                target=os.readlink(path)
                if Path(target).is_absolute() or not path.resolve(strict=True).is_relative_to(app.resolve()):
                    raise ValueError("Uncontained app link "+relative)
                info.type=tarfile.SYMTYPE;info.linkname=target;info.mode=0o777;tar.addfile(info)
                index[relative]=["link",target]
            elif stat.S_ISDIR(mode):
                info.type=tarfile.DIRTYPE;info.mode=0o755;tar.addfile(info);index[relative]=["directory"]
            elif stat.S_ISREG(mode):
                info.mode=0o755 if mode&0o111 else 0o644;info.size=path.stat().st_size
                index[relative]=["file",info.mode,digest(path)]
                with path.open("rb") as stream:tar.addfile(info,stream)
            else:raise ValueError("Unexpected bundle member")
    return index


def package():
    commit=subprocess.check_output(["git","rev-parse","HEAD"],cwd=ROOT,text=True).strip()
    epoch=subprocess.check_output(["git","show","-s","--format=%ct",commit],cwd=ROOT,text=True).strip()
    distribution=ROOT/".local/desktop-distributions";distribution.mkdir(mode=0o700,parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="orange-desktop-release-",dir="/private/tmp") as tmp:
        scratch=Path(tmp)
        seen=[];archives=[];probes=[]
        for i in range(2):
            tree=scratch/str(i);tree.mkdir(mode=0o700)
            with tempfile.TemporaryFile() as stream:
                subprocess.run(["git","archive",commit],cwd=ROOT,stdout=stream,check=True);stream.seek(0)
                with tarfile.open(fileobj=stream) as tar:tar.extractall(tree,filter="data")
            (tree/".local").mkdir(mode=0o700)
            for name in ("toolchains","pub-cache","model-bundle"):
                subprocess.run(["cp","-cR",(ROOT/".local"/name).resolve(strict=True),tree/".local"/name],check=True)
            env=dict(os.environ,SOURCE_DATE_EPOCH=epoch)
            subprocess.run([sys.executable,tree/"scripts/package-desktop-release.py","--build-checkout"],cwd=tree,env=env,check=True)
            app,=list((tree/"apps/desktop/build/macos/Build/Products/Release").glob("*.app"))
            probes.append(inspect(app))
            target=scratch/(str(i)+".tar.gz");seen.append(archive(app,target));archives.append(target)
        hashes=[digest(x) for x in archives]
        if hashes[0]!=hashes[1]:
            differences=[{"member":n,"first":seen[0].get(n),"second":seen[1].get(n)}
                         for n in sorted(set(seen[0])|set(seen[1])) if seen[0].get(n)!=seen[1].get(n)]
            # Retain only differing native executables for diagnosing the signed inputs.
            # The original app artifacts, user data and signing state are never modified.
            diagnostics=distribution/"diagnostics"/commit
            for difference in differences:
                member=difference["member"]
                if member.endswith(("/orange_desktop_bridge","/MacOS/orange_desktop")):
                    for i in range(2):
                        app_root=scratch/str(i)/"apps/desktop/build/macos/Build/Products/Release"
                        dest=diagnostics/str(i)/Path(member).name
                        dest.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
                        shutil.copy2(app_root/member,dest)
            failure={"source":commit,"archive_digests":hashes,"changed_members":differences,"inspections":probes}
            (distribution/(commit+"-differences.json")).write_text(json.dumps(failure,indent=2)+"\n")
            raise ValueError("Independent builds differ; inspect the per-member diagnostics")
        extracted=scratch/"unpacked";extracted.mkdir(mode=0o700)
        with tarfile.open(archives[0]) as tar:tar.extractall(extracted,filter="data")
        app,=list(extracted.glob("*.app"));proof=inspect(app)
        if probes!=[proof,proof]:raise ValueError("Unpacked install probe differs")
        out=distribution/("orange-desktop-macos-arm64-"+hashes[0][:16]+".tar.gz")
        if out.exists():
            if digest(out)!=hashes[0]:raise ValueError("Archive conflict")
        else:
            # The scratch path can be on a different APFS volume.
            with tempfile.NamedTemporaryFile(dir=distribution,delete=False) as tmp_out:
                stage=Path(tmp_out.name)
                try:
                    with archives[0].open("rb") as stream:shutil.copyfileobj(stream,tmp_out)
                    tmp_out.flush();os.fsync(tmp_out.fileno())
                    if digest(stage)!=hashes[0]:raise ValueError("Package copy changed")
                    os.link(stage,out)
                finally:stage.unlink(missing_ok=True)
        report={"source":commit,"archive":out.name,"sha256":hashes[0],"bytes":out.stat().st_size,"clean_builds":2,
                "members":len(seen[0]),"verification":proof,"public_signing_or_notarization":False}
        out.with_suffix(".json").write_text(json.dumps(report,indent=2)+"\n");print(json.dumps(report))


if __name__=="__main__":
    parser=argparse.ArgumentParser();parser.add_argument("--build-checkout",action="store_true");args=parser.parse_args()
    if (platform.system(),platform.machine())!=("Darwin","arm64") or sys.version_info[:2]!=(3,12):raise SystemExit("macOS arm64 and Python 3.12 required")
    if args.build_checkout:build()
    else:package()
