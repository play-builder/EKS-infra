"""Execute actual Terraform health Lua against ESO v2.10.0 API-shaped objects."""
import copy
import json
import os
import pathlib
import re
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
lua = os.environ.get("LUA_BIN", "lua")
healthy = {"metadata": {"generation": 7}, "status": {
    "refreshTime": "2026-09-05T00:00:00Z", "syncedResourceVersion": "7-1234567890abcdef",
    "conditions": [{"type": "Ready", "status": "True", "reason": "SecretSynced", "message": "secret synced"}]}}


def literal(value):
    if isinstance(value, dict):
        return "{" + ",".join("[" + json.dumps(k) + "]=" + literal(v) for k,v in value.items()) + "}"
    if isinstance(value, list):
        return "{" + ",".join(literal(v) for v in value) + "}"
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    return json.dumps(value)


for env in ("dev", "prod"):
    source = (root / f"environments/{env}/04-workloads/argocd/main.tf").read_text()
    script = re.search(r"external_secret_health_lua = <<-LUA\n(.*?)\n  LUA", source, re.S)[1]
    cases = [(healthy, "Healthy")]
    mutations = [
        lambda x: x["status"].update(syncedResourceVersion="6-hash"),
        lambda x: x["status"].update(syncedResourceVersion="70-hash"),
        lambda x: x["status"].update(syncedResourceVersion="7-"),
        lambda x: x["status"].pop("refreshTime"),
        lambda x: x["metadata"].update(deletionTimestamp="2026-09-05T00:01:00Z"),
        lambda x: x["status"]["conditions"][0].update(reason="SecretDeleted"),
        lambda x: x["status"]["conditions"][0].update(reason="SecretMissing"),
        lambda x: x["status"]["conditions"][0].update(message="secret retained due to DeletionPolicy=Retain"),
    ]
    for mutation in mutations:
        obj=copy.deepcopy(healthy); mutation(obj); cases.append((obj,"Progressing"))
    obj=copy.deepcopy(healthy); obj["status"]["conditions"][0].update(status="False",reason="SecretSyncedError"); cases.append((obj,"Degraded"))
    for index,(obj,expected) in enumerate(cases):
        program="obj="+literal(obj)+"\nlocal result=(function()\n"+script+"\nend)()\nassert(result.status == "+json.dumps(expected)+", result.status)\n"
        result=subprocess.run([lua,"-"],input=program,text=True,capture_output=True)
        assert result.returncode==0, f"{env} case {index}: {result.stderr}"
print("PASS: actual Lua health, 20 ESO v2.10 API-shaped cases; no observedGeneration assumption")
