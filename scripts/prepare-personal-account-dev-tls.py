#!/usr/bin/env python3
"""Create a private loopback leaf and a separate public trust anchor for desktop/User Web TLS."""
import argparse,os,shutil,subprocess,tempfile
from pathlib import Path


def prepare(directory):
    installed=Path("/opt/homebrew/opt/openssl@3/bin/openssl")
    openssl=str(installed) if installed.is_file() else shutil.which("openssl")
    if not openssl or not subprocess.check_output([openssl,"version"],text=True).startswith("OpenSSL 3."):
        raise ValueError("OpenSSL 3 is required for loopback IP and server-purpose verification")
    directory=directory.resolve()
    directory.parent.mkdir(parents=True,exist_ok=True)
    def verify(directory):
        subprocess.run([openssl,"verify","-purpose","sslserver","-verify_ip","127.0.0.1","-CAfile",directory/"ca.pem",directory/"cert.pem"],check=True)
        cert=subprocess.check_output([openssl,"x509","-in",directory/"cert.pem","-pubkey","-noout"])
        key=subprocess.check_output([openssl,"pkey","-in",directory/"key.pem","-pubout"])
        if cert!=key:raise ValueError("Certificate and serving key differ")
    if not directory.exists():
        with tempfile.TemporaryDirectory(dir=directory.parent) as scratch:
            root=Path(scratch);out=root/"tls";out.mkdir(mode=0o700)
            def run(*args):subprocess.run([openssl,*args],cwd=root,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
            run("req","-x509","-nodes","-newkey","rsa:2048","-keyout","ca.key","-out",str(out/"ca.pem"),"-days","30",
                "-subj","/CN=Orange local account test CA","-addext","basicConstraints=critical,CA:TRUE","-addext","keyUsage=critical,keyCertSign,cRLSign")
            run("req","-new","-newkey","rsa:2048","-nodes","-keyout",str(out/"key.pem"),"-out","service.csr","-subj","/CN=127.0.0.1")
            (root/"service.ext").write_text("basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=IP:127.0.0.1\n")
            run("x509","-req","-in","service.csr","-CA",str(out/"ca.pem"),"-CAkey","ca.key","-set_serial",str(int.from_bytes(os.urandom(16),"big") or 1),
                "-days","7","-extfile","service.ext","-out",str(out/"cert.pem"))
            for f in out.iterdir():f.chmod(0o600)
            verify(out)
            out.rename(directory)
    verify(directory)
    return directory


if __name__=="__main__":
    p=argparse.ArgumentParser();p.add_argument("--output",type=Path,required=True)
    prepare(p.parse_args().output)
