#!/usr/bin/env python3
"""Read-only API/SQL capture and reproducible isolated recovery measurements."""
import argparse
import datetime as dt
import hashlib
import importlib.util
import json
import pathlib
import subprocess

spec = importlib.util.spec_from_file_location('rds_bootstrap', pathlib.Path(__file__).with_name('rds-bootstrap.py'))
db = importlib.util.module_from_spec(spec)
spec.loader.exec_module(db)

SQL = """BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SELECT json_build_object(
 'database', current_database(), 'serverAddress', inet_server_addr(), 'serverAt', clock_timestamp(),
 'tls', (SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()),
 'markers', (SELECT json_agg(json_build_object('seq', seq, 'token', token) ORDER BY seq) FROM platform_recovery.markers),
 'orders', (SELECT count(*) FROM public.orders),
 'totalCents', (SELECT coalesce(sum(total_cents),0) FROM public.orders),
 'items', (SELECT count(*) FROM public.order_items),
 'readbackOrder', (SELECT json_build_object('id',o.id,'totalCents',o.total_cents,'itemCount',(SELECT count(*) FROM public.order_items i WHERE i.order_id=o.id)) FROM public.orders o ORDER BY o.id DESC LIMIT 1),
 'inventoryChecksum', (SELECT md5(string_agg(product_id::text || ':' || available_quantity::text, ',' ORDER BY product_id)) FROM public.inventory),
 'invalidTotals', (SELECT count(*) FROM public.orders o LEFT JOIN (SELECT order_id,sum(unit_price_cents::bigint*quantity) AS total FROM public.order_items GROUP BY order_id) i ON i.order_id=o.id WHERE o.total_cents IS DISTINCT FROM i.total),
 'orphanItems', (SELECT count(*) FROM public.order_items i LEFT JOIN public.orders o ON i.order_id=o.id LEFT JOIN public.products p ON i.product_id=p.id WHERE o.id IS NULL OR p.id IS NULL),
 'orphanInventory', (SELECT count(*) FROM public.inventory i LEFT JOIN public.products p ON p.id=i.product_id WHERE p.id IS NULL),
 'duplicateIdempotency', (SELECT count(*) FROM (SELECT idempotency_key FROM public.orders GROUP BY idempotency_key HAVING count(*)>1 OR idempotency_key IS NULL) d),
 'negativeStock', (SELECT count(*) FROM public.inventory WHERE available_quantity<0));
COMMIT;
"""


