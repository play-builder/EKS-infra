import copy
import hashlib
import importlib.util
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts/lib' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def contract(recovery=False):
    name = 'commerce-target' if recovery else 'commerce-source'
    prefix = 'recovery-commerce-target' if recovery else 'prod'
    secret = 'arn:aws:secretsmanager:us-east-1:123456789012:secret:'
    return {'schemaVersion':'platform.database/v1','accountId':'123456789012','region':'us-east-1',
            'identifier':name,'arn':'arn:aws:rds:us-east-1:123456789012:db:'+name,'resourceId':'db-'+name,
            'endpoint':name+'.example.invalid','port':5432,'databaseName':'commerce','masterUsername':'platform_admin',
            'masterSecretArn':secret+name+'-master-abcdef',
            'expectedConfiguration':{'caCertificateId':'rds-ca-rsa2048-g1','backupRetentionDays':35,'backupWindow':'01:00-01:30','maintenanceWindow':'sun:04:00-sun:05:00','parameterGroupName':name+'-params'},
            'applicationCredentials':{k:{'name':prefix+'/mini-commerce/'+k,'arn':secret+prefix+'/mini-commerce/'+k+'-abcdef'} for k in ('database','migration')},
            'root':{'stateKey':('recovery' if recovery else 'prod')+'/03-database/terraform.tfstate'},
            'objectives':{'rpoMinutes':60,'rtoMinutes':120,'drillMaxAgeDays':30},
            'restore':{'sourceIdentifier':'commerce-source','sourceArn':'arn:aws:rds:us-east-1:123456789012:db:commerce-source','requestedTime':'2026-09-05T00:10:00Z'} if recovery else None}


def instance(c):
    return {'DBInstanceIdentifier':c['identifier'],'DBInstanceArn':c['arn'],'DbiResourceId':c['resourceId'],
            'Endpoint':{'Address':c['endpoint'],'Port':5432},'DBName':'commerce','MasterUsername':'platform_admin',
            'MasterUserSecret':{'SecretArn':c['masterSecretArn']},'DBInstanceStatus':'available','PendingModifiedValues':{},
            'StorageEncrypted':True,'PubliclyAccessible':False,'CACertificateIdentifier':'rds-ca-rsa2048-g1',
            'BackupRetentionPeriod':35,'PreferredBackupWindow':'01:00-01:30','PreferredMaintenanceWindow':'sun:04:00-sun:05:00',
            'DBParameterGroups':[{'DBParameterGroupName':c['identifier']+'-params','ParameterApplyStatus':'in-sync'}],
            'LatestRestorableTime':'2026-09-05T00:10:00Z'}


def pair(module):
    import json
    sql = {'database':'commerce','serverAddress':'10.0.1.4','serverAt':'2026-09-05T00:05:30Z','tls':True,
           'markers':[{'seq':1,'token':'a'*32}], 'orders':2,'items':3,'totalCents':500,'readbackOrder':{'id':2,'totalCents':300,'itemCount':2},
           'inventoryChecksum':'d'*32,'invalidTotals':0,'orphanItems':0,'orphanInventory':0,'duplicateIdempotency':0,'negativeStock':0}
    c = contract()
    source = {'schemaVersion':'platform.rds-observation/v1','contract':c,'caller':{'Account':c['accountId']},'instance':instance(c),
              'sql':sql,'startedAt':'2026-09-05T00:05:00Z','completedAt':'2026-09-05T00:06:00Z',
              'querySha256':hashlib.sha256(module.SQL.encode()).hexdigest(),
              'markerTranscript':'\n'.join([json.dumps({'phase':'before','at':'2026-09-05T00:00:00Z','pid':42}), 'BEGIN',
                                            json.dumps({'phase':'marker','seq':1,'token':'a'*32}), 'INSERT 0 1','COMMIT',
                                            json.dumps({'phase':'after','at':'2026-09-05T00:01:00Z','pid':42}),
                                            json.dumps({'database':'commerce','serverAddress':'10.0.1.4','pid':42})])}
    target = copy.deepcopy(source)
    target['contract'] = contract(True)
    target['instance'] = instance(target['contract'])
    target['startedAt'] = '2026-09-05T00:20:00Z'
    target['completedAt'] = '2026-09-05T00:30:00Z'
    target['sql']['serverAt'] = '2026-09-05T00:25:00Z'
    target['sourceRestorable'] = instance(c)
    target['sourceAutomatedBackups']={'DBInstanceAutomatedBackups':[{'DBInstanceArn':c['arn'],'DbiResourceId':c['resourceId'],
        'DBInstanceIdentifier':c['identifier'],'Region':c['region'],'Status':'active','Encrypted':True,
        'RestoreWindow':{'EarliestTime':'2026-09-01T00:00:00Z','LatestTime':'2026-09-05T00:10:00Z'}}]}
    target['restoreEvent'] = {'eventName':'RestoreDBInstanceToPointInTime','eventSource':'rds.amazonaws.com','eventTime':'2026-09-05T00:16:00Z',
                              'awsRegion':'us-east-1','recipientAccountId':'123456789012','requestID':'request-123','eventID':'event-123',
                              'userAgent':'HashiCorp Terraform/1.16 terraform-provider-aws/5.87',
                              'requestParameters':{'sourceDBInstanceIdentifier':'commerce-source','targetDBInstanceIdentifier':'commerce-target','restoreTime':'2026-09-05T00:10:00Z'},
                              'responseElements':{'dBInstanceIdentifier':'commerce-target'}}
    return source,target
