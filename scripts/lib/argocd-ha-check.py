#!/usr/bin/env python3
"""Read-only production HA/RBAC collector; never reads Secret data."""
import datetime,hashlib,json,os,pathlib,subprocess,sys,tempfile
COMPONENTS=["argocd-server","argocd-repo-server","argocd-application-controller","argocd-applicationset-controller"]
def require(v,c):
 if not v:raise ValueError(c)
def validate(x):
 require(set(x["components"])==set(COMPONENTS),"ARGO_COMPONENT_MISSING")
 for c in x["components"].values():
  require(c["ready"]>=2 and c["ready"]==c["desired"],"ARGO_NOT_HA")
  require(len(set(c["nodes"]))>=2 and len(set(c["zones"]))>=2,"ARGO_NOT_DISTRIBUTED")
 require(x["redisReady"]>=3,"REDIS_NO_QUORUM_CAPACITY")
 require(len(x["pdbs"])>=4 and all(n>0 for n in x["pdbs"]),"ARGO_PDB_BLOCKED")
 require(x["externalSecretsReady"]==3 and len(x["secretMetadataHashes"])==3,"ARGO_SECRETS_UNRESOLVED")
 require(x["rbac"]=={"readonlyGet":True,"readonlyDelete":False,"adminSync":True},"ARGO_RBAC_DENIED")
def collect(cluster,region,readonly,admin,output):
 def raw(*args):return subprocess.check_output(args,text=True,timeout=90).strip()
 def run(*args):return json.loads(raw(*args))
 c=run("aws","eks","describe-cluster","--name",cluster,"--region",region,"--output","json")["cluster"]
 require(run("kubectl","config","view","--minify","-o","json")["clusters"][0]["cluster"]["server"]==c["endpoint"],"KUBECONFIG_CLUSTER_MISMATCH")
 objects=run("kubectl","-n","argocd","get","deploy,statefulset,pdb","-o","json")["items"]
 pods=run("kubectl","-n","argocd","get","pods","-o","json")["items"]
 nodes={n["metadata"]["name"]:n["metadata"]["labels"].get("topology.kubernetes.io/zone","") for n in run("kubectl","get","nodes","-o","json")["items"]}
 x={"components":{},"pdbs":[],"redisReady":0}
 for o in objects:
  name=o["metadata"]["name"]
  if o["kind"]=="PodDisruptionBudget":x["pdbs"].append(o["status"].get("disruptionsAllowed",0));continue
  if name in COMPONENTS:
   selected=[p for p in pods if all(p["metadata"]["labels"].get(k)==v for k,v in o["spec"]["selector"]["matchLabels"].items())]
   ready=[p for p in selected if any(v["type"]=="Ready" and v["status"]=="True" for v in p.get("status",{}).get("conditions",[]))]
   placed=[p["spec"]["nodeName"] for p in ready]
   require(all(nodes.get(n) for n in placed),"NODE_ZONE_MISSING")
   x["components"][name]={"ready":o.get("status",{}).get("readyReplicas",0),"desired":o["spec"].get("replicas",1),"nodes":placed,"zones":[nodes[n] for n in placed]}
  if o["kind"]=="StatefulSet" and "redis-ha" in name:x["redisReady"]=o.get("status",{}).get("readyReplicas",0)
 es=run("kubectl","-n","argocd","get","externalsecrets","-o","json")["items"]
 targets={"argocd-oidc","argocd-notifications-secret","argocd-repository-credentials"}
 x["externalSecretsReady"]=sum(1 for e in es if e["spec"].get("target",{}).get("name") in targets and e.get("status",{}).get("refreshTime") and any(v["type"]=="Ready" and v["status"]=="True" for v in e.get("status",{}).get("conditions",[])))
 x["secretMetadataHashes"]=[hashlib.sha256(raw("kubectl","-n","argocd","get","secret",n,"-o","jsonpath={.metadata.uid}/{.metadata.resourceVersion}").encode()).hexdigest() for n in sorted(targets)]
 def can(group,verb):
  result=subprocess.run(["argocd","admin","settings","rbac","can",group,verb,"applications","*/*","--namespace","argocd"],capture_output=True,text=True,timeout=90)
  decision=(result.returncode,result.stdout.strip())
  require(not result.stderr.strip() and decision in [(0,"Yes"),(1,"No")],"ARGO_RBAC_COMMAND_FAILED")
  return decision==(0,"Yes")
 x["rbac"]={"readonlyGet":can(readonly,"get"),"readonlyDelete":can(readonly,"delete"),"adminSync":can(admin,"sync")}
 validate(x)
 x.update(schemaVersion="platform.argocd-ha/v1",evidenceGrade="CLOUD_RUNTIME",decision="PASS",clusterArn=c["arn"],region=region,observedAt=datetime.datetime.now(datetime.timezone.utc).isoformat())
 p=pathlib.Path(output);p.parent.mkdir(parents=True,exist_ok=True)
 with tempfile.NamedTemporaryFile("w",dir=p.parent,delete=False) as f:json.dump(x,f);tmp=f.name
 os.replace(tmp,p)
if __name__=="__main__":
 try:collect(*sys.argv[1:])
 except (ValueError,KeyError,TypeError,subprocess.SubprocessError) as e:print(e,file=sys.stderr);sys.exit(1)
