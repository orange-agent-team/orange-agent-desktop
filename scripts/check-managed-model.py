#!/usr/bin/env python3
"""Real fixed-model product path with an explicit temporary test weight payload.

Restores the original staged component bundle after the test. No user data or
running model state is deleted by this build-artifact fixture helper.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from environment import APP,ROOT,tool_environment
from model_bundle import STAGED,digest,regular,verify_bundle

def invalidate_hook():
    cache=APP/'.dart_tool/hooks_runner'
    if cache.is_symlink():raise RuntimeError('Linked generated hook cache')
    if cache.exists():shutil.rmtree(cache)

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--model',type=Path)
    parser.add_argument('--ui-search-only',action='store_true',help='Target only the real UI search case; does not certify the separate lifecycle case')
    parser.add_argument('--ui-memory-only',action='store_true',help='Verify real packaged model read/write and explicit memory approval')
    parser.add_argument('--download-only',action='store_true',help='Verify local consent, cancellation and the pinned download API using preverified cache content')
    parser.add_argument('--live-download',action='store_true',help='Also fetch the fixed public GGUF to an empty disposable cache')
    args=parser.parse_args()
    if args.live_download and not args.download_only:parser.error('--live-download requires --download-only')
    if args.download_only and (args.ui_search_only or args.ui_memory_only):parser.error('Choose one targeted scenario')
    if args.ui_search_only and args.ui_memory_only:parser.error('Choose one targeted scenario')
    original=verify_bundle(STAGED)
    if not args.live_download:
        if not args.model:parser.error('A fixed model fixture is required for offline tests')
        regular(args.model)
        if args.model.stat().st_size!=original['model']['bytes'] or digest(args.model)!=original['model']['sha256']:
            raise RuntimeError('Explicit fixed test model differs from catalog')
    temporary=Path(tempfile.mkdtemp(prefix='managed-model-bundle-',dir=ROOT/'.local'))
    backup=temporary/'original';fixture=temporary/'fixture'
    shutil.copytree(STAGED,fixture)
    if not args.live_download:
        shutil.copyfile(args.model,fixture/'test-model.gguf')
        manifest=json.loads((fixture/'manifest.json').read_text())
        manifest['test_model_included']=True
        manifest['files']['test-model.gguf']={'sha256':original['model']['sha256'],'bytes':original['model']['bytes'],'executable':False}
        (fixture/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    verify_bundle(fixture);expected=digest(fixture/'manifest.json')
    os.replace(STAGED,backup);os.replace(fixture,STAGED);invalidate_hook()
    try:
        environment,tools=tool_environment()
        command=[str(tools['flutter']),'--suppress-analytics','test','integration_test/managed_model_test.dart','-d','macos','--no-pub']
        if args.download_only:
            command[3]='integration_test/model_download_test.dart'
            if args.live_download:command.append('--dart-define=ORANGE_TEST_LIVE_DOWNLOAD=true')
            result=subprocess.run(command,cwd=APP,env=environment,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=1600)
            print(result.stdout,end='',flush=True);result.check_returncode()
            check='"liveDownload":true' if args.live_download else '"liveDownload":false'
            if check not in result.stdout or 'All tests passed!' not in result.stdout:raise RuntimeError('Required native download test did not finish')
        elif args.ui_memory_only:
            command[3]='integration_test/managed_task_memory_test.dart'
            result=subprocess.run(command,cwd=APP,env=environment,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=900)
            print(result.stdout,end='',flush=True);result.check_returncode()
            if '"actualModelRead":true' not in result.stdout or '"actualModelWrite":true' not in result.stdout or 'All tests passed!' not in result.stdout:
                raise RuntimeError('Packaged model memory verification did not finish')
        elif args.ui_search_only:
            command+=['--plain-name','production model buttons import and start a real packaged model before explicit Agent tool approval']
            result=subprocess.run(command,cwd=APP,env=environment,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=900)
            print(result.stdout,end='',flush=True);result.check_returncode()
            if '"actualTextSearch":true' not in result.stdout or '"deletedSearchSourceCleared":true' not in result.stdout or 'All tests passed!' not in result.stdout:
                raise RuntimeError('Actual UI search/deletion acceptance did not run to completion')
        else:
            subprocess.run(command,cwd=APP,env=environment,check=True,timeout=900)
    finally:
        # Preserve both sides if unexpected concurrent edits occurred, rather
        # than erasing unknown changes or claiming a successful restoration.
        verify_bundle(STAGED)
        if digest(STAGED/'manifest.json')!=expected:raise RuntimeError('Test bundle changed unexpectedly; original retained at '+str(backup))
        shutil.rmtree(STAGED);os.replace(backup,STAGED);invalidate_hook();shutil.rmtree(temporary)
    if args.download_only:
        print('PASS reviewed original model, isolated desktop state and native verified cache',flush=True)
    elif args.ui_memory_only:
        print('PASS real packaged CPU inference, separate memory read/write approvals, SQLite commit and parent withdrawal')
    elif args.ui_search_only:
        print('PASS actual packaged model UI read/text-search approval and source-deletion clearing; explicit owned selector fixtures. Separate lifecycle/35-second heartbeat case was not run by this targeted invocation')
    else:
        print('PASS actual packaged sandbox model import/start/35-second idle heartbeat and product UI approved file/text search with deleted-source clearing, instance fencing, Host-close cleanup, durable replay/cancel and unowned-process refusal. Native picker selections are explicit fixtures; no production signing, orphan reconciliation or broad hardware certificate')

if __name__=='__main__':
    path=ROOT/'.local/model-bundle.lock'
    fd=os.open(path,os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'a') as guard:
        if os.fstat(guard.fileno()).st_nlink!=1:raise RuntimeError('Linked bundle lock')
        fcntl.flock(guard,fcntl.LOCK_EX|fcntl.LOCK_NB);main()