def timestamp(value):
    db.require(isinstance(value, str))
    result = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
    db.require(result.tzinfo is not None)
    return result.astimezone(dt.timezone.utc)


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def checksum(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def write(path, value):
    path = pathlib.Path(path)
    with path.open('x', encoding='utf8') as stream:
        stream.write(json.dumps(value, indent=2) + '\n')
    path.chmod(0o600)


def integrity(observation):
    db.require(observation['tls'] is True)
    db.require(all(type(observation[k]) is int and observation[k] == 0 for k in ['invalidTotals','orphanItems','orphanInventory','duplicateIdempotency','negativeStock']))
    db.require(type(observation['orders']) is int and observation['orders'] > 0)
    db.require(type(observation['items']) is int and observation['items'] >= observation['orders'])
    db.require(type(observation['totalCents']) is int and observation['totalCents'] >= 0)
    db.require(isinstance(observation['inventoryChecksum'], str) and len(observation['inventoryChecksum']) == 32)
    markers = observation['markers']
    db.require(isinstance(markers, list) and len(markers) > 0)
    for index, marker in enumerate(markers, 1):
        db.require(type(marker['seq']) is int and marker['seq'] == index)
        db.require(isinstance(marker['token'], str) and len(marker['token']) >= 32)
    db.require(len({m['token'] for m in markers}) == len(markers))
    return markers[-1]


def commit_interval(raw):
    lines = raw.strip().splitlines()
    db.require(len(lines) == 7 and lines[1] == 'BEGIN' and lines[3:5] == ['INSERT 0 1', 'COMMIT'])
    before, marker, after = json.loads(lines[0]), json.loads(lines[2]), json.loads(lines[5])
    # A trailing server identity observation binds both timestamp reads to the same database.
    identity = json.loads(lines[6])
    db.require(before['phase'] == 'before' and marker['phase'] == 'marker' and after['phase'] == 'after')
    db.require(before['pid'] == after['pid'] == identity['pid'])
    db.require(timestamp(before['at']) <= timestamp(after['at']))
    return before, marker, after, identity


def capture(contract, ca):
    started = now()
    identity, instance = db.observe(contract)
    secret = json.loads(db.aws(contract['region'], 'secretsmanager', 'get-secret-value', '--secret-id', contract['masterSecretArn'])['SecretString'])
    db.require(secret['username'] == contract['masterUsername'])
    sql = json.loads(db.pg(contract, ca, secret, SQL, readonly=True))
    completed = now()
    integrity(sql)
    db.require(sql['database'] == contract['databaseName'])
    db.require(timestamp(started) <= timestamp(sql['serverAt']) <= timestamp(completed))
    return {'schemaVersion':'platform.rds-observation/v1', 'startedAt':started, 'completedAt':completed,
            'contract':contract, 'caller':identity, 'instance':instance, 'sql':sql,
            'querySha256':hashlib.sha256(SQL.encode()).hexdigest()}


def validate_observation(value):
    db.require(value['schemaVersion'] == 'platform.rds-observation/v1')
    db.require('evidenceGrade' not in value and 'achievedMinutes' not in value and 'achieved' not in value)
    db.require(value['querySha256'] == hashlib.sha256(SQL.encode()).hexdigest())
    c = value['contract']
    api = value['instance']
    db.require(value['caller']['Account'] == c['accountId'])
    db.require(api['DBInstanceArn'] == c['arn'] and api['DbiResourceId'] == c['resourceId'])
    db.require(api['DBInstanceIdentifier'] == c['identifier'] and api['Endpoint']['Address'] == c['endpoint'])
    db.require(api['DBInstanceStatus'] == 'available' and api['PendingModifiedValues'] == {})
    db.require(api['StorageEncrypted'] is True and api['PubliclyAccessible'] is False)
    expected = c['expectedConfiguration']
    db.require(api['CACertificateIdentifier'] == expected['caCertificateId'])
    db.require(api['BackupRetentionPeriod'] == expected['backupRetentionDays'])
    db.require(api['PreferredBackupWindow'] == expected['backupWindow'])
    db.require(api['PreferredMaintenanceWindow'] == expected['maintenanceWindow'])
    db.require(api['DBParameterGroups'] == [{'DBParameterGroupName':expected['parameterGroupName'],'ParameterApplyStatus':'in-sync'}])
    db.require(value['sql']['database'] == c['databaseName'])
    db.require(timestamp(value['startedAt']) <= timestamp(value['sql']['serverAt']) <= timestamp(value['completedAt']))
    return integrity(value['sql'])


def evaluate(source, target, incident_at, *, current=None):
    source_marker = validate_observation(source)
    target_marker = validate_observation(target)
    before, marker, after, marker_identity = commit_interval(source['markerTranscript'])
    s, t = source['contract'], target['contract']
    db.require(s['identifier'] != t['identifier'] and s['arn'] != t['arn'] and s['resourceId'] != t['resourceId'])
    db.require(s['accountId'] == t['accountId'] and s['region'] == t['region'])
    db.require(marker_identity['database'] == s['databaseName'])
    db.require(marker_identity['serverAddress'] == source['sql']['serverAddress'])
    db.require(marker['seq'] == source_marker['seq'] and marker['token'] == source_marker['token'])
    db.require(s['root']['stateKey'] == 'prod/03-database/terraform.tfstate')
    db.require(t['root']['stateKey'] == 'recovery/03-database/terraform.tfstate')
    restore = t['restore']
    db.require(restore['sourceIdentifier'] == s['identifier'] and restore['sourceArn'] == s['arn'])
    cutoff = timestamp(restore['requestedTime'])
    incident = timestamp(incident_at)
    completed = timestamp(target['completedAt'])
    event = target['restoreEvent']
    db.require(event['eventName']=='RestoreDBInstanceToPointInTime' and event['eventSource']=='rds.amazonaws.com')
    db.require(event['awsRegion']==s['region'] and event['recipientAccountId']==s['accountId'])
    db.require(isinstance(event['requestID'],str) and len(event['requestID'])>0 and isinstance(event['eventID'],str) and len(event['eventID'])>0)
    db.require('Terraform/' in event['userAgent'] and event.get('responseElements') and not event.get('errorCode'))
    parameters = event['requestParameters']
    db.require(parameters['sourceDBInstanceIdentifier']==s['identifier'])
    db.require('dBInstanceIdentifier' not in parameters)
    db.require(parameters['targetDBInstanceIdentifier']==t['identifier'])
    db.require(timestamp(parameters['restoreTime'])==cutoff)
    db.require(incident <= timestamp(event['eventTime']) <= timestamp(target['startedAt']))
    current = current or dt.datetime.now(dt.timezone.utc)
    db.require(timestamp(source['completedAt']) <= cutoff <= incident <= timestamp(target['startedAt']) <= completed <= current)
    source_instance=target['sourceRestorable']
    db.require(source_instance['DBInstanceArn']==s['arn'] and source_instance['DbiResourceId']==s['resourceId'])
    backups=target['sourceAutomatedBackups']['DBInstanceAutomatedBackups']
    db.require(len(backups)==1)
    backup=backups[0]
    db.require(backup['DBInstanceArn']==s['arn'] and backup['DbiResourceId']==s['resourceId'])
    db.require(backup['DBInstanceIdentifier']==s['identifier'] and backup['Region']==s['region'])
    db.require(backup['Status']=='active' and backup['Encrypted'] is True)
    window=backup['RestoreWindow']
    db.require(timestamp(window['EarliestTime']) <= cutoff <= timestamp(window['LatestTime']))
    db.require(cutoff <= timestamp(source_instance['LatestRestorableTime']))
    objectives = t['objectives']
    db.require(all(type(objectives[k]) is int and objectives[k] > 0 for k in ('rpoMinutes','rtoMinutes','drillMaxAgeDays')))
    db.require((current-completed).total_seconds() <= objectives['drillMaxAgeDays']*86400)
    for key in ['markers','orders','totalCents','items','inventoryChecksum','readbackOrder']:
        db.require(source['sql'][key] == target['sql'][key])
    db.require(source_marker == target_marker and timestamp(after['at']) <= timestamp(source['startedAt']))
    rpo = (incident-timestamp(before['at'])).total_seconds()/60
    rto = (completed-incident).total_seconds()/60
    db.require(0 <= rpo <= objectives['rpoMinutes'] and 0 <= rto <= objectives['rtoMinutes'])
    return {'schemaVersion':'platform.rds-recovery/v2','status':'OBSERVED','evidenceGrade':'LOCAL_VERIFIED',
            'liveStatus':'LIVE_NOT_VERIFIED','objectives':objectives,'incidentAt':incident_at,'completedAt':target['completedAt'],
            'achieved':{'rpoMinutes':rpo,'rtoMinutes':rto},'sourceArn':s['arn'],'targetArn':t['arn'],
            'rpoMethod':'conservative-commit-interval', 'commitInterval':{'notBefore':before['at'],'notAfter':after['at']},
            'restoreCutoff':restore['requestedTime'],'restoredMarker':target['sql']['markers'][-1]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--snapshot', action='store_true')
    parser.add_argument('--capture', action='store_true')
    parser.add_argument('--validate', action='store_true')
    parser.add_argument('--contract')
    parser.add_argument('--ca')
    parser.add_argument('--source')
    parser.add_argument('--marker-proof')
    parser.add_argument('--target')
    parser.add_argument('--incident-at')
    parser.add_argument('--output')
    args = parser.parse_args()
    try:
        db.require(sum([args.snapshot,args.capture,args.validate]) == 1)
        if args.snapshot:
            value = capture(db.contract(args.contract), args.ca)
            db.require(value['contract']['restore'] is None)
            value['markerTranscript'] = pathlib.Path(args.marker_proof).read_text()
            commit_interval(value['markerTranscript'])
            write(args.output, value)
            print(json.dumps({'status':'OBSERVED','evidenceGrade':'LOCAL_VERIFIED','sha256':checksum(args.output)}))
        else:
            source = json.loads(pathlib.Path(args.source).read_text())
            if args.capture:
                target = capture(db.contract(args.contract), args.ca)
                source_records = db.aws(target['contract']['region'], 'rds', 'describe-db-instances', '--db-instance-identifier', source['contract']['identifier'])['DBInstances']
                db.require(len(source_records) == 1)
                target['sourceRestorable'] = source_records[0]
                target['sourceAutomatedBackups'] = db.aws(target['contract']['region'],'rds','describe-db-instance-automated-backups',
                    '--dbi-resource-id',source['contract']['resourceId'])
                events = db.aws(target['contract']['region'],'cloudtrail','lookup-events','--lookup-attributes',
                                'AttributeKey=ResourceName,AttributeValue='+target['contract']['identifier'],
                                '--start-time',args.incident_at)
                candidates = [json.loads(e['CloudTrailEvent']) for e in events['Events'] if e['EventName']=='RestoreDBInstanceToPointInTime']
                db.require(len(candidates)==1)
                target['restoreEvent'] = candidates[0]
                target['completedAt'] = now()
                write(args.target, target)
            else:
                target = json.loads(pathlib.Path(args.target).read_text())
            result = evaluate(source,target,args.incident_at)
            result['raw'] = {'sourceSha256':checksum(args.source),'targetSha256':checksum(args.target)}
            write(args.output,result)
            print(json.dumps(result))
        return 0
    except (db.Denied, KeyError, ValueError, TypeError, OSError, subprocess.SubprocessError):
        print(json.dumps({'schemaVersion':'platform.rds-recovery/v2','status':'PENDING','evidenceGrade':'LIVE_NOT_VERIFIED',
                          'reason':'Missing, denied, stale, inconsistent or incomplete API/SQL recovery evidence.'}))
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
