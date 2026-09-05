import importlib.util
import pathlib
import subprocess
import unittest
import datetime as dt
import json
from unittest.mock import patch

support_spec = importlib.util.spec_from_file_location('rds_support', pathlib.Path(__file__).with_name('rds-test-support.py'))
support = importlib.util.module_from_spec(support_spec)
support_spec.loader.exec_module(support)
rebuild = support.load('rds-platform-rebuild')


def observations():
    issuer='oidc.eks.us-east-1.amazonaws.com/id/NEW'
    e={'accountId':'123456789012','region':'us-east-1','sourceCluster':'old','targetCluster':'new',
       'rbacSubject':'operator@example.com','oidcIssuer':'https://id.example.com','argocdHost':'argo.example.com',
       'externalSecrets':{},'gitRevision':'a'*40,'applications':['commerce'],'imageDigest':'sha256:'+'b'*64,
       'istioRevision':'1-30-4','loadBalancerArn':'arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/rebuilt/123',
       'targetGroupArn':'arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/rebuilt/123',
       'webAclArn':'arn:aws:wafv2:us-east-1:123456789012:regional/webacl/rebuilt/123','applicationUrl':'https://shop.example.com/orders/2','rtoMinutes':120}
    raw={'schemaVersion':'platform.rebuild-observations/v1','startedAt':'2026-09-05T00:30:00Z','completedAt':'2026-09-05T00:50:00Z','expected':e,
         'caller':{'Account':'123456789012'},'externalSecrets':{'items':[]},'roles':{},'stores':{'items':[]},'serviceAccounts':{'items':[]}}
    for key,name in [('sourceCluster','old'),('targetCluster','new')]:
        raw[key]={'name':name,'arn':'arn:aws:eks:us-east-1:123456789012:cluster/'+name,'status':'ACTIVE','createdAt':'2026-09-05T00:16:00Z',
                  'endpoint':'https://'+name+'.example.invalid','identity':{'oidc':{'issuer':'https://'+(issuer if name=='new' else issuer.replace('NEW','OLD'))}}}
    for kind in ('oidc','notifications','repositoryCredentials'):
        role='arn:aws:iam::123456789012:role/reader-'+kind
        e['externalSecrets'][kind]={'name':kind,'targetName':'target-'+kind,'sourceName':'source-'+kind,'roleArn':role,'serviceAccount':'reader-'+kind}
        raw['externalSecrets']['items'].append({'metadata':{'name':kind,'namespace':'argocd'},'spec':{'target':{'name':'target-'+kind},'data':[{'remoteRef':{'key':'source-'+kind}}],'secretStoreRef':{'name':'store-'+kind}},'status':{'conditions':[{'type':'Ready','status':'True'}],'refreshTime':'2026-09-05T00:20:00Z','syncedResourceVersion':'1'}})
        raw['stores']['items'].append({'metadata':{'name':'store-'+kind},'spec':{'provider':{'aws':{'region':'us-east-1','auth':{'jwt':{'serviceAccountRef':{'name':'reader-'+kind}}}}}}})
        raw['serviceAccounts']['items'].append({'metadata':{'name':'reader-'+kind,'annotations':{'eks.amazonaws.com/role-arn':role}}})
        raw['roles'][role]={'Arn':role,'AssumeRolePolicyDocument':{'Statement':[{'Effect':'Allow','Action':'sts:AssumeRoleWithWebIdentity','Principal':{'Federated':'arn:aws:iam::123456789012:oidc-provider/'+issuer},'Condition':{'StringEquals':{issuer+':aud':'sts.amazonaws.com',issuer+':sub':'system:serviceaccount:argocd:reader-'+kind}}}]}}
    raw.update(kubernetesAuthorization='yes',argoAuthorization='yes',argoUser={'username':'operator@example.com','iss':'https://id.example.com'},
               controllers={'items':[{'metadata':{'name':n,'generation':1},'status':{'observedGeneration':1,'readyReplicas':2}} for n in ['argocd-server','argocd-repo-server','argocd-application-controller']]},
               applications={'items':[{'metadata':{'name':'commerce'},'spec':{'destination':{'server':'https://kubernetes.default.svc'}},'status':{'health':{'status':'Healthy'},'sync':{'status':'Synced','revision':'a'*40}}}]},
               appPods={'items':[{'metadata':{'labels':{'app.kubernetes.io/name':'mini-commerce','istio.io/rev':'1-30-4'}},'status':{'containerStatuses':[{'name':'istio-proxy','ready':True},{'name':'mini-commerce','ready':True,'imageID':'ecr.example/commerce@sha256:'+'b'*64}]}}]},
               waf={'WebACL':{'ARN':e['webAclArn']}},loadBalancer={'LoadBalancers':[{'LoadBalancerArn':e['loadBalancerArn'],'State':{'Code':'active'}}]},
               targetGroup={'TargetGroups':[{'TargetGroupArn':e['targetGroupArn'],'LoadBalancerArns':[e['loadBalancerArn']]}]},targetHealth={'TargetHealthDescriptions':[{'TargetHealth':{'State':'healthy'}}]},
               readback={'order':{'id':2,'totalCents':300,'items':[{},{}]}})
    raw['appPods']['items'][0]['metadata']['annotations']={'sidecar.istio.io/status':json.dumps({'revision':'1-30-4','containers':['istio-proxy']})}
    raw['controllers']['items'].extend([{'metadata':{'name':'argocd-applicationset-controller','generation':1},'status':{'observedGeneration':1,'readyReplicas':2}},
                                       {'metadata':{'name':'argocd-redis-ha-server','generation':1},'status':{'observedGeneration':1,'readyReplicas':3}}])
    raw['argocdConfig']={'data':{'url':'https://argo.example.com'}}
    raw['argoUser']['loggedIn']=True
    raw['loadBalancer']['LoadBalancers'][0]['DNSName']='recovery-alb.elb.amazonaws.com'
    traffic_fixture(raw)
    return raw


