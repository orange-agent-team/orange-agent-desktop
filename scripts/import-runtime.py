#!/usr/bin/env python3
"""Explicit artifact import; ordinary builds verify local sources without reading another repo."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path,PurePosixPath
import tarfile
import tempfile
ROOT=Path(__file__).resolve().parents[1]
lock=json.loads((ROOT/'config/runtime.lock.json').read_text())
parser=argparse.ArgumentParser();parser.add_argument('--archive');parser.add_argument('--verify',action='store_true');args=parser.parse_args()
def safe_name(name):
    p=PurePosixPath(name)
    if not p.parts or p.is_absolute() or p.as_posix()!=name or any(part in ['.','..'] for part in p.parts) or '\\' in name or '\0' in name:
        raise SystemExit('Unsafe artifact path')
    return p
vendor_path=safe_name(lock['vendor_directory'])
if vendor_path.parts[0]!='vendor':raise SystemExit('Runtime import must remain below vendor/')
destination=ROOT/str(vendor_path)
current=ROOT
for part in vendor_path.parts:
    current=current/part
    if current.is_symlink():raise SystemExit('Linked vendor path refused')
def manifest_valid(manifest):
    for key in ['schema','origin_commit','version','members']:
        if manifest.get(key)!=lock[key]:raise SystemExit('Runtime provenance differs from locked '+key)
def verify():
    if destination.is_symlink() or not destination.is_dir():raise SystemExit('Imported runtime missing or linked')
    release=destination/'release-manifest.json'
    if release.is_symlink():raise SystemExit('Linked release manifest')
    if hashlib.sha256(release.read_bytes()).hexdigest()!=lock['release_manifest_sha256']:raise SystemExit('Release manifest differs from lock')
    manifest=json.loads(release.read_text());manifest_valid(manifest)
    expected=set(manifest['content_sha256'])|{'release-manifest.json'};actual=set()
    for directory,folders,names in os.walk(destination,followlinks=False):
        for folder in folders:
            if (Path(directory)/folder).is_symlink():raise SystemExit('Linked runtime directory')
        folders[:]=[name for name in folders if name!='target']
        for name in names:
            path=Path(directory)/name;relative=path.relative_to(destination).as_posix()
            if path.is_symlink() or not path.is_file():raise SystemExit('Linked or irregular runtime source')
            actual.add(relative)
            if relative!='release-manifest.json' and hashlib.sha256(path.read_bytes()).hexdigest()!=manifest['content_sha256'].get(relative):
                raise SystemExit('Runtime source differs from committed release: '+relative)
    if actual!=expected:raise SystemExit('Runtime file inventory differs from release')
    print('PASS fixed local runtime source inventory:',lock['origin_commit'])
if args.verify:
    verify();raise SystemExit(0)
if not args.archive:raise SystemExit('Provide an explicit --archive; build verification never locates adjacent repositories')
archive_path=Path(args.archive)
if not archive_path.is_file() or archive_path.stat().st_size!=lock['archive_bytes']:raise SystemExit('Archive byte count differs')
payload=archive_path.read_bytes()
if hashlib.sha256(payload).hexdigest()!=lock['archive_sha256']:raise SystemExit('Archive SHA-256 differs from lock')
files={};modes={};total=0
with tarfile.open(fileobj=io.BytesIO(payload),mode='r:gz') as archive:
    for entry in archive:
        safe_name(entry.name)
        if not entry.isfile() or entry.name in files or len(files)>=10000:raise SystemExit('Only unique regular source files allowed')
        total+=entry.size
        if total>50*1024*1024:raise SystemExit('Source archive exceeds limit')
        files[entry.name]=archive.extractfile(entry).read();modes[entry.name]=entry.mode&0o755
if hashlib.sha256(files['release-manifest.json']).hexdigest()!=lock['release_manifest_sha256']:raise SystemExit('Archive release manifest differs from lock')
manifest=json.loads(files['release-manifest.json']);manifest_valid(manifest)
if set(files)!=(set(manifest['content_sha256'])|{'release-manifest.json'}):raise SystemExit('Archive inventory mismatch')
for name,sha in manifest['content_sha256'].items():
    if hashlib.sha256(files[name]).hexdigest()!=sha:raise SystemExit('Archive source checksum mismatch')
if destination.exists():verify();raise SystemExit(0)
destination.parent.mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory(prefix='runtime-import-',dir=destination.parent) as directory:
    stage=Path(directory)/'runtime';stage.mkdir()
    for name,content in files.items():
        target=stage/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(content);target.chmod(modes[name])
    stage.rename(destination)
verify()
