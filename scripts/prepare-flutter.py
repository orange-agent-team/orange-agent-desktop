#!/usr/bin/env python3
"""Install only the pinned official SDK under this repository. No global PATH changes."""
import argparse
import fcntl
import hashlib
import json
from pathlib import Path,PurePosixPath
import platform
import posixpath
import shutil
import stat
import subprocess
import tempfile
import zipfile
ROOT=Path(__file__).resolve().parents[1]
lock=json.loads((ROOT/'config/flutter.lock.json').read_text())
parser=argparse.ArgumentParser();parser.add_argument('action',choices=['install','status']);args=parser.parse_args()
if platform.system()!='Darwin' or platform.machine()!='arm64':
    raise SystemExit('This lock certifies macOS ARM64 only; other targets require their own pinned SDK artifact')
if not lock['url'].startswith('https://storage.googleapis.com/flutter_infra_release/releases/stable/macos/'):
    raise SystemExit('Only the pinned official Flutter archive is allowed')
cache=ROOT/'.local/flutter-download';cache.mkdir(parents=True,exist_ok=True)
destination=ROOT/'.local/toolchains'/('flutter-'+lock['version'])
sdk=destination/'flutter'
def installed():
    if not sdk.is_dir():return False
    revision=subprocess.check_output(['git','-C',str(sdk),'rev-parse','HEAD'],text=True).strip()
    if revision!=lock['framework_revision']:raise SystemExit('Installed Flutter revision differs from lock')
    return True
if args.action=='status':
    print(json.dumps({'installed':installed(),'sdk':str(sdk),'version':lock['version']}));raise SystemExit(0)
with (cache/'prepare.lock').open('a+b') as held:
    fcntl.flock(held,fcntl.LOCK_EX|fcntl.LOCK_NB)
    if installed():print('Pinned SDK already installed:',sdk);raise SystemExit(0)
    partial=cache/('flutter_macos_arm64_'+lock['version']+'-stable.zip.part')
    if partial.is_symlink():raise SystemExit('Refuse linked download staging file')
    if not partial.is_file() or partial.stat().st_size!=lock['bytes']:
        subprocess.run(['curl','--fail','--silent','--show-error','--connect-timeout','20','--max-time','900','--max-filesize',str(lock['bytes']),'--continue-at','-','--retry','2','--retry-max-time','1200','--output',str(partial),lock['url']],check=True)
    if partial.stat().st_size!=lock['bytes']:raise SystemExit('SDK archive byte count differs from lock')
    sha=hashlib.sha256()
    with partial.open('rb') as stream:
        for chunk in iter(lambda:stream.read(8*1024*1024),b''):sha.update(chunk)
    if sha.hexdigest()!=lock['sha256']:raise SystemExit('SDK checksum mismatch; archive was not extracted or executed')
    with zipfile.ZipFile(partial) as archive:
        total=0
        for entry in archive.infolist():
            path=PurePosixPath(entry.filename)
            if path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0]!='flutter' or '\\' in entry.filename:
                raise SystemExit('Unsafe SDK archive path')
            total+=entry.file_size
            if total>20*1024**3:raise SystemExit('SDK extraction size exceeds limit')
            if stat.S_ISLNK(entry.external_attr>>16):
                target=archive.read(entry).decode('utf-8')
                resolved=posixpath.normpath(str(path.parent/PurePosixPath(target)))
                if target.startswith('/') or not resolved.startswith('flutter/'):
                    raise SystemExit('SDK symbolic link escapes extraction root')
    if shutil.disk_usage(ROOT).free<total+2*1024**3:raise SystemExit('Insufficient disk for bounded SDK extraction')
    destination.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='flutter-stage-',dir=destination.parent) as staging:
        subprocess.run(['/usr/bin/ditto','-x','-k',str(partial),staging],check=True)
        staged=Path(staging)/'flutter'
        revision=subprocess.check_output(['git','-C',str(staged),'rev-parse','HEAD'],text=True).strip()
        if revision!=lock['framework_revision']:raise SystemExit('Extracted revision does not match official manifest')
        destination.mkdir(mode=0o700)
        staged.rename(sdk)
    print('Installed verified SDK:',sdk)
