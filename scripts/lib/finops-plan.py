#!/usr/bin/env python3
"""Bind the existing configuration-only FinOps collector to a saved plan.

This is a trusted-runner guard, not a signature or a direct-Terraform IAM boundary.
"""
import argparse
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('finops_readiness', HERE / 'finops-readiness.py')
readiness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(readiness)
require = readiness.require
digest = readiness.digest


def read_file(path):
    path = Path(path)
    require(path.is_file() and not path.is_symlink(), 'FinOps artifact missing or symlinked')
    return path.read_bytes()


def timestamp(value):
    stamp = dt.datetime.strptime(value, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=dt.timezone.utc)
    require(stamp.strftime('%Y-%m-%dT%H:%M:%SZ') == value, 'canonical UTC time required')
    return stamp


def access():
    fixture = os.environ.get('FINOPS_FIXTURE_JSON')
    doubles = os.environ.get('COURSE_CHECK_BIN_DIR')
    profile = os.environ.get('FINOPS_BILLING_PROFILE')
    role = os.environ.get('FINOPS_BILLING_ROLE_ARN')
    if fixture or doubles:
        require(fixture and doubles and not profile and not role and os.environ.get('GITHUB_ACTIONS') != 'true',
                'fixtures require local STATIC doubles; prohibited in GitHub lane')
        return 'fixture', ['--observations', fixture], 'STATIC'
    require(bool(profile) != bool(role), 'select one explicit billing profile or monitoring role')
    if os.environ.get('GITHUB_ACTIONS') == 'true':
        require(role and not profile, 'GitHub requires the fixed billing monitoring role')
    return 'collect', ['--role-arn', role] if role else ['--profile', profile], 'CLOUD_RUNTIME'


def validate_result(raw, c, contract_bytes, args, mode):
    result = json.loads(raw)
    require(result['schemaVersion'] == 'platform.finops-readiness/v1' and result['source'] == mode,
            'readiness schema/source mismatch')
    require(result['evidenceGrade'] == ('LOCAL_VERIFIED' if mode == 'fixture' else 'CLOUD_RUNTIME'), 'readiness grade mismatch')
    require(result['gatePolicy'] == 'configuration-only' and result['configurationStatus'] == 'CONFIGURED', 'configuration not ready')
    require(result['deliveryStatus'] == 'NOT_VERIFIED' and result['dataStatus'] in ('DATA_PENDING', 'DATA_OBSERVED'), 'unsupported evidence claim')
    require(result['accountId'] == args.account and result['region'] == args.region and
            result['platformInstanceId'] == os.environ['PLATFORM_INSTANCE_ID'], 'readiness workload mismatch')
    require(result['billingAccountId'] == c['billingAccountId'] and result['billingApiRegion'] == 'us-east-1', 'billing identity mismatch')
    identity = result['monitoringIdentity']
    require(identity['accountId'] == identity['managementAccountId'] == c['billingAccountId'] and
            identity['organizationId'] == c['organizationId'], 'management monitoring identity mismatch')
    require(re.fullmatch(r'arn:aws:(iam|sts)::' + c['billingAccountId'] + r':.+', identity['principalArn']), 'monitor principal mismatch')
    role = os.environ.get('FINOPS_BILLING_ROLE_ARN')
    if role:
        require(re.fullmatch(r'arn:aws:iam::' + c['billingAccountId'] + r':role/[A-Za-z0-9_+=,.@/-]+', role), 'billing role account mismatch')
        prefix = f"arn:aws:sts::{c['billingAccountId']}:assumed-role/{role.rsplit('/', 1)[1]}/"
        require(identity['principalArn'].startswith(prefix) and len(identity['principalArn']) > len(prefix), 'unexpected billing monitoring role')
    now = dt.datetime.now(dt.timezone.utc)
    observed, expires = timestamp(result['observedAt']), timestamp(result['expiresAt'])
    require(observed <= now < expires and (now-observed).total_seconds() <= 900 and
            0 < (expires-observed).total_seconds() <= 900, 'stale or unbounded FinOps evidence')
    require(result['bindings']['contractSha256'] == digest(contract_bytes), 'readiness contract digest mismatch')
    require(result['bindings']['collectorSha256'] == digest(read_file(HERE/'finops-readiness.py')), 'collector source mismatch')
    require(re.fullmatch(r'sha256:[a-f0-9]{64}', result['bindings']['observationsSha256']), 'observation digest missing')
    return result


