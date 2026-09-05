#!/usr/bin/env python3
"""Explicit, owner-bound PostgreSQL credential bootstrap; values never leave protected pipes/files."""
import argparse
import json
import os
import pathlib
import re
import secrets
import subprocess
import tempfile


class Denied(Exception):
    pass


def require(condition):
    if not condition:
        raise Denied('contract or runtime identity rejected')


def run(args, *, stdin=None, env=None):
    result = subprocess.run(args, input=stdin, text=True, capture_output=True, env=env, timeout=90)
    if result.returncode:
        raise Denied('external command failed; diagnostic content suppressed')
    return result.stdout


def aws(region, *args):
    return json.loads(run(['aws', '--region', region, '--no-cli-pager', *args, '--output', 'json']))


def contract(path):
    value = json.loads(pathlib.Path(path).read_text())
    require(value.get('schemaVersion') == 'platform.database/v1')
    require(re.fullmatch(r'\d{12}', value['accountId']) is not None)
    require(re.fullmatch(r'[a-z][a-z0-9_]{0,62}', value['databaseName']) is not None)
    require(re.fullmatch(r'[a-z][a-z0-9_]{0,15}', value['masterUsername']) is not None)
    require(value['masterUsername'] not in ('commerce_runtime', 'commerce_migration'))
    prefix = f"arn:aws:secretsmanager:{value['region']}:{value['accountId']}:secret:"
    require(value['masterSecretArn'].startswith(prefix))
    require(value['arn'] == f"arn:aws:rds:{value['region']}:{value['accountId']}:db:{value['identifier']}")
    require(value['port'] == 5432 and re.fullmatch(r'[a-z0-9.-]+', value['endpoint']) is not None)
    creds = value['applicationCredentials']
    require(set(creds) == {'database', 'migration'})
    require(len({value['masterSecretArn'], creds['database']['arn'], creds['migration']['arn']}) == 3)
    require(all(c['arn'].startswith(prefix + c['name'] + '-') for c in creds.values()))
    recovery = value.get('restore')
    require(value['root']['stateKey'] == ('recovery' if recovery else 'prod') + '/03-database/terraform.tfstate')
    if recovery:
        require(recovery['sourceIdentifier'] != value['identifier'])
        require(all(c['name'].startswith('recovery-' + value['identifier'] + '/mini-commerce/') for c in creds.values()))
    return value


def observe(value):
    identity = aws(value['region'], 'sts', 'get-caller-identity')
    require(identity['Account'] == value['accountId'])
    require(identity['Arn'].startswith(f"arn:aws:sts::{value['accountId']}:assumed-role/"))
    records = aws(value['region'], 'rds', 'describe-db-instances', '--db-instance-identifier', value['identifier'])['DBInstances']
    require(len(records) == 1)
    db = records[0]
    require(db['DBInstanceArn'] == value['arn'] and db['DbiResourceId'] == value['resourceId'])
    require(db['Endpoint']['Address'] == value['endpoint'] and db['Endpoint']['Port'] == 5432)
    require(db['DBName'] == value['databaseName'] and db['MasterUsername'] == value['masterUsername'])
    require(db['MasterUserSecret']['SecretArn'] == value['masterSecretArn'])
    require(db['DBInstanceStatus'] == 'available' and not db['PendingModifiedValues'])
    require(db['StorageEncrypted'] and not db['PubliclyAccessible'])
    expected = value['expectedConfiguration']
    require(db['CACertificateIdentifier'] == expected['caCertificateId'])
    require(db['BackupRetentionPeriod'] == expected['backupRetentionDays'])
    require(db['PreferredBackupWindow'] == expected['backupWindow'])
    require(db['PreferredMaintenanceWindow'] == expected['maintenanceWindow'])
    require(db['DBParameterGroups'] == [{'DBParameterGroupName': expected['parameterGroupName'], 'ParameterApplyStatus': 'in-sync'}])
    return identity, db


