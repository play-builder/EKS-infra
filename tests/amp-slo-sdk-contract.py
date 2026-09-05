#!/usr/bin/env python3
"""Offline SDK shape validation plus real SigV4 signing over controlled HTTP responses.

Run using the optional collector venv. No credential chain, metadata, or network calls.
"""
import argparse, copy, importlib.util, io, json, pathlib, sys, tempfile
sys.dont_write_bytecode = True
from unittest.mock import patch
import boto3
from botocore.stub import Stubber
ROOT=pathlib.Path(__file__).resolve().parents[1]
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
drill=load("drill",ROOT/"scripts/lib/amp-slo-drill.py")
fixtures=load("fixtures",ROOT/"tests/amp-slo-drill-contract.py")
record=fixtures.fixture();record.update(source="captured",evidenceGrade="LIVE_NOT_VERIFIED")
session=boto3.Session(aws_access_key_id="TESTACCESSKEY",aws_secret_access_key="TESTSECRET",region_name=fixtures.REGION)
clients={name:session.client(name) for name in ("sts","amp","eks")}
stubs={name:Stubber(client) for name,client in clients.items()}
workspace=copy.deepcopy(record["observations"]["workspace"]);workspace["workspace"]["createdAt"]=fixtures.NOW
workspace["workspace"]["prometheusEndpoint"]="https://aps-workspaces.ap-northeast-2.amazonaws.com/workspaces/ws-test/"
for name,response,params,method in [
    ("sts",{"Account":fixtures.ACCOUNT,"Arn":f"arn:aws:iam::{fixtures.ACCOUNT}:user/test","UserId":"TESTUSER"},{}, "get_caller_identity"),
    ("amp",workspace,{"workspaceId":"ws-test"},"describe_workspace"),
    ("eks",record["observations"]["cluster"],{"name":"test"},"describe_cluster")]:
    stubs[name].add_response(method,response,params);stubs[name].activate()
real_client=session.client
session.client=lambda name:clients[name]
seen=[]
def http(request,timeout):
    url=request.full_url
    assert url.startswith("https://aps-workspaces.ap-northeast-2.amazonaws.com/workspaces/ws-test/")
    assert request.get_method()=="GET" and timeout==30
    assert "/ap-northeast-2/aps/aws4_request" in request.headers["Authorization"]
    seen.append(url)
    if "/alertmanager/api/v2/alerts" in url:payload=record["observations"]["firing"]
    elif "/api/v1/rules" in url:payload=record["observations"]["rules"]
    elif "/api/v1/query?" in url:payload=record["observations"]["query"]
    else:raise AssertionError("Unsupported collector endpoint")
    response=io.BytesIO(json.dumps(payload).encode());response.status=200;return response
with tempfile.TemporaryDirectory(prefix="amp-sdk-contract-") as directory:
    args=argparse.Namespace(phase="firing",output=str(pathlib.Path(directory)/"capture.json"),short_window="5m",long_window="1h")
    with patch("boto3.Session",return_value=session),patch("urllib.request.urlopen",side_effect=http):
        result=drill.collect(record,args)
    actual=json.loads(pathlib.Path(args.output).read_text())
    assert result["evidenceGrade"]=="LIVE_NOT_VERIFIED"
    assert actual["observations"]["workspace"]["workspace"]["arn"]==fixtures.WORKSPACE
    assert len(seen)==4 and "%5B5m%5D" in seen[1] and "%5B1h%5D" in seen[2]
    assert pathlib.Path(args.output).stat().st_mode & 0o777 == 0o600
for stub in stubs.values():stub.assert_no_pending_responses()
print("PASS: pinned SDK request/response models and SigV4 read-only AMP endpoints; LOCAL_VERIFIED")