def collect(contract_path, output, args, mode, credentials):
    command = ['bash', str(HERE.parent/'finops-readiness-check.sh'), mode, '--contract', str(contract_path),
               '--account', args.account, '--region', args.region, '--platform-id', os.environ['PLATFORM_INSTANCE_ID'],
               '--gate-policy', 'configuration-only', *credentials, '--output', str(output)]
    # Collector suppresses SDK exception details; do not print credentials or contact data.
    subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
    return read_file(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('capture', 'verify'))
    for key in ('artifact', 'root', 'operation', 'account', 'region'):
        parser.add_argument('--'+key, required=True)
    args = parser.parse_args()
    try:
        operator_only = args.root in ('environments/prod/00-finops', 'terraform/platform-backup')
        require(not operator_only or os.environ.get('GITHUB_ACTIONS') != 'true', 'dedicated root is operator-only')
        if operator_only or args.operation == 'destroy' or args.root.startswith('environments/dev/'):
            print('null')
            return 0
        require(args.operation == 'apply', 'unsupported operation')
        require(os.environ.get('FINOPS_GATE_POLICY') == 'configuration-only', 'explicit configuration-only policy required')
        expected_sha = os.environ.get('FINOPS_CONTRACT_SHA256', '')
        require(re.fullmatch(r'sha256:[a-f0-9]{64}', expected_sha), 'trusted contract SHA256 required')
        mode, credentials, grade = access()
        artifact = Path(args.artifact)
        contract_path = artifact/'finops-contract.json'
        readiness_path = artifact/'finops-readiness.json'
        contract_bytes = read_file(os.environ['FINOPS_CONTRACT_JSON']) if args.mode == 'capture' else read_file(contract_path)
        require(digest(contract_bytes) == expected_sha, 'trusted contract digest mismatch')
        c = json.loads(contract_bytes)
        readiness.validate_contract(c, args.account, args.region, os.environ['PLATFORM_INSTANCE_ID'])
        if args.mode == 'capture':
            contract_path.write_bytes(contract_bytes)
            result_bytes = collect(contract_path, readiness_path, args, mode, credentials)
        else:
            result_bytes = read_file(readiness_path)
        result = validate_result(result_bytes, c, contract_bytes, args, mode)
        binding = dict(schemaVersion='platform.saved-plan-finops/v1', evidenceGrade=grade,
                       contractSha256=expected_sha, readinessSha256=digest(result_bytes),
                       accountId=args.account, region=args.region, platformInstanceId=os.environ['PLATFORM_INSTANCE_ID'],
                       billingAccountId=c['billingAccountId'], monitoringIdentity=result['monitoringIdentity'],
                       observedAt=result['observedAt'], expiresAt=result['expiresAt'])
        if args.mode == 'verify':
            manifest = json.loads(read_file(artifact/'plan-identity.json'))
            require(manifest['finops'] == binding, 'saved-plan FinOps binding mismatch')
            with tempfile.TemporaryDirectory(prefix='finops-apply-') as directory:
                fresh = collect(contract_path, Path(directory)/'readiness.json', args, mode, credentials)
                validate_result(fresh, c, contract_bytes, args, mode)
                (artifact/'finops-apply-readiness.json').write_bytes(fresh)
        print(json.dumps(binding, separators=(',', ':')))
        return 0
    except Exception as error:
        detail = str(error) if isinstance(error, ValueError) else type(error).__name__
        print('SAVED_PLAN_FINOPS_NOT_READY: '+detail, file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
