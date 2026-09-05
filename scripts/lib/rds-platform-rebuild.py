#!/usr/bin/env python3
"""Capture isolated platform rebuild observations without changing cluster resources."""
import argparse
import importlib.util
import json
import pathlib
import re
import subprocess
import tempfile
from urllib.parse import urlparse

spec = importlib.util.spec_from_file_location('rds_recovery', pathlib.Path(__file__).with_name('rds-recovery.py'))
rds = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rds)
db = rds.db
traffic_spec=importlib.util.spec_from_file_location('rds_rebuild_traffic',pathlib.Path(__file__).with_name('rds-rebuild-traffic.py'))
traffic=importlib.util.module_from_spec(traffic_spec);traffic_spec.loader.exec_module(traffic)

APP_DATABASE_OBSERVATION = """
import { config } from './src/config.js';
import { createDatabasePool } from './src/database.js';
let pool, client;
try {
  if (!config.databaseEnabled || !config.database.ssl) throw new Error('database TLS required');
  pool = createDatabasePool(config.database);
  client = await pool.connect();
  await client.query('BEGIN READ ONLY');
  const { rows } = await client.query(`SELECT json_build_object(
    'database', current_database(), 'user', current_user,
    'serverAddress', inet_server_addr(), 'serverAt', clock_timestamp(),
    'tls', (SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()),
    'order', (SELECT json_build_object('id',o.id,'totalCents',o.total_cents,
      'itemCount',(SELECT count(*) FROM public.order_items i WHERE i.order_id=o.id))
      FROM public.orders o ORDER BY o.id DESC LIMIT 1)) AS observation`);
  await client.query('COMMIT');
  process.stdout.write(JSON.stringify({host:config.database.host,port:config.database.port,...rows[0].observation}));
} catch {
  process.stderr.write('PENDING: application database observation unavailable\\n');
  process.exitCode = 2;
} finally {
  client?.release();
  await pool?.end();
}
"""


