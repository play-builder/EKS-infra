"""Bind captured Gateway API, Istio, endpoint and database observations for one recovery path."""
from fnmatch import fnmatchcase
from urllib.parse import urlparse


def validate(raw,target_db,require,timestamp):
    e=raw['expected'];t=e['traffic'];namespace='istio-system';app_namespace='app-recovery'
    url=urlparse(e['applicationUrl']);host=url.hostname
    require(url.scheme=='https' and host and not url.username and not url.password and (url.port or 443)==443)
    tags=raw['lbTags']['TagDescriptions']
    require(len(tags)==1 and tags[0]['ResourceArn']==e['loadBalancerArn'])
    require({tag['Key']:tag['Value'] for tag in tags[0]['Tags']}.get('elbv2.k8s.aws/cluster')==raw['targetCluster']['name'])
    gateway=raw['edgeGateway']
    require(gateway['metadata']['name']==t['gatewayName'] and gateway['metadata']['namespace']==namespace)
    require(any(a['value']==raw['loadBalancer']['LoadBalancers'][0]['DNSName'] for a in gateway['status']['addresses']))
    for kind in ('Accepted','Programmed'):
        require(any(c['type']==kind and c['status']=='True' and c['observedGeneration']==gateway['metadata']['generation'] for c in gateway['status']['conditions']))
    require(any(l['port']==443 and l['protocol']=='HTTPS' and l['hostname']==host for l in gateway['spec']['listeners']))
    routes=[r for r in raw['httpRoutes']['items'] if host in r['spec'].get('hostnames',[]) and any(
        p['name']==t['gatewayName'] and p.get('namespace',r['metadata']['namespace'])==namespace for p in r['spec']['parentRefs'])]
    require(len(routes)==1)
    route=routes[0]
    require(route['metadata']['name']==t['httpRouteName'] and route['metadata']['namespace']==namespace)
    require(len(route['spec']['rules'])==1)
    rule=route['spec']['rules'][0]
    require(not rule.get('filters') and rule['matches']==[{'path':{'type':'PathPrefix','value':'/'}}])
    backends=[b for b in rule['backendRefs'] if b.get('weight',1)>0]
    require(len(backends)==1)
    backend=backends[0]
    require(backend['name']==t['ingressServiceName'] and backend.get('namespace',namespace)==namespace and backend.get('kind','Service')=='Service')
    bindings=[b for b in raw['targetBindings']['items'] if b['spec']['targetGroupARN']==e['targetGroupArn']]
    require(len(bindings)==1)
    binding=bindings[0]
    require(binding['metadata']['namespace']==namespace and binding['spec']['targetType']=='ip' and not binding['spec'].get('multiClusterTargetGroup',False))
    require(binding['spec']['serviceRef']['name']==t['ingressServiceName'] and binding['spec']['serviceRef']['port']==backend['port'])
    require(raw['targetGroup']['TargetGroups'][0]['TargetType']=='ip')
    ingress_targets,ingress_pods=service_endpoints(raw['ingressServices'],raw['ingressEndpoints'],raw['ingressPods'],
                                                 namespace,t['ingressServiceName'],backend['port'],require)
    actual_targets={(h['Target']['Id'],h['Target']['Port']) for h in raw['targetHealth']['TargetHealthDescriptions']}
    require(actual_targets==ingress_targets)
    istio=raw['istioGateway']
    require(istio['metadata']['namespace']==namespace and istio['metadata']['name']==t['istioGatewayName'])
    selector=istio['spec']['selector'];require(selector)
    require(all(all(p['metadata']['labels'].get(k)==v for k,v in selector.items()) for p in ingress_pods))
    require(any(s['port']['number']==backend['port'] and s['port']['protocol']=='HTTP' and host in s['hosts'] for s in istio['spec']['servers']))
    qualified_gateway=namespace+'/'+t['istioGatewayName']
    virtuals=[v for v in raw['virtualServices']['items'] if any(fnmatchcase(host,h) for h in v['spec']['hosts']) and any(
        (g if '/' in g else v['metadata']['namespace']+'/'+g)==qualified_gateway for g in v['spec'].get('gateways',[]))]
    require(len(virtuals)==1)
    virtual=virtuals[0]
    require(virtual['metadata']['namespace']==app_namespace and virtual['metadata']['name']==t['virtualServiceName'])
    require(host in virtual['spec']['hosts'] and len(virtual['spec']['http'])==1)
    http=virtual['spec']['http'][0]
    require(http['match']==[{'uri':{'prefix':'/'}}] and not any(k in http for k in ('redirect','delegate','rewrite','fault')))
    destinations=[r for r in http['route'] if r.get('weight',100)>0]
    require(len(destinations)==1 and destinations[0].get('weight',100)==100)
    destination=destinations[0]['destination']
    require(destination['host'] in (t['appServiceName'],t['appServiceName']+'.'+app_namespace+'.svc.cluster.local'))
    _,app_pods=service_endpoints(raw['appServices'],raw['appEndpoints'],raw['appPods'],app_namespace,t['appServiceName'],destination['port']['number'],require)
    listener_forward(raw,e,host,url.path,require)
    database=target_db['contract']
    sources=raw['appExternalSecrets']['items']
    for pod in app_pods:
        container=next(c for c in pod['spec']['containers'] if c['name']=='mini-commerce')
        envs=container['env'];require(len({v['name'] for v in envs})==len(envs))
        env={v['name']:v for v in envs}
        names=set()
        for key in ('DB_HOST','DB_PORT','DB_NAME','DB_USER','DB_PASSWORD'):
            require('value' not in env[key])
            ref=env[key]['valueFrom']['secretKeyRef'];require(ref['key']==key and not ref.get('optional',False));names.add(ref['name'])
        require(len(names)==1)
        secret_name=next(iter(names))
        matches=[s for s in sources if s['metadata']['namespace']==app_namespace and s['spec']['target']['name']==secret_name]
        require(len(matches)==1)
        secret=matches[0]
        require(any(c['type']=='Ready' and c['status']=='True' for c in secret['status']['conditions']))
        require(timestamp(raw['targetCluster']['createdAt'])<=timestamp(secret['status']['refreshTime'])<=timestamp(raw['completedAt']))
        require(not secret['spec'].get('dataFrom') and not secret['spec']['target'].get('template'))
        mappings={d['secretKey']:d['remoteRef'] for d in secret['spec']['data']}
        require(len(mappings)==len(secret['spec']['data']))
        for key in ('DB_HOST','DB_PORT','DB_NAME','DB_USER','DB_PASSWORD'):
            require(mappings[key]['key']==database['applicationCredentials']['database']['name'] and mappings[key]['property']==key)
        connection=raw['appDatabaseConnections'][pod['metadata']['uid']]
        require(connection['podUid']==pod['metadata']['uid'] and connection['podName']==pod['metadata']['name'])
        observation=connection['observation']
        require(observation['host']==database['endpoint'] and observation['port']==database['port'])
        require(observation['database']==database['databaseName'] and observation['user']=='commerce_runtime' and observation['tls'] is True)
        require(observation['serverAddress']==target_db['sql']['serverAddress'] and observation['order']==target_db['sql']['readbackOrder'])
        require(timestamp(raw['startedAt'])<=timestamp(observation['serverAt'])<=timestamp(connection['observedAt'])<=timestamp(raw['completedAt']))