def traffic_fixture(raw):
    e=raw['expected']; host='shop.example.com'; db=support.contract(True)
    e['traffic']={'gatewayName':'commerce-edge','httpRouteName':'commerce-edge','ingressServiceName':'istio-ingress-stable',
                  'istioGatewayName':'mini-commerce-internal','virtualServiceName':'mini-commerce','appServiceName':'mini-commerce-stable'}
    raw['lbTags']={'TagDescriptions':[{'ResourceArn':e['loadBalancerArn'],'Tags':[{'Key':'elbv2.k8s.aws/cluster','Value':'new'}]}]}
    raw['edgeGateway']={'metadata':{'name':'commerce-edge','namespace':'istio-system','generation':1},'spec':{'listeners':[{'name':'https','port':443,'protocol':'HTTPS','hostname':host}]},
                        'status':{'addresses':[{'type':'Hostname','value':'recovery-alb.elb.amazonaws.com'}],'conditions':[{'type':'Accepted','status':'True','observedGeneration':1},{'type':'Programmed','status':'True','observedGeneration':1}]}}
    raw['httpRoutes']={'items':[{'metadata':{'name':'commerce-edge','namespace':'istio-system'},'spec':{'hostnames':[host],'parentRefs':[{'name':'commerce-edge','sectionName':'https'}],
       'rules':[{'matches':[{'path':{'type':'PathPrefix','value':'/'}}],'backendRefs':[{'name':'istio-ingress-stable','port':80,'weight':1}]}]}}]}
    raw['targetBindings']={'items':[{'metadata':{'name':'binding','namespace':'istio-system'},'spec':{'targetGroupARN':e['targetGroupArn'],'targetType':'ip','serviceRef':{'name':'istio-ingress-stable','port':80}}}]}
    gateway_pod={'metadata':{'name':'ingress-1','namespace':'istio-system','uid':'gateway-uid','labels':{'istio':'ingressgateway-stable'}},
                 'spec':{'containers':[{'name':'istio-proxy','ports':[{'name':'http2','containerPort':8080}]}]},
                 'status':{'podIP':'10.0.50.2','phase':'Running','conditions':[{'type':'Ready','status':'True'}]}}
    raw['ingressPods']={'items':[gateway_pod]}
    raw['ingressServices']={'items':[{'metadata':{'name':'istio-ingress-stable','namespace':'istio-system','uid':'gateway-service'},
        'spec':{'selector':{'istio':'ingressgateway-stable'},'ports':[{'name':'http2','port':80,'targetPort':'http2'}]}}]}
    pod=raw['appPods']['items'][0]
    pod['metadata'].update(name='commerce-1',namespace='app-recovery',uid='app-uid')
    pod['spec']={'containers':[{'name':'mini-commerce','ports':[{'name':'public','containerPort':3000}],
        'env':[{'name':k,'valueFrom':{'secretKeyRef':{'name':'mini-commerce-database','key':k}}} for k in ['DB_HOST','DB_PORT','DB_NAME','DB_USER','DB_PASSWORD']]}]}
    pod['status'].update(podIP='10.0.50.10',phase='Running',conditions=[{'type':'Ready','status':'True'}])
    raw['appServices']={'items':[{'metadata':{'name':'mini-commerce-stable','namespace':'app-recovery','uid':'app-service'},
        'spec':{'selector':{'app.kubernetes.io/name':'mini-commerce'},'ports':[{'name':'http','port':80,'targetPort':'public'}]}}]}
    def slices(namespace,service,uid,podname,poduid,ip,portname,port):
        return {'items':[{'metadata':{'namespace':namespace,'labels':{'kubernetes.io/service-name':service},'ownerReferences':[{'kind':'Service','name':service,'uid':uid}]},
            'ports':[{'name':portname,'port':port,'protocol':'TCP'}],'endpoints':[{'addresses':[ip],'conditions':{'ready':True,'terminating':False},
            'targetRef':{'kind':'Pod','namespace':namespace,'name':podname,'uid':poduid}}]}]}
    raw['ingressEndpoints']=slices('istio-system','istio-ingress-stable','gateway-service','ingress-1','gateway-uid','10.0.50.2','http2',8080)
    raw['appEndpoints']=slices('app-recovery','mini-commerce-stable','app-service','commerce-1','app-uid','10.0.50.10','http',3000)
    raw['istioGateway']={'metadata':{'name':'mini-commerce-internal','namespace':'istio-system'},'spec':{'selector':{'istio':'ingressgateway-stable'},
        'servers':[{'port':{'number':80,'protocol':'HTTP'},'hosts':[host]}]}}
    raw['virtualServices']={'items':[{'metadata':{'name':'mini-commerce','namespace':'app-recovery'},'spec':{'hosts':[host],
        'gateways':['istio-system/mini-commerce-internal'],'http':[{'name':'primary','match':[{'uri':{'prefix':'/'}}],
        'route':[{'destination':{'host':'mini-commerce-stable','port':{'number':80}},'weight':100}]}]}}]}
    raw['appExternalSecrets']={'items':[{'metadata':{'name':'mini-commerce-database','namespace':'app-recovery'},'spec':{'target':{'name':'mini-commerce-database'},
        'data':[{'secretKey':k,'remoteRef':{'key':db['applicationCredentials']['database']['name'],'property':k}} for k in ['DB_HOST','DB_PORT','DB_NAME','DB_USER','DB_PASSWORD']]},
        'status':{'conditions':[{'type':'Ready','status':'True'}],'refreshTime':'2026-09-05T00:32:00Z'}}]}
    raw['appDatabaseConnections']={'app-uid':{'podName':'commerce-1','podUid':'app-uid','observedAt':'2026-09-05T00:35:00Z',
        'observation':{'host':db['endpoint'],'port':5432,'database':'commerce','user':'commerce_runtime','serverAddress':'10.0.1.4','tls':True,'serverAt':'2026-09-05T00:35:00Z',
                       'order':{'id':2,'totalCents':300,'itemCount':2}}}}
    raw['targetHealth']['TargetHealthDescriptions'][0]['Target']={'Id':'10.0.50.2','Port':8080}
    raw['targetGroup']['TargetGroups'][0]['TargetType']='ip'
    listener='arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/rebuilt/123/456'
    raw['listeners']={'Listeners':[{'ListenerArn':listener,'LoadBalancerArn':e['loadBalancerArn'],'Protocol':'HTTPS','Port':443}]}
    raw['listenerRulesListenerArn']=listener
    raw['listenerRules']={'Rules':[{'Priority':'1','Conditions':[{'Field':'host-header','Values':[host]},{'Field':'path-pattern','Values':['/*']}],
        'Actions':[{'Type':'forward','TargetGroupArn':e['targetGroupArn']}]}]}