def capture(expected):
    region = expected['region']
    raw = {'schemaVersion':'platform.rebuild-observations/v1','startedAt':rds.now(),'expected':expected}
    raw['caller'] = db.aws(region,'sts','get-caller-identity')
    for key in ('sourceCluster','targetCluster'):
        raw[key] = db.aws(region,'eks','describe-cluster','--name',expected[key])['cluster']
    raw['roles'] = {v['roleArn']:db.aws(region,'iam','get-role','--role-name',v['roleArn'].split('/')[-1])['Role'] for v in expected['externalSecrets'].values()}
    cluster = raw['targetCluster']
    config = {'apiVersion':'v1','kind':'Config','current-context':'recovery',
              'clusters':[{'name':'recovery','cluster':{'server':cluster['endpoint'],'certificate-authority-data':cluster['certificateAuthority']['data']}}],
              'contexts':[{'name':'recovery','context':{'cluster':'recovery','user':'operator'}}],
              'users':[{'name':'operator','user':{'exec':{'apiVersion':'client.authentication.k8s.io/v1beta1','command':'aws','args':['eks','get-token','--region',region,'--cluster-name',expected['targetCluster']]}}}]}
    with tempfile.TemporaryDirectory(prefix='rebuild-kube-') as directory:
        path = pathlib.Path(directory)/'config'
        rds.write(path,config)
        def kube(*args): return db.run(['kubectl','--kubeconfig',str(path),*args])
        for key, resource, namespace in [('externalSecrets','externalsecrets','argocd'),('stores','secretstores','argocd'),
                                          ('serviceAccounts','serviceaccounts','argocd'),('applications','applications','argocd'),
                                          ('controllers','deployments,statefulsets','argocd'),('appPods','pods','app-recovery')]:
            raw[key] = json.loads(kube('get',resource,'-n',namespace,'-o','json'))
        raw['kubernetesAuthorization'] = kube('auth','can-i','get','applications.argoproj.io','-n','argocd').strip()
        raw['argocdConfig'] = json.loads(kube('get','configmap','argocd-cm','-n','argocd','-o','json'))
        t=expected['traffic']
        for key,resource,namespace in [
            ('httpRoutes','httproutes.gateway.networking.k8s.io','istio-system'),
            ('targetBindings','targetgroupbindings.elbv2.k8s.aws','istio-system'),
            ('ingressServices','services','istio-system'),('ingressPods','pods','istio-system'),
            ('ingressEndpoints','endpointslices.discovery.k8s.io','istio-system'),
            ('appServices','services','app-recovery'),('appEndpoints','endpointslices.discovery.k8s.io','app-recovery'),
            ('appExternalSecrets','externalsecrets','app-recovery')]:
            raw[key]=json.loads(kube('get',resource,'-n',namespace,'-o','json'))
        raw['edgeGateway']=json.loads(kube('get','gateways.gateway.networking.k8s.io',t['gatewayName'],'-n','istio-system','-o','json'))
        raw['istioGateway']=json.loads(kube('get','gateways.networking.istio.io',t['istioGatewayName'],'-n','istio-system','-o','json'))
        raw['virtualServices']=json.loads(kube('get','virtualservices.networking.istio.io','--all-namespaces','-o','json'))
        raw['appDatabaseConnections']={}
        for pod in raw['appPods']['items']:
            meta=pod['metadata']
            if meta.get('labels',{}).get('app.kubernetes.io/name')!='mini-commerce': continue
            db.require(meta['namespace']=='app-recovery')
            observation=json.loads(kube('exec','-n','app-recovery',meta['name'],'-c','mini-commerce','--','node','--input-type=module','-e',APP_DATABASE_OBSERVATION))
            after=json.loads(kube('get','pod',meta['name'],'-n','app-recovery','-o','json'))
            db.require(after['metadata']['uid']==meta['uid'])
            raw['appDatabaseConnections'][meta['uid']]={'podName':meta['name'],'podUid':meta['uid'],'observedAt':rds.now(),'observation':observation}
    raw['argoUser'] = json.loads(db.run(['argocd','--server',expected['argocdHost'],'account','get-user-info','-o','json']))
    raw['argoAuthorization'] = db.run(['argocd','--server',expected['argocdHost'],'account','can-i','get','applications','*/*']).strip()
    raw['waf'] = db.aws(region,'wafv2','get-web-acl-for-resource','--resource-arn',expected['loadBalancerArn'])
    raw['loadBalancer'] = db.aws(region,'elbv2','describe-load-balancers','--load-balancer-arns',expected['loadBalancerArn'])
    raw['targetGroup'] = db.aws(region,'elbv2','describe-target-groups','--target-group-arns',expected['targetGroupArn'])
    raw['targetHealth'] = db.aws(region,'elbv2','describe-target-health','--target-group-arn',expected['targetGroupArn'])
    raw['lbTags']=db.aws(region,'elbv2','describe-tags','--resource-arns',expected['loadBalancerArn'])
    raw['listeners']=db.aws(region,'elbv2','describe-listeners','--load-balancer-arn',expected['loadBalancerArn'])
    listeners=[l for l in raw['listeners']['Listeners'] if l['LoadBalancerArn']==expected['loadBalancerArn'] and l['Port']==443 and l['Protocol']=='HTTPS']
    db.require(len(listeners)==1)
    raw['listenerRulesListenerArn']=listeners[0]['ListenerArn']
    raw['listenerRules']=db.aws(region,'elbv2','describe-rules','--listener-arn',raw['listenerRulesListenerArn'])
    parsed = urlparse(expected['applicationUrl'])
    db.require(parsed.scheme == 'https' and parsed.hostname and not parsed.username and not parsed.password and not parsed.query and not parsed.fragment)
    db.require(re.fullmatch(r'/orders/[1-9][0-9]*',parsed.path) is not None)
    lbs=raw['loadBalancer']['LoadBalancers']
    db.require(len(lbs)==1 and lbs[0]['LoadBalancerArn']==expected['loadBalancerArn'])
    connection=f"{parsed.hostname}:{parsed.port or 443}:{lbs[0]['DNSName']}:443"
    raw['readback'] = json.loads(db.run(['curl','--fail','--silent','--show-error','--max-time','20','--connect-to',connection,expected['applicationUrl']]))
    raw['completedAt'] = rds.now()
    return raw