def pg(value, ca, credential, query, *, readonly=False, quiet=True):
    ca_path = pathlib.Path(ca).resolve(strict=True)
    require(ca_path.is_file())
    with tempfile.TemporaryDirectory(prefix='commerce-db-') as directory:
        path = pathlib.Path(directory) / 'pgpass'
        escape = lambda s: str(s).replace('\\', '\\\\').replace(':', '\\:')
        require(all('\n' not in str(s) and '\r' not in str(s) for s in credential.values()))
        path.touch(mode=0o600)
        path.write_text(':'.join(map(escape, [value['endpoint'], 5432, value['databaseName'], credential['username'], credential['password']])) + '\n')
        env = {k: v for k, v in os.environ.items() if not k.startswith('PG')}
        env.update(PGHOST=value['endpoint'], PGPORT='5432', PGDATABASE=value['databaseName'],
                   PGUSER=credential['username'], PGPASSFILE=str(path), PGSSLMODE='verify-full',
                   PGSSLROOTCERT=str(ca_path), PGCONNECT_TIMEOUT='15',
                   PGOPTIONS='-c statement_timeout=60000 -c lock_timeout=10000' + (' -c default_transaction_read_only=on' if readonly else ''))
        return run(['psql', '-X', '-A', '-t', '-v', 'ON_ERROR_STOP=1'] + (['-q'] if quiet else []), stdin=query, env=env)


def prepare_marker(value, ca, output):
    require(value['restore'] is None and output and not pathlib.Path(output).exists())
    observe(value)
    master = json.loads(aws(value['region'],'secretsmanager','get-secret-value','--secret-id',value['masterSecretArn'])['SecretString'])
    require(master['username']==value['masterUsername'] and len(master['password'])>0)
    pg(value,ca,master,"""BEGIN;
CREATE SCHEMA IF NOT EXISTS platform_recovery;
REVOKE ALL ON SCHEMA platform_recovery FROM PUBLIC, commerce_runtime, commerce_migration;
CREATE TABLE IF NOT EXISTS platform_recovery.markers (seq bigint PRIMARY KEY, token text NOT NULL UNIQUE);
COMMIT;
""")
    token=secrets.token_hex(24)
    transcript=pg(value,ca,master,f"""SELECT json_build_object('phase','before','at',clock_timestamp(),'pid',pg_backend_pid());
BEGIN;
INSERT INTO platform_recovery.markers (seq,token)
SELECT coalesce(max(seq),0)+1,'{token}' FROM platform_recovery.markers
RETURNING json_build_object('phase','marker','seq',seq,'token',token);
COMMIT;
SELECT json_build_object('phase','after','at',clock_timestamp(),'pid',pg_backend_pid());
SELECT json_build_object('database',current_database(),'serverAddress',inet_server_addr(),'pid',pg_backend_pid());
""",quiet=False)
    path=pathlib.Path(output)
    with path.open('x') as stream:
        stream.write(transcript)
    path.chmod(0o600)


def bootstrap(value, ca):
    observe(value)
    master = json.loads(aws(value['region'], 'secretsmanager', 'get-secret-value', '--secret-id', value['masterSecretArn'])['SecretString'])
    require(master['username'] == value['masterUsername'])
    require(isinstance(master['password'], str) and len(master['password']) > 0)
    passwords = {}
    for kind, metadata in value['applicationCredentials'].items():
        shell = aws(value['region'], 'secretsmanager', 'describe-secret', '--secret-id', metadata['arn'])
        require(shell['ARN'] == metadata['arn'] and shell['Name'] == metadata['name'])
        if shell.get('VersionIdsToStages'):
            current = json.loads(aws(value['region'], 'secretsmanager', 'get-secret-value', '--secret-id', metadata['arn'])['SecretString'])
            require(current['DB_HOST'] == value['endpoint'] and current['DB_NAME'] == value['databaseName'])
            require(current['DB_USER'] == ('commerce_runtime' if kind == 'database' else 'commerce_migration'))
            require(isinstance(current['DB_PASSWORD'], str) and len(current['DB_PASSWORD']) >= 24)
            passwords[kind] = current['DB_PASSWORD']
        else:
            passwords[kind] = secrets.token_urlsafe(36)
    pg(value, ca, master, bootstrap_sql(value,passwords))
    with tempfile.TemporaryDirectory(prefix='commerce-secret-') as directory:
        for kind, role in [('database', 'commerce_runtime'), ('migration', 'commerce_migration')]:
            path = pathlib.Path(directory) / kind
            path.touch(mode=0o600)
            path.write_text(json.dumps({'DB_HOST': value['endpoint'], 'DB_PORT': '5432', 'DB_NAME': value['databaseName'], 'DB_USER': role, 'DB_PASSWORD': passwords[kind]}))
            aws(value['region'], 'secretsmanager', 'put-secret-value', '--secret-id', value['applicationCredentials'][kind]['arn'], '--secret-string', 'file://' + str(path))


