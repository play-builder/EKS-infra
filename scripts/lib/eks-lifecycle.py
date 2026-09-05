#!/usr/bin/env python3
"""Read-only lifecycle collector. Local observation validation never emits CLOUD_RUNTIME evidence."""
import datetime, hashlib, json, os, pathlib, subprocess, sys, tempfile, time

def require(value, code):
 if not value: raise ValueError(code)
def run(*args):
 return json.loads(subprocess.check_output(args, text=True, timeout=90))
def validate(x):
 age=(datetime.datetime.now(datetime.timezone.utc)-datetime.datetime.fromisoformat(x["observedAt"].replace("Z","+00:00"))).total_seconds()
 require(0 <= age <= 900, "UPGRADE_OBSERVATIONS_STALE")
 require(x["refresh"]["status"]=="COMPLETED","INSIGHTS_REFRESH_INCOMPLETE")
 require(x["insights"] and len(x["details"])==len(x["insights"]),"INSIGHTS_MISSING")
 for i in x["insights"]:
  require(i["kubernetesVersion"]==x["toVersion"] and i["insightStatus"]["status"]=="PASS","INSIGHT_NOT_PASS")
 for d in x["details"]:
  i=d["insight"]
  require(i["insightStatus"]["status"]=="PASS","INSIGHT_DETAIL_NOT_PASS")
  require(all(r.get("insightStatus",{}).get("status")=="PASS" for r in i.get("resources",[])),"UNSUPPORTED_API")
 require(x["nodes"]["items"],"NO_NODES")
 require(all(any(c["type"]=="Ready" and c["status"]=="True" for c in n["status"]["conditions"]) for n in x["nodes"]["items"]),"NODE_NOT_READY")
 require(all(p["status"].get("disruptionsAllowed",0)>0 for p in x["pdbs"]["items"]),"PDB_BLOCKS_DISRUPTION")
 require(all(x["addons"].get(n) for n in ["coredns","kube-proxy","vpc-cni","aws-ebs-csi-driver","snapshot-controller"]),"ADDON_MISSING")
 names=[c["metadata"]["name"] for c in x["controllers"]["items"]]
 require(all(any(w in n for n in names) for w in ["cluster-autoscaler","argocd","rollouts","external-secrets","adot","istiod"]),"CONTROLLER_INVENTORY_INCOMPLETE")
 require(x["nodegroup"]["status"]=="ACTIVE" and not x["nodegroup"]["health"]["issues"],"NODEGROUP_UNHEALTHY")
 require(x["nodegroup"]["releaseVersion"]==x["expectedRelease"],"NODE_RELEASE_MISMATCH")
def collect(cluster, region, old, new, nodegroup, release, output):
 aws=lambda *a:run("aws",*a,"--region",region,"--output","json")
 identity=aws("sts","get-caller-identity")
 cluster_data=aws("eks","describe-cluster","--name",cluster)["cluster"]
 require(cluster_data["version"]==old,"SOURCE_CLUSTER_VERSION_MISMATCH")
 # The kubeconfig must already target this exact cluster. No context is silently changed.
 context=run("kubectl","config","view","--minify","-o","json")
 require(context["clusters"][0]["cluster"]["server"]==cluster_data["endpoint"],"KUBECONFIG_CLUSTER_MISMATCH")
 aws("eks","start-insights-refresh","--cluster-name",cluster)
 deadline=time.monotonic()+300
 while True:
  refresh=aws("eks","describe-insights-refresh","--cluster-name",cluster)
  if refresh["status"]=="COMPLETED": break
  require(refresh["status"]!="FAILED" and time.monotonic()<deadline,"INSIGHTS_REFRESH_TIMEOUT")
  time.sleep(10)
 insights=aws("eks","list-insights","--cluster-name",cluster,"--filter",json.dumps({"categories":["UPGRADE_READINESS"],"kubernetesVersions":[new]}))["insights"]
 details=[aws("eks","describe-insight","--cluster-name",cluster,"--id",i["id"]) for i in insights]
 addons={n:aws("eks","describe-addon","--cluster-name",cluster,"--addon-name",n)["addon"]["addonVersion"] for n in ["coredns","kube-proxy","vpc-cni","aws-ebs-csi-driver","snapshot-controller"]}
 x={"cluster":cluster,"region":region,"accountId":identity["Account"],"clusterArn":cluster_data["arn"],"fromVersion":old,"toVersion":new,"observedAt":datetime.datetime.now(datetime.timezone.utc).isoformat(),"refresh":refresh,"insights":insights,"details":details,"addons":addons,"nodes":run("kubectl","get","nodes","-o","json"),"pdbs":run("kubectl","get","pdb","-A","-o","json"),"controllers":run("kubectl","get","deploy,statefulset,daemonset","-A","-o","json"),"nodegroup":aws("eks","describe-nodegroup","--cluster-name",cluster,"--nodegroup-name",nodegroup)["nodegroup"],"expectedRelease":release}
 validate(x)
 x.update(schemaVersion="platform.eks-upgrade-preflight/v1",evidenceGrade="CLOUD_RUNTIME",decision="PASS",observationsSha256=hashlib.sha256(json.dumps(x,sort_keys=True).encode()).hexdigest())
 p=pathlib.Path(output); p.parent.mkdir(parents=True,exist_ok=True)
 with tempfile.NamedTemporaryFile(mode="w",dir=p.parent,delete=False) as f: json.dump(x,f); tmp=f.name
 os.replace(tmp,p)
if __name__=="__main__":
 try:
  if sys.argv[1]=="validate": validate(json.loads(pathlib.Path(sys.argv[2]).read_text())); print("PASS: local observations only")
  elif sys.argv[1]=="collect": collect(*sys.argv[2:])
  else: raise ValueError("USAGE: validate file | collect cluster region from to nodegroup release output")
 except (ValueError,KeyError,TypeError,IndexError,subprocess.SubprocessError) as e: print(str(e),file=sys.stderr); sys.exit(1)
