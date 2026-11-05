#!/usr/bin/env python3
"""Opt-in, explicit artifacts: real CPU model through the desktop Rust Host API.

Never searches adjacent repositories, downloads models, opens user workspaces,
or grants product tools automatic approval. All consent targets are owned fixtures.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import selectors
import subprocess
import tempfile
import time
import uuid
from environment import ROOT, tool_environment


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for data in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(data)
    return value.hexdigest()


def write(path, value):
    with path.open('w') as stream:
        json.dump(value, stream)
    path.chmod(0o600)


def main():
    parser = argparse.ArgumentParser()
    for option in ['model-lock', 'build-manifest', 'model', 'backend', 'model-host']:
        parser.add_argument('--' + option, type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    report_dir = ROOT / '.local/real-run'
    report_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    report = {'passed': False, 'phase': 'preparing', 'test_run_id': uuid.uuid4().hex}
    write(report_dir / 'last-report.json', report)
    lock = json.loads(args.model_lock.read_text())
    build = json.loads(args.build_manifest.read_text())
    model, backend, executable = [p.resolve(strict=True) for p in [args.model, args.backend, args.model_host]]
    if model.stat().st_size != lock['model']['bytes'] or digest(model) != lock['model']['sha256']:
        raise RuntimeError('Pinned real model size/digest differs')
    if build['backend_commit'] != lock['backend']['commit'] or build['gpu_enabled'] or digest(backend) != build['executable_sha256']:
        raise RuntimeError('Verified fixed CPU backend required')
    environment, tools = tool_environment()
    subprocess.run([str(tools['cargo']), 'build', '-p', 'orange-desktop-bridge', '--example', 'run-acceptance', '--locked', '--offline'], cwd=ROOT, env=environment, check=True)
    report.update({'model_sha256': lock['model']['sha256'], 'backend_commit': lock['backend']['commit'],
                   'model_host_sha256': digest(executable), 'runtime_commit': json.loads((ROOT / 'config/runtime.lock.json').read_text())['origin_commit']})
    with tempfile.TemporaryDirectory(prefix='oa-desktop-', dir='/private/tmp' if os.uname().sysname == 'Darwin' else None) as temporary:
        base = Path(temporary).resolve()
        private, workspace = base / 'h', base / 'w'
        runtime = private / ('durable-model-state-' * 6)
        ipc = base / 'm'
        runtime.mkdir(parents=True, mode=0o700)
        private.chmod(0o700)
        workspace.mkdir(mode=0o700)
        ipc.mkdir(mode=0o700)
        import_config=base/'import.json'
        descriptor=lock['model']
        write(import_config,{'source':str(model),'cache':str(private/'models'),'url':'https://huggingface.co/'+descriptor['repository']+'/resolve/'+descriptor['revision']+'/'+descriptor['file'],'sha256':descriptor['sha256'],'bytes':descriptor['bytes']})
        import_command=[str(ROOT/'target/debug/examples/run-acceptance'),'--import',str(import_config)]
        imported=json.loads(subprocess.check_output(import_command,env=environment,text=True,timeout=180))
        reused=json.loads(subprocess.check_output(import_command,env=environment,text=True,timeout=180))
        if imported!={'imported':True,'cached':False,'sha256':descriptor['sha256'],'bytes':str(descriptor['bytes'])} or reused!={**imported,'cached':True}:
            raise RuntimeError('Actual private model import/cache reuse failed')
        installed=private/'models'/(descriptor['sha256']+'.gguf')
        if digest(installed)!=descriptor['sha256'] or installed.stat().st_nlink!=1 or (installed.stat().st_dev,installed.stat().st_ino)==(model.stat().st_dev,model.stat().st_ino):
            raise RuntimeError('Installed artifact is not an independently verified copy')
        report['actual_private_model_import']=True
        report['verified_cache_reuse']=True
        report['separate_private_ipc'] = True
        report['durable_socket_path_bytes'] = len(os.fsencode(runtime / 'engine.sock'))
        report['actual_socket_path_bytes'] = len(os.fsencode(ipc / 'engine.sock'))
        if report['durable_socket_path_bytes'] <= 100 or report['actual_socket_path_bytes'] > 100:
            raise RuntimeError('Long-state/short-IPC regression not exercised')
        sentinel = 'ORANGE_DESKTOP_' + uuid.uuid4().hex
        (workspace / 'proof.txt').write_text(sentinel + '\n')
        nonce, instance = uuid.uuid4().hex + uuid.uuid4().hex, uuid.uuid4().hex
        write(runtime / 'profile.json', {'protocol': 1, 'runtime_directory': str(runtime), 'socket_directory': str(ipc), 'executable': str(backend),
              'executable_sha256': build['executable_sha256'], 'model': str(installed), 'model_sha256': lock['model']['sha256'],
              'model_bytes': lock['model']['bytes'], 'model_version': 'qwen-desktop-acceptance-v1', 'context_tokens': 4096,
              'startup_timeout_seconds': 120, 'control_nonce': nonce, 'instance_id': instance})
        config = base / 'acceptance.json'
        write(config, {'private_root': str(private), 'service_root': str(runtime), 'workspace': str(workspace), 'sentinel': sentinel})
        with (runtime / 'host.log').open('w') as log:
            host = subprocess.Popen([str(executable), str(runtime / 'profile.json')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True, env={'PATH': '/usr/bin:/bin'})
            child = None
            try:
                host.stdin.write('auth ' + nonce + '\n')
                host.stdin.flush()
                with selectors.DefaultSelector() as selector:
                    selector.register(host.stdout, selectors.EVENT_READ)
                    deadline = time.monotonic() + 125
                    while time.monotonic() < deadline:
                        if host.poll() is not None:
                            raise RuntimeError('Model host exited before ready')
                        host.stdin.write('ping\n'); host.stdin.flush()
                        if selector.select(5):
                            ready = json.loads(host.stdout.readline())
                            break
                    else:
                        raise RuntimeError('Model readiness deadline')
                if ready['record']['phase'] != 'ready' or ready['record']['instance_id'] != instance:
                    raise RuntimeError('Wrong model instance')
                child = subprocess.Popen([str(ROOT / 'target/debug/examples/run-acceptance'), str(config)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment)
                for _ in range(60):
                    try:
                        output, error = child.communicate(timeout=5)
                        break
                    except subprocess.TimeoutExpired:
                        host.stdin.write('ping\n'); host.stdin.flush()
                else:
                    raise RuntimeError('Desktop Run acceptance deadline')
                if child.returncode:
                    raise RuntimeError('Desktop API acceptance failed: ' + error[:1800])
                report.update(json.loads(output))
                report['phase'] = 'validated'
            except Exception as error:
                report['failure'] = str(error)[:2000]
                raise
            finally:
                if child is not None and child.poll() is None:
                    child.kill(); child.wait()
                host.stdin.close()
                host.wait(timeout=15)
                record = runtime / 'process.json'
                report['model_stopped'] = record.is_file() and json.loads(record.read_text())['phase'] == 'stopped'
                report['passed'] = report['passed'] and report['model_stopped']
                if report['passed']:
                    report['phase'] = 'complete'
                write(report_dir / 'last-report.json', report)
                if not report['model_stopped']:
                    raise RuntimeError('Model cleanup unconfirmed; no resource release claim')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