def service_endpoints(services,slices,pods,namespace,name,port,require):
    services=[s for s in services['items'] if s['metadata']['namespace']==namespace and s['metadata']['name']==name]
    require(len(services)==1);service=services[0]
    selector=service['spec']['selector'];require(selector)
    ports=[p for p in service['spec']['ports'] if port in (p['port'],p['name'])]
    require(len(ports)==1);service_port=ports[0]
    ready={p['metadata']['uid']:p for p in pods['items'] if p['metadata']['namespace']==namespace and
        all(p['metadata']['labels'].get(k)==v for k,v in selector.items()) and p['status']['phase']=='Running' and
        any(c['type']=='Ready' and c['status']=='True' for c in p['status']['conditions']) and not p['metadata'].get('deletionTimestamp')}
    require(ready)
    target_ids=set();seen=set()
    selected=[s for s in slices['items'] if s['metadata']['namespace']==namespace and s['metadata']['labels'].get('kubernetes.io/service-name')==name]
    require(selected)
    for section in selected:
        require(any(o['kind']=='Service' and o['name']==name and o['uid']==service['metadata']['uid'] for o in section['metadata']['ownerReferences']))
        ports=[p for p in section['ports'] if p['name']==service_port['name'] and p.get('protocol','TCP')=='TCP']
        require(len(ports)==1)
        for endpoint in section['endpoints']:
            require(endpoint['conditions']['ready'] is True and not endpoint['conditions'].get('terminating',False))
            ref=endpoint['targetRef'];require(ref['kind']=='Pod' and ref['namespace']==namespace and ref['uid'] in ready)
            pod=ready[ref['uid']];require(ref['name']==pod['metadata']['name'])
            require(endpoint['addresses']==[pod['status']['podIP']])
            target=service_port.get('targetPort',service_port['port'])
            if isinstance(target,str):
                numbers={p['containerPort'] for c in pod['spec']['containers'] for p in c.get('ports',[]) if p['name']==target}
                require(len(numbers)==1);target=next(iter(numbers))
            require(ports[0]['port']==target)
            seen.add(ref['uid']);target_ids.add((pod['status']['podIP'],target))
    require(seen==set(ready))
    return target_ids,list(ready.values())


def listener_forward(raw,e,host,path,require):
    listeners=[l for l in raw['listeners']['Listeners'] if l['LoadBalancerArn']==e['loadBalancerArn'] and l['Port']==443 and l['Protocol']=='HTTPS']
    require(len(listeners)==1)
    require(raw['listenerRulesListenerArn']==listeners[0]['ListenerArn'])
    rules=sorted(raw['listenerRules']['Rules'],key=lambda r: int(r['Priority']) if r['Priority']!='default' else 50001)
    for rule in rules:
        matches=True
        for condition in rule['Conditions']:
            field=condition['Field']
            require(field in ('host-header','path-pattern','http-request-method'))
            value={'host-header':host,'path-pattern':path,'http-request-method':'GET'}[field]
            matches=matches and any(fnmatchcase(value,p) for p in condition['Values'])
        if matches:
            require(len(rule['Actions'])==1 and rule['Actions'][0]['Type']=='forward')
            action=rule['Actions'][0]
            arns={action['TargetGroupArn']} if 'TargetGroupArn' in action else {t['TargetGroupArn'] for t in action['ForwardConfig']['TargetGroups'] if t.get('Weight',1)>0}
            require(arns=={e['targetGroupArn']})
            return
    require(False)