def bootstrap_sql(value,passwords):
    literal = lambda s: "'" + s.replace("'", "''") + "'"
    query = """BEGIN;
SET LOCAL log_statement = 'none';
SET LOCAL log_min_error_statement = 'panic';
SET LOCAL log_parameter_max_length_on_error = 0;
SET LOCAL password_encryption = 'scram-sha-256';
SET LOCAL standard_conforming_strings = on;
"""
    for kind, role in [('database', 'commerce_runtime'), ('migration', 'commerce_migration')]:
        query += f"""DO $bootstrap$ BEGIN
IF EXISTS (SELECT 1 FROM pg_auth_members WHERE member = (SELECT oid FROM pg_roles WHERE rolname = '{role}')) THEN
RAISE EXCEPTION 'Existing role membership requires explicit remediation'; END IF;
IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '{role}') THEN CREATE ROLE {role}; END IF;
IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '{role}' AND
  (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)) THEN
RAISE EXCEPTION 'Privileged application role requires explicit remediation'; END IF;
END $bootstrap$;
GRANT {role} TO "{value['masterUsername']}" WITH ADMIN TRUE;
GRANT {role} TO "{value['masterUsername']}" WITH INHERIT FALSE;
ALTER ROLE {role} LOGIN NOINHERIT PASSWORD {literal(passwords[kind])};
"""
    query += f"""REVOKE ALL ON DATABASE "{value['databaseName']}" FROM PUBLIC;
GRANT CONNECT ON DATABASE "{value['databaseName']}" TO commerce_runtime, commerce_migration;
GRANT CREATE ON DATABASE "{value['databaseName']}" TO commerce_migration;
GRANT commerce_migration TO "{value['masterUsername']}" WITH SET TRUE;
DO $owner$ BEGIN
IF (SELECT nspowner FROM pg_namespace WHERE nspname='public') <> 'commerce_migration'::regrole THEN
ALTER SCHEMA public OWNER TO commerce_migration;
END IF; END $owner$;
SET LOCAL ROLE commerce_migration;
REVOKE ALL ON SCHEMA public FROM PUBLIC, commerce_runtime;
GRANT USAGE ON SCHEMA public TO commerce_runtime;
GRANT USAGE ON SCHEMA public TO "{value['masterUsername']}";
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM commerce_runtime;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM commerce_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE commerce_migration IN SCHEMA public REVOKE ALL ON TABLES FROM PUBLIC, commerce_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE commerce_migration IN SCHEMA public REVOKE ALL ON SEQUENCES FROM PUBLIC, commerce_runtime;
DO $grants$ DECLARE t text; BEGIN
FOREACH t IN ARRAY ARRAY['products','inventory','orders','order_items'] LOOP
IF to_regclass('public.' || t) IS NOT NULL THEN
EXECUTE format('GRANT %s ON TABLE public.%I TO commerce_runtime',
CASE t WHEN 'products' THEN 'SELECT' WHEN 'inventory' THEN 'SELECT, UPDATE' ELSE 'SELECT, INSERT' END, t);
EXECUTE format('GRANT SELECT ON TABLE public.%I TO %I', t, '{value['masterUsername']}');
END IF; END LOOP;
FOREACH t IN ARRAY ARRAY['orders_id_seq','order_items_id_seq'] LOOP
IF to_regclass('public.' || t) IS NOT NULL THEN
EXECUTE format('GRANT USAGE, SELECT ON SEQUENCE public.%I TO commerce_runtime', t);
END IF; END LOOP; END $grants$;
RESET ROLE;
REVOKE CREATE ON DATABASE "{value['databaseName']}" FROM commerce_migration;
GRANT commerce_migration TO "{value['masterUsername']}" WITH SET FALSE;
GRANT commerce_runtime TO "{value['masterUsername']}" WITH SET FALSE;
COMMIT;
"""
    return query


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--execute', action='store_true')
    parser.add_argument('--contract')
    parser.add_argument('--ca')
    parser.add_argument('--prepare-marker',action='store_true')
    parser.add_argument('--output')
    args = parser.parse_args()
    try:
        require(args.execute and args.contract and args.ca)
        if args.prepare_marker:
            require(args.output)
            prepare_marker(contract(args.contract),args.ca,args.output)
        else:
            bootstrap(contract(args.contract), args.ca)
        print(json.dumps({'schemaVersion': 'platform.db-bootstrap/v1', 'status': 'OBSERVED', 'evidenceGrade': 'LOCAL_VERIFIED', 'liveStatus': 'LIVE_NOT_VERIFIED'}))
        return 0
    except (Denied, KeyError, ValueError, TypeError, OSError, subprocess.SubprocessError):
        print(json.dumps({'schemaVersion': 'platform.db-bootstrap/v1', 'status': 'PENDING', 'reason': 'Invalid metadata, missing explicit execution/CA, or protected runtime operation failed. Secret-bearing diagnostics suppressed.'}))
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