def evaluate(raw, source_db, target_db, incident_at, *, current=None):
    db.require(raw['schemaVersion'] == 'platform.rebuild-observations/v1')
    db.require('evidenceGrade' not in raw and 'achieved' not in raw)
    e, source, target = raw['expected'], raw['sourceCluster'], raw['targetCluster']
    incident = rds.timestamp(incident_at)
    completed = rds.timestamp(raw['completedAt'])
    current = current or rds.timestamp(rds.now())
    db.require(incident <= rds.timestamp(raw['startedAt']) <= completed <= current)
    db.require(rds.timestamp(target['createdAt']) >= incident)
    db.require(raw['caller']['Account'] == e['accountId'])
    for key, cluster in [('sourceCluster',source),('targetCluster',target)]:
        db.require(cluster['arn'] == f"arn:aws:eks:{e['region']}:{e['accountId']}:cluster/{e[key]}")
        db.require(cluster['name'] == e[key] and cluster['status'] == 'ACTIVE')
    db.require(source['arn'] != target['arn'])
    issuer = target['identity']['oidc']['issuer'].removeprefix('https://')
    db.require(issuer != source['identity']['oidc']['issuer'].removeprefix('https://'))
    db.require(set(e['externalSecrets']) == {'oidc','notifications','repositoryCredentials'})
    secrets = {s['metadata']['name']:s for s in raw['externalSecrets']['items']}
    stores = {s['metadata']['name']:s for s in raw['stores']['items']}
    accounts = {s['metadata']['name']:s for s in raw['serviceAccounts']['items']}
    for expected in e['externalSecrets'].values():
        actual = secrets[expected['name']]
        db.require(actual['metadata']['namespace'] == 'argocd')
        db.require(actual['spec']['target']['name'] == expected['targetName'])
        db.require(actual['spec']['data'] and all(d['remoteRef']['key'] == expected['sourceName'] for d in actual['spec']['data']))
        db.require(any(c['type']=='Ready' and c['status']=='True' for c in actual['status']['conditions']))
        db.require(rds.timestamp(target['createdAt']) <= rds.timestamp(actual['status']['refreshTime']) <= completed)
        db.require(actual['status']['syncedResourceVersion'])
        store = stores[actual['spec']['secretStoreRef']['name']]
        db.require(store['spec']['provider']['aws']['region'] == e['region'])
        sa = store['spec']['provider']['aws']['auth']['jwt']['serviceAccountRef']['name']
        db.require(sa == expected['serviceAccount'])
        db.require(accounts[sa]['metadata']['annotations']['eks.amazonaws.com/role-arn'] == expected['roleArn'])
        role = raw['roles'][expected['roleArn']]
        db.require(role['Arn'] == expected['roleArn'])
        statements = role['AssumeRolePolicyDocument']['Statement']
        db.require(any(s['Effect']=='Allow' and s['Action']=='sts:AssumeRoleWithWebIdentity' and
                       s['Principal']['Federated']==f"arn:aws:iam::{e['accountId']}:oidc-provider/{issuer}" and
                       s['Condition']['StringEquals'].get(issuer+':aud')=='sts.amazonaws.com' and
                       s['Condition']['StringEquals'].get(issuer+':sub')=='system:serviceaccount:argocd:'+sa for s in statements))
    db.require(raw['kubernetesAuthorization'] == 'yes' and raw['argoAuthorization'].lower() == 'yes')
    db.require(raw['argoUser']['loggedIn'] is True and raw['argoUser']['username'] == e['rbacSubject'] and raw['argoUser']['iss'] == e['oidcIssuer'])
    argo_url=urlparse(raw['argocdConfig']['data']['url'])
    db.require(argo_url.scheme=='https' and argo_url.netloc==e['argocdHost'])
    controllers = {d['metadata']['name']:d for d in raw['controllers']['items']}
    for name in ('argocd-server','argocd-repo-server','argocd-application-controller','argocd-applicationset-controller','argocd-redis-ha-server'):
        controller = controllers[name]
        db.require(controller['status']['observedGeneration'] >= controller['metadata']['generation'])
        db.require(controller['status']['readyReplicas'] >= (3 if name=='argocd-redis-ha-server' else 2))
    db.require(re.fullmatch(r'[0-9a-f]{40}',e['gitRevision']) is not None)
    apps = {a['metadata']['name']:a for a in raw['applications']['items']}
    db.require(len(e['applications']) > 0)
    for name in e['applications']:
        app = apps[name]
        db.require(app['status']['health']['status']=='Healthy' and app['status']['sync']['status']=='Synced')
        db.require(app['status']['sync']['revision']==e['gitRevision'])
        db.require(app['spec']['destination']['server'] in (target['endpoint'],'https://kubernetes.default.svc'))
    db.require(re.fullmatch(r'sha256:[a-f0-9]{64}',e['imageDigest']) is not None)
    pods = [p for p in raw['appPods']['items'] if p['metadata']['labels'].get('app.kubernetes.io/name')=='mini-commerce']
    db.require(len(pods)>0)
    for pod in pods:
        injection=json.loads(pod['metadata']['annotations']['sidecar.istio.io/status'])
        db.require(injection['revision']==e['istioRevision'] and 'istio-proxy' in injection['containers'])
        statuses = pod['status']['containerStatuses']
        db.require(any(c['name']=='istio-proxy' and c['ready'] for c in statuses))
        app = next(c for c in statuses if c['name']=='mini-commerce')
        db.require(app['ready'] and app['imageID'].endswith('@'+e['imageDigest']))
    db.require(raw['waf']['WebACL']['ARN']==e['webAclArn'])
    for key,service in [('webAclArn','wafv2'),('loadBalancerArn','elasticloadbalancing'),('targetGroupArn','elasticloadbalancing')]:
        db.require(e[key].startswith(f"arn:aws:{service}:{e['region']}:{e['accountId']}:"))
    lbs = raw['loadBalancer']['LoadBalancers']
    db.require(len(lbs)==1 and lbs[0]['LoadBalancerArn']==e['loadBalancerArn'] and lbs[0]['State']['Code']=='active')
    groups = raw['targetGroup']['TargetGroups']
    db.require(len(groups)==1 and groups[0]['TargetGroupArn']==e['targetGroupArn'] and e['loadBalancerArn'] in groups[0]['LoadBalancerArns'])
    health = raw['targetHealth']['TargetHealthDescriptions']
    db.require(len(health)>0 and all(h['TargetHealth']['State']=='healthy' for h in health))
    result = rds.evaluate(source_db,target_db,incident_at,current=current)
    traffic.validate(raw,target_db,db.require,rds.timestamp)
    db.require(rds.timestamp(target_db['completedAt']) <= completed)
    db.require(e['accountId']==target_db['contract']['accountId'] and e['region']==target_db['contract']['region'])
    order = raw['readback']['order']
    expected_order = target_db['sql']['readbackOrder']
    db.require(order['id']==expected_order['id'] and order['totalCents']==expected_order['totalCents'] and len(order['items'])==expected_order['itemCount'])
    db.require(urlparse(e['applicationUrl']).path == '/orders/'+str(order['id']))
    rto = (completed-incident).total_seconds()/60
    db.require(type(e['rtoMinutes']) is int and 0 < rto <= e['rtoMinutes'])
    db.require((current-completed).total_seconds() <= target_db['contract']['objectives']['drillMaxAgeDays']*86400)
    return {'schemaVersion':'platform.rebuild-dr/v1','status':'OBSERVED','evidenceGrade':'LOCAL_VERIFIED','liveStatus':'LIVE_NOT_VERIFIED',
            'sourceClusterArn':source['arn'],'targetClusterArn':target['arn'],'targetOidc':issuer,
            'gitRevision':e['gitRevision'],'imageDigest':e['imageDigest'],'istioRevision':e['istioRevision'],
            'achieved':{'rtoMinutes':rto,'rpoMinutes':result['achieved']['rpoMinutes']},'completedAt':raw['completedAt']}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--capture',action='store_true')
    parser.add_argument('--validate',action='store_true')
    for name in ('spec','raw','source','target','incident-at','output'): parser.add_argument('--'+name)
    args = parser.parse_args()
    try:
        db.require(args.capture != args.validate)
        if args.capture:
            raw = capture(json.loads(pathlib.Path(args.spec).read_text()))
            rds.write(args.raw,raw)
        else: raw = json.loads(pathlib.Path(args.raw).read_text())
        result = evaluate(raw,json.loads(pathlib.Path(args.source).read_text()),json.loads(pathlib.Path(args.target).read_text()),args.incident_at)
        result['raw'] = {'platformSha256':rds.checksum(args.raw),'sourceDbSha256':rds.checksum(args.source),'targetDbSha256':rds.checksum(args.target)}
        rds.write(args.output,result)
        print(json.dumps(result))
        return 0
    except (db.Denied,KeyError,ValueError,TypeError,OSError,StopIteration,subprocess.SubprocessError):
        print(json.dumps({'schemaVersion':'platform.rebuild-dr/v1','status':'PENDING','evidenceGrade':'LIVE_NOT_VERIFIED','reason':'Incomplete, denied or inconsistent platform/API/SQL observations.'}))
        return 2


if __name__ == '__main__': raise SystemExit(main())
