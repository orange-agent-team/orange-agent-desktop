#!/usr/bin/env python3
"""Run the real desktop FRB and Flutter panel over authenticated loopback TLS against a packaged API."""
import argparse
import contextlib
import hashlib
import http.client
import json
import os
from pathlib import Path
import platform
import secrets
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from urllib.parse import urlsplit,unquote

from environment import ROOT,APP,tool_environment


def api_request(origin,path,method,headers,body=None):
    u=urlsplit(origin)
    if u.scheme!="http" or u.hostname!="127.0.0.1" or not u.port:raise ValueError("Owned local API required")
    connection=http.client.HTTPConnection(u.hostname,u.port,timeout=8)
    try:
        connection.request(method,path,body,headers)
        reply=connection.getresponse()
        return reply.status,reply.getheader("Content-Type",""),reply.read(65537)
    finally:connection.close()


@contextlib.contextmanager
def proxy(origin,tls):
    counts={"wallet":0,"budgets":0}
    class Handler(BaseHTTPRequestHandler):
        def log_message(self,*args):pass
        def do_GET(self):
            parsed=urlsplit(self.path)
            resource=parsed.path.rsplit("/",1)[-1]
            if parsed.scheme or parsed.netloc or parsed.path!="/api/v1/automation/account/"+resource or resource not in counts:
                self.send_error(404);return
            counts[resource]+=1
            status,media,body=api_request(origin,self.path,"GET",{"Authorization":self.headers.get("Authorization","")})
            self.send_response(status);self.send_header("Content-Type",media);self.send_header("Content-Length",str(len(body)))
            self.end_headers();self.wfile.write(body)
    with ThreadingHTTPServer(("127.0.0.1",43122),Handler) as listener:
        context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(tls/"cert.pem",tls/"key.pem")
        listener.socket=context.wrap_socket(listener.socket,server_side=True)
        thread=threading.Thread(target=listener.serve_forever,daemon=True);thread.start()
        try:yield counts
        finally:listener.shutdown();thread.join(5)