ROOT = pathlib.Path(__file__).resolve().parents[1]


class Rebuild(unittest.TestCase):
    def test_rejects_broken_traffic_graph_and_stale_pod_observation(self):
        changes=[lambda r:r.update(listenerRulesListenerArn='foreign-listener'),
                 lambda r:r['listenerRules']['Rules'][0]['Actions'][0].update(TargetGroupArn='foreign-target'),
                 lambda r:r['httpRoutes']['items'][0]['spec']['rules'][0]['backendRefs'][0].update(name='source-ingress'),
                 lambda r:r['targetBindings']['items'][0]['spec']['serviceRef'].update(name='source-ingress'),
                 lambda r:r['ingressEndpoints']['items'][0]['endpoints'][0]['targetRef'].update(uid='foreign-pod'),
                 lambda r:r['virtualServices']['items'][0]['spec']['http'][0]['route'][0]['destination'].update(host='source-app'),
                 lambda r:r['appEndpoints']['items'][0]['endpoints'][0]['targetRef'].update(uid='foreign-pod'),
                 lambda r:r['appDatabaseConnections']['app-uid'].update(podUid='old-pod'),
                 lambda r:r['appDatabaseConnections']['app-uid']['observation'].update(serverAddress='10.0.99.9'),
                 lambda r:r['appDatabaseConnections']['app-uid']['observation'].update(tls=False)]
        for index,change in enumerate(changes):
            with self.subTest(case=index):
                raw=observations();change(raw)
                with self.assertRaises(rebuild.db.Denied): self.check(raw)

    def test_rejects_source_alb_foreign_healthy_target_and_source_database(self):
        changes=[lambda r:r['lbTags']['TagDescriptions'][0]['Tags'][0].update(Value='old'),
                 lambda r:r['targetHealth']['TargetHealthDescriptions'][0]['Target'].update(Id='10.0.99.99'),
                 lambda r:r['appDatabaseConnections']['app-uid']['observation'].update(host='commerce-source.example.invalid'),
                 lambda r:r['appExternalSecrets']['items'][0]['spec']['data'][0]['remoteRef'].update(key='prod/mini-commerce/database')]
        for i,change in enumerate(changes):
            with self.subTest(case=i):
                raw=observations();change(raw)
                with self.assertRaises(rebuild.db.Denied): self.check(raw)
    def test_requires_redis_ha_and_target_argo_server_binding(self):
        for kind in ('redis','argo'):
            raw=observations()
            if kind=='redis': raw['controllers']['items'].pop()
            else: raw['argocdConfig']['data']['url']='https://source-argo.example.com'
            with self.subTest(kind=kind):
                with self.assertRaises((rebuild.db.Denied,KeyError)): self.check(raw)

    def test_rejects_anonymous_argo_identity(self):
        raw=observations(); raw['argoUser']['loggedIn']=False
        with self.assertRaises(rebuild.db.Denied): self.check(raw)

    def test_capture_binds_kubectl_to_new_endpoint_and_reads_all_service_boundaries(self):
        raw=observations()
        raw['targetCluster']['certificateAuthority']={'data':'Y2E='}
        calls=[]
        def external(args,**kwargs):
            calls.append(args)
            if args[0]=='aws':
                if 'get-caller-identity' in args: result=raw['caller']
                elif 'describe-cluster' in args: result={'cluster':raw['targetCluster'] if args[args.index('--name')+1]=='new' else raw['sourceCluster']}
                elif 'get-role' in args: result={'Role':next(v for k,v in raw['roles'].items() if k.endswith('/'+args[args.index('--role-name')+1]))}
                elif 'get-web-acl-for-resource' in args: result=raw['waf']
                elif 'describe-load-balancers' in args: result=raw['loadBalancer']
                elif 'describe-target-groups' in args: result=raw['targetGroup']
                elif 'describe-target-health' in args: result=raw['targetHealth']
                elif 'describe-tags' in args: result=raw['lbTags']
                elif 'describe-listeners' in args: result=raw['listeners']
                elif 'describe-rules' in args:
                    self.assertEqual(args[args.index('--listener-arn')+1],raw['listenerRulesListenerArn'])
                    result=raw['listenerRules']
                else: self.fail('unexpected AWS command')
            elif args[0]=='kubectl':
                config=json.loads(pathlib.Path(args[2]).read_text())
                self.assertEqual(config['clusters'][0]['cluster']['server'],'https://new.example.invalid')
                self.assertEqual(config['users'][0]['user']['exec']['args'][-1],'new')
                self.assertEqual(pathlib.Path(args[2]).stat().st_mode & 0o777,0o600)
                if 'can-i' in args: return subprocess.CompletedProcess(args,0,'yes\n','')
                if args[3]=='exec':
                    self.assertEqual(args[4:12],['-n','app-recovery','commerce-1','-c','mini-commerce','--','node','--input-type=module'])
                    self.assertIn("import { createDatabasePool }",args[-1])
                    self.assertIn('BEGIN READ ONLY',args[-1])
                    result=raw['appDatabaseConnections']['app-uid']['observation']
                elif args[4]=='pod': result=raw['appPods']['items'][0]
                else:
                    namespace=args[args.index('-n')+1] if '-n' in args else ''
                    mapping={'externalsecrets':'externalSecrets' if namespace=='argocd' else 'appExternalSecrets','secretstores':'stores',
                             'serviceaccounts':'serviceAccounts','applications':'applications','deployments,statefulsets':'controllers',
                             'pods':'appPods' if namespace=='app-recovery' else 'ingressPods','configmap':'argocdConfig',
                             'services':'appServices' if namespace=='app-recovery' else 'ingressServices',
                             'endpointslices.discovery.k8s.io':'appEndpoints' if namespace=='app-recovery' else 'ingressEndpoints',
                             'httproutes.gateway.networking.k8s.io':'httpRoutes','targetgroupbindings.elbv2.k8s.aws':'targetBindings',
                             'gateways.gateway.networking.k8s.io':'edgeGateway','gateways.networking.istio.io':'istioGateway',
                             'virtualservices.networking.istio.io':'virtualServices'}
                    result=raw[mapping[args[4]]]
            elif args[0]=='argocd':
                self.assertEqual(args[2],'argo.example.com')
                if 'can-i' in args: return subprocess.CompletedProcess(args,0,'Yes\n','')
                result=raw['argoUser']
            elif args[0]=='curl':
                self.assertEqual(args[-1],'https://shop.example.com/orders/2')
                self.assertIn('shop.example.com:443:recovery-alb.elb.amazonaws.com:443',args)
                result=raw['readback']
            else: self.fail('unexpected executable')
            return subprocess.CompletedProcess(args,0,json.dumps(result),'')
        with patch.object(rebuild.db.subprocess,'run',side_effect=external): result=rebuild.capture(raw['expected'])
        self.assertEqual(len(calls),37)
        self.assertEqual(result['readback']['order']['id'],2)
        self.assertEqual(result['appDatabaseConnections']['app-uid']['observation']['host'],'commerce-target.example.invalid')
        self.assertEqual(result['lbTags'],raw['lbTags'])

    def test_reads_actual_injector_revision_annotation(self):
        raw=observations()
        pod=raw['appPods']['items'][0]
        pod['metadata']['labels'].pop('istio.io/rev')
        pod['metadata']['annotations']={'sidecar.istio.io/status':json.dumps({'revision':'1-30-4','containers':['istio-proxy']})}
        self.assertEqual(self.check(raw)['istioRevision'],'1-30-4')

    def check(self, raw):
        return rebuild.evaluate(raw,*support.pair(rebuild.rds),'2026-09-05T00:15:00Z',current=dt.datetime(2026,9,5,1,tzinfo=dt.timezone.utc))

    def test_complete_raw_observations_derive_platform_rto(self):
        result=self.check(observations())
        self.assertEqual(result['achieved'],{'rtoMinutes':35,'rpoMinutes':15})
        self.assertEqual(result['evidenceGrade'],'LOCAL_VERIFIED')

    def test_rejects_missing_rehydration_cluster_digest_health_readback_or_grade(self):
        changes=[lambda r:r['sourceCluster'].update(arn=r['targetCluster']['arn']),
                 lambda r:r['externalSecrets']['items'].pop(),
                 lambda r:r['appPods']['items'][0]['status']['containerStatuses'][1].update(imageID='wrong'),
                 lambda r:r['targetHealth'].update(TargetHealthDescriptions=[]),
                 lambda r:r['readback']['order'].update(totalCents=301),
                 lambda r:r.update(argoAuthorization='no'),lambda r:r.update(evidenceGrade='CLOUD_RUNTIME'),
                 lambda r:r['applications']['items'][0]['status']['sync'].update(revision='f'*40)]
        for index,change in enumerate(changes):
            with self.subTest(case=index):
                raw=observations(); change(raw)
                with self.assertRaises((rebuild.db.Denied,KeyError)): self.check(raw)

    def test_rejects_future_refresh_after_capture_completion(self):
        raw=observations()
        raw['externalSecrets']['items'][0]['status']['refreshTime']='2026-09-05T00:59:00Z'
        with self.assertRaises(rebuild.db.Denied): self.check(raw)

    def test_rejects_cross_account_load_balancer_expected_identity(self):
        raw=observations()
        raw['expected']['loadBalancerArn']=raw['expected']['loadBalancerArn'].replace('123456789012','999999999999')
        raw['loadBalancer']['LoadBalancers'][0]['LoadBalancerArn']=raw['expected']['loadBalancerArn']
        raw['targetGroup']['TargetGroups'][0]['LoadBalancerArns']=[raw['expected']['loadBalancerArn']]
        with self.assertRaises(rebuild.db.Denied): self.check(raw)

    def test_rds_only_is_explicit_pending(self):
        result = subprocess.run(['bash', str(ROOT/'scripts/platform-rebuild-dr-check.sh')], capture_output=True,text=True)
        self.assertEqual(result.returncode,2)
        self.assertIn('PENDING',result.stdout)


if __name__ == '__main__': unittest.main()
