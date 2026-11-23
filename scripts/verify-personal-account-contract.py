#!/usr/bin/env python3
"""Verify the read-only contract projection against its immutable producer commit."""
import argparse,hashlib,json,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
LOCK=ROOT/"config/personal-api-contract.lock.json"
PATHS=("/api/v1/automation/account/wallet","/api/v1/automation/account/budgets")
def projection(api):
    definitions=api["components"]["schemas"]
    return {"paths":{p:api["paths"][p] for p in PATHS},"components":{"schemas":{n:definitions[n] for n in
            ("ApiError","WalletView","PersonalBudgetList","BudgetView")},"securitySchemes":{"PersonalAutomationKey":api["components"]["securitySchemes"]["PersonalAutomationKey"]}}}
if __name__=="__main__":
    cli=argparse.ArgumentParser();cli.add_argument("--server-repo",required=True,type=Path);args=cli.parse_args()
    lock=json.loads(LOCK.read_bytes())
    raw=subprocess.check_output(["git","show",lock["producer_commit"]+":"+lock["source"]],cwd=args.server_repo)
    snapshot=ROOT/"contracts/personal-account/read-operations.json"
    if hashlib.sha256(raw).hexdigest()!=lock["producer_sha256"] or hashlib.sha256(snapshot.read_bytes()).hexdigest()!=lock["snapshot_sha256"]:
        raise ValueError("Pinned desktop account contract differs")
    if projection(json.loads(raw))!=json.loads(snapshot.read_bytes()):
        raise ValueError("Account operations differ from original producer")
    print("PASS immutable personal wallet/budget operations and schema",lock["producer_commit"])