def main():
    cli=argparse.ArgumentParser()
    cli.add_argument("--server-repo",type=Path,required=True,help="Fixed server checkout providing the development DB helpers")
    cli.add_argument("--server-binary",type=Path,required=True,help="Locally built orange-user-api")
    cli.add_argument("--environment",type=Path,required=True)
    cli.add_argument("--bridge",type=Path,help="Framework executable extracted from this desktop commit")
    args=cli.parse_args();private=args.environment.resolve();binary=args.server_binary.resolve(strict=True)
    sys.path.insert(0,str(args.server_repo.resolve()/"scripts"))
    from acceptance_origins import reserve_origins
    from owned_postgres import database
    from platform_package_smoke import listening
    env,tools=tool_environment()
    env.update(CARGO_NET_OFFLINE="true",CARGO_INCREMENTAL="0")
    env.setdefault("CARGO_BUILD_JOBS","2")
    if args.bridge:
        library=args.bridge.resolve(strict=True)
    else:
        subprocess.run([tools["cargo"],"build","--locked","--offline","-p","orange-desktop-bridge"],cwd=ROOT,env=env,check=True)
        meta=json.loads(subprocess.check_output([tools["cargo"],"metadata","--locked","--offline","--no-deps","--format-version","1"],cwd=ROOT,env=env))
        library=Path(meta["target_directory"])/"debug"/("liborange_desktop_bridge.dylib" if platform.system()=="Darwin" else "liborange_desktop_bridge.so")
    reserve_origins(43122)
    with database(private/"database-url","orange_desktop_keys_") as (_,url),tempfile.TemporaryDirectory() as path:
        tmp=Path(path)
        subprocess.run([sys.executable,ROOT/"scripts/prepare-personal-account-dev-tls.py","--output",tmp/"tls"],check=True)
        shutil.copyfile(tmp/"tls/ca.pem",tmp/"ca.pem")
        uid=str(uuid.uuid4());session_id=str(uuid.uuid4());cookie,csrf=secrets.token_hex(32),secrets.token_hex(32)
        hashed=hashlib.sha256(cookie.encode()).hexdigest()
        cfg=private/"identity/user-config.json";site=json.loads(cfg.read_bytes())["user_origin"]
        if site!="https://127.0.0.1:43122":raise ValueError("Wrong development origin")
        server={"PATH":"/usr/bin:/bin","ORANGE_ENV":"development","DATABASE_URL":url,"ORANGE_USER_CONFIG_FILE":str(cfg),"ORANGE_USER_BIND":"127.0.0.1:0"}
        db=urlsplit(url);psql=shutil.which("psql") or "/opt/homebrew/opt/postgresql@17/bin/psql"
        penv=dict(os.environ,PGHOST=db.hostname,PGPORT=str(db.port),PGUSER=unquote(db.username),PGPASSWORD=unquote(db.password),PGDATABASE=db.path[1:])
        with listening(binary,server,"User API") as origin,proxy(origin,tmp/"tls") as counts:
            sql=f"""BEGIN; INSERT INTO owners(owner_id) VALUES('{uid}');
                INSERT INTO users(user_id,issuer,subject,personal_owner_id) VALUES('{uid}','fixture','{uid}','{uid}');
                INSERT INTO wallets(owner_id,gift) VALUES('{uid}',9007199254740993);
                INSERT INTO user_sessions(token_hash,session_id,user_id,csrf_token,auth_time,idle_expires_at,absolute_expires_at)
                VALUES('{hashed}','{session_id}','{uid}','{csrf}',0,floor(extract(epoch FROM clock_timestamp()))::bigint+1200,floor(extract(epoch FROM clock_timestamp()))::bigint+1200);
                INSERT INTO budget_roots(root_budget_id,owner_id,scope_id,limit_amount) VALUES('a','{uid}','desktop-budget-one',9007199254740993),('b','{uid}','desktop-budget-two',100); COMMIT;"""
            subprocess.run([psql,"-X","-w","-q","-v","ON_ERROR_STOP=1"],input=sql.encode(),env=penv,check=True)
            def manage(id,method,body=None):
                return api_request(origin,"/api/v1/account/api-keys/"+id,method,{"Cookie":"__Host-orange-user="+cookie,"Origin":site,
                    "X-CSRF-Token":csrf,"Idempotency-Key":id,"Content-Type":"application/json"},None if body is None else json.dumps(body))[0]
            def issue(scope):
                kid=str(uuid.uuid4());value=f"oa1.{kid}.{secrets.token_hex(32)}"
                if manage(kid,"PUT",dict(label="desktop acceptance",scope=scope,ttl_seconds=1200,
                      verifier=hashlib.sha256(value.encode()).hexdigest(),audience="orange-personal-automation-v1"))!=200:
                    raise RuntimeError("Could not issue the scoped fixture")
                return kid,value
            wallet,wkey=issue("wallet:read");budget,bkey=issue("budgets:read")
            runtime=dict(env,ORANGE_TEST_ACCOUNT_LIBRARY=str(library),ORANGE_TEST_ACCOUNT_WALLET_KEY=wkey,
                         ORANGE_TEST_ACCOUNT_BUDGET_KEY=bkey,ORANGE_TEST_ACCOUNT_DIRECTORY=str(tmp),ORANGE_TEST_ACCOUNT_OWNER=uid)
            with tempfile.TemporaryFile() as output:
                child=subprocess.Popen([tools["flutter"],"--suppress-analytics","test","--no-pub","--reporter","expanded",
                    "acceptance/personal_account_test.dart"],cwd=APP,env=runtime,stdout=output,stderr=subprocess.STDOUT)
                revoked=False
                try:
                    deadline=time.monotonic()+900
                    while child.poll() is None:
                        if not revoked and (tmp/"read-complete").is_file():
                            if manage(wallet,"DELETE")!=204:raise RuntimeError("Original credential withdrawal failed")
                            (tmp/"revoked").touch();revoked=True
                        if time.monotonic()>deadline:raise RuntimeError("Desktop qualification timeout")
                        time.sleep(.05)
                    output.seek(0);log=output.read().decode(errors="replace")
                    print(log.replace(wkey,"[redacted]").replace(bkey,"[redacted]").replace(cookie,"[redacted]").replace(csrf,"[redacted]"),flush=True)
                    if child.returncode or not revoked or "All tests passed!" not in log or counts["budgets"]<3 or counts["wallet"]<3:
                        raise RuntimeError("Incomplete native/Flutter qualification")
                finally:
                    if child.poll() is None:child.terminate();child.wait(timeout=15)
            if manage(budget,"DELETE")!=204:raise RuntimeError("Budget credential cleanup failed")
            print("PASS actual Flutter panel, Rust bridge, validated local TLS, exact wallet and paged budgets, scope denial, live revocation and view clearing")
if __name__=="__main__":
    main()
