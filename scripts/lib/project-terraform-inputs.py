#!/usr/bin/env python3
"""Project one approved CI input object privately; never print input values."""
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import stat
import sys

ROOTS = {f'environments/{environment}/{layer}'
         for environment in ('dev', 'prod')
         for layer in ('01-network', '02-eks', '03-platform', '04-workloads/argocd')}
ROOTS |= {'environments/prod/03-database', 'environments/recovery/03-database'}
SECRETS = {'plan': 'TERRAFORM_PLAN_INPUTS_JSON', 'drift': 'TERRAFORM_DRIFT_INPUTS_JSON'}
FILENAME = 'terraform.tfvars.json'


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate key')
        result[key] = value
    return result


def invalid_constant(_):
    raise ValueError('non-JSON constant')


def selected_inputs(action, root):
    region = os.environ['AWS_REGION']
    bucket = os.environ['BACKEND_BUCKET']
    account = os.environ['AWS_ACCOUNT_ID']
    if (region not in ('us-east-1', 'ap-northeast-2') or
            not re.fullmatch(r'[0-9]{12}', account) or
            not re.fullmatch(r'[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]', bucket)):
        raise ValueError('invalid expected identity')
    raw = os.environ[SECRETS[action]]
    if len(raw.encode('utf-8')) > 1024 * 1024:
        raise ValueError('oversized inputs')
    document = json.loads(raw, object_pairs_hook=unique_object, parse_constant=invalid_constant)
    if not isinstance(document, dict) or not set(document).issubset(ROOTS):
        raise ValueError('unknown input root')
    inputs = document[root]
    if not isinstance(inputs, dict) or not inputs or inputs.get('aws_region') != region:
        raise ValueError('missing or foreign root inputs')
    expected = {'state_bucket_name': bucket, 'state_bucket': bucket,
                'state_region': region, 'expected_account_id': account}
    required = ('state_bucket', 'state_region', 'expected_account_id') if root.endswith('03-database') else (
        () if root.endswith('01-network') else ('state_bucket_name',))
    if any(inputs.get(key) != expected[key] for key in required):
        raise ValueError('required identity mismatch')
    if any(key in inputs and inputs[key] != value for key, value in expected.items()):
        raise ValueError('foreign optional identity')
    return inputs


@contextmanager
def root_directory(root):
    # Workspace comes from GitHub, never from the JSON document. Open each root
    # component relative to an anchored directory descriptor, rejecting symlinks.
    workspace = Path(os.environ['GITHUB_WORKSPACE'])
    if not workspace.is_absolute():
        raise ValueError('absolute workspace required')
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    descriptor = os.open(workspace, flags)
    try:
        for component in root.split('/'):
            child = os.open(component, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        yield descriptor
    finally:
        os.close(descriptor)


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in (*SECRETS, 'cleanup'):
        raise ValueError('unsupported action')
    action = sys.argv[1]
    root = os.environ['TF_ROOT']
    if root not in ROOTS:
        raise ValueError('unknown root')
    inputs = None if action == 'cleanup' else selected_inputs(action, root)
    with root_directory(root) as directory:
        if action == 'cleanup':
            try:
                existing = os.stat(FILENAME, dir_fd=directory, follow_symlinks=False)
            except FileNotFoundError:
                return
            if not stat.S_ISREG(existing.st_mode):
                raise ValueError('refuse nonregular cleanup target')
            os.unlink(FILENAME, dir_fd=directory)
        else:
            body = (json.dumps(inputs, allow_nan=False, ensure_ascii=True) + '\n').encode('utf-8')
            descriptor = os.open(FILENAME, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                 0o600, dir_fd=directory)
            try:
                with os.fdopen(descriptor, 'wb') as stream:
                    stream.write(body)
            except BaseException:
                os.unlink(FILENAME, dir_fd=directory)
                raise


if __name__ == '__main__':
    try:
        main()
    except (KeyError, ValueError, OSError, TypeError, RecursionError):
        print('TERRAFORM_INPUTS_REJECTED', file=sys.stderr)
        sys.exit(64)
