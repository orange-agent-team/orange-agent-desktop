#!/usr/bin/env python3
"""Read real account data through an extracted macOS bridge and extracted user API."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

from environment import ROOT


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def unpack(repo, kind, target):
    source = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
    directory = repo / ".local" / (kind + "-distributions")
    records = (json.loads(path.read_bytes()) for path in directory.glob("*.tar.json"))
    record, = [entry for entry in records if entry["source"] == source]
    archive = directory / record["archive"]
    if archive.parent != directory or archive.is_symlink() or digest(archive) != record["sha256"]:
        raise ValueError("Changed local " + kind + " archive")
    builds = record["clean_builds"] if kind == "desktop" else record["identical_archives"]
    if builds != 2:
        raise ValueError("Two clean reproducible builds required")
    with tarfile.open(archive, "r:gz") as stream:
        stream.extractall(target, filter="data")
    print(kind, source, record["sha256"], flush=True)
    return record


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--server-repo", type=Path, required=True)
    parser.add_argument("--environment", type=Path, required=True)
    parser.add_argument("--native-app", action="store_true")
    args = parser.parse_args()
    server = args.server_repo.resolve(strict=True)
    with tempfile.TemporaryDirectory() as workspace:
        tmp = Path(workspace)
        api = unpack(server, "platform", tmp / "api")
        desktop = unpack(ROOT, "desktop", tmp / "desktop")
        app, = (tmp / "desktop").glob("*.app")
        subprocess.run(["codesign", "--verify", "--deep", "--strict", app], check=True)
        binary = tmp / "api/orange-platform/bin/orange-user-api"
        if any(build["orange-user-api"] != digest(binary) for build in api["two_native_builds"]):
            raise ValueError("Extracted user API differs from its two inspected builds")
        bridge = app / "Contents/Frameworks/orange_desktop_bridge.framework/Versions/A/orange_desktop_bridge"
        if not bridge.resolve(strict=True).is_relative_to(app.resolve(strict=True)):
            raise ValueError("Desktop framework outside extracted application")
        installed = json.loads(subprocess.check_output([app / "Contents/MacOS/orange_desktop", "--verify-installation"]))
        if installed != desktop["verification"]["bridge_probe"]:
            raise ValueError("Extracted installation probe differs from build")
        command = [sys.executable, ROOT / "scripts/check-personal-account-live.py",
                   "--server-repo", server, "--server-binary", binary, "--environment", args.environment.resolve()]
        subprocess.run([*command, "--bridge", bridge], check=True)
        if args.native_app:
            subprocess.run([*command, "--native-app"], check=True)
        print("PASS installed account framework and installed user API with real PostgreSQL")


if __name__ == "__main__":
    main()
