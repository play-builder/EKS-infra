#!/usr/bin/env python3
"""User-run API collectors. No cloud resource mutation except server dry-run admission."""
import datetime,fnmatch,hashlib,json,os,pathlib,re,subprocess,sys,tempfile
def require(v,c):
 if not v:raise ValueError(c)
def run(*args):return json.loads(subprocess.check_output(args,text=True,timeout=90))
def validate_scanning(x,repositories):
 c=x["scanningConfiguration"];require(c["scanType"]=="ENHANCED","ECR_NOT_ENHANCED")
 for repo in repositories:
  require(any(r["scanFrequency"]=="CONTINUOUS_SCAN" and any(f["filterType"]=="WILDCARD" and fnmatch.fnmatchcase(repo,f["filter"]) for f in r["repositoryFilters"]) for r in c["rules"]),"ECR_FILTER_OR_FREQUENCY_MISMATCH")
def validate_handoff(plan):
 require(not any(r["type"]=="aws_ecr_registry_scanning_configuration" and "delete" in r["change"]["actions"] for r in plan.get("resource_changes",[])),"SCANNING_DESTROY_FORBIDDEN")
def validate_admission(signed,unsigned,allowed,denied,error):
 require(signed!=unsigned and all(re.fullmatch(r"[^\s]+@sha256:[0-9a-f]{64}",i) for i in [signed,unsigned]),"DIGEST_REQUIRED")
 require(allowed==0 and denied!=0 and re.search(r"admission webhook.*(sigstore|policy-controller).*denied",error,re.S),"ADMISSION_NOT_PROVEN")
def emit(output,schema,observations):
 x={"schemaVersion":schema,"evidenceGrade":"CLOUD_RUNTIME","observedAt":datetime.datetime.now(datetime.timezone.utc).isoformat(),"observations":observations,"observationsSha256":hashlib.sha256(json.dumps(observations,sort_keys=True).encode()).hexdigest(),"decision":"PASS"}
 p=pathlib.Path(output);p.parent.mkdir(parents=True,exist_ok=True)
 with tempfile.NamedTemporaryFile("w",dir=p.parent,delete=False) as f:json.dump(x,f);tmp=f.name
 os.replace(tmp,p)
def identity(cluster,region):
 c=run("aws","eks","describe-cluster","--name",cluster,"--region",region,"--output","json")["cluster"]
 require(run("kubectl","config","view","--minify","-o","json")["clusters"][0]["cluster"]["server"]==c["endpoint"],"KUBECONFIG_CLUSTER_MISMATCH")
 return c["arn"]
def controller(cluster,region,replicas,output):
 arn=identity(cluster,region)
 deploy=run("kubectl","-n","cosign-system","get","deploy","-o","json")
 require(deploy["items"] and all(d.get("status",{}).get("availableReplicas",0)>=int(replicas) for d in deploy["items"]),"SIGSTORE_CONTROLLER_NOT_READY")
 crds={n:run("kubectl","get","crd",n,"-o","json") for n in ["clusterimagepolicies.policy.sigstore.dev","trustroots.policy.sigstore.dev"]}
 for n,c in crds.items():
  require(any(v["type"]=="Established" and v["status"]=="True" for v in c.get("status",{}).get("conditions",[])),"SIGSTORE_CRD_NOT_ESTABLISHED")
  require([v["name"] for v in c["spec"]["versions"] if v["storage"]]==["v1alpha1"],"SIGSTORE_STORAGE_VERSION_MISMATCH")
  expected={"v1alpha1","v1beta1"} if n.startswith("clusterimage") else {"v1alpha1"}
  require({v["name"] for v in c["spec"]["versions"] if v["served"]}==expected,"SIGSTORE_SERVED_VERSION_MISMATCH")
 webhooks=run("kubectl","get","validatingwebhookconfigurations","-o","json")
 selected=[w for obj in webhooks["items"] for w in obj["webhooks"] if w.get("clientConfig",{}).get("service",{}).get("namespace")=="cosign-system"]
 require(selected and all(w.get("failurePolicy")=="Fail" for w in selected),"SIGSTORE_WEBHOOK_NOT_FAIL_CLOSED")
 emit(output,"platform.sigstore-controller/v1",{"clusterArn":arn,"region":region,"deployments":deploy,"crds":crds,"webhooks":selected,"policyOwner":"argocd-gitops"})
def admission(cluster,region,namespace,signed,unsigned,output):
 arn=identity(cluster,region)
 require(re.fullmatch(r"(sigstore|admission)-drill-[a-z0-9-]+",namespace),"DEDICATED_DRILL_NAMESPACE_REQUIRED")
 n=run("kubectl","get","namespace",namespace,"-o","json")
 require(n["metadata"].get("labels",{}).get("policy.sigstore.dev/include")=="true","GITOPS_NAMESPACE_OPT_IN_REQUIRED")
 require(signed!=unsigned and all(re.fullmatch(r"[^\s]+@sha256:[0-9a-f]{64}",i) for i in [signed,unsigned]),"DIGEST_REQUIRED")
 results=[]
 for name,image in [("signed",signed),("unsigned",unsigned)]:
  pod={"apiVersion":"v1","kind":"Pod","metadata":{"name":"sigstore-dry-run-"+name,"namespace":namespace},"spec":{"restartPolicy":"Never","containers":[{"name":"probe","image":image}]}}
  r=subprocess.run(["kubectl","create","--dry-run=server","-f","-","-o","json"],input=json.dumps(pod),text=True,capture_output=True,timeout=90)
  results.append({"status":r.returncode,"stdout":r.stdout,"stderr":r.stderr,"image":image})
 validate_admission(signed,unsigned,results[0]["status"],results[1]["status"],results[1]["stderr"])
 emit(output,"platform.sigstore-admission-preflight/v1",{"clusterArn":arn,"region":region,"namespaceUid":n["metadata"]["uid"],"method":"server-dry-run","signedAdmission":results[0],"unsignedAdmission":results[1],"persistedObjects":0})
def scanning(region,legacy,new,digest,output):
 require(re.fullmatch(r"sha256:[0-9a-f]{64}",digest),"DIGEST_REQUIRED")
 account=run("aws","sts","get-caller-identity","--region",region,"--output","json")["Account"]
 c=run("aws","ecr","get-registry-scanning-configuration","--region",region,"--output","json");validate_scanning(c,[legacy,new])
 scan=run("aws","ecr","describe-image-scan-findings","--repository-name",new,"--image-id","imageDigest="+digest,"--region",region,"--output","json")
 require(scan["imageScanStatus"]["status"] in ["ACTIVE","COMPLETE"],"ECR_SCAN_NOT_ACTIVE")
 require(scan["registryId"]==account and scan["repositoryName"]==new and scan["imageId"]["imageDigest"]==digest,"ECR_SCAN_IDENTITY_MISMATCH")
 emit(output,"platform.ecr-scanning/v1",{"accountId":account,"region":region,"registry":c,"scan":scan,"claim":"continuous scanning status only; not signature verification or zero vulnerabilities"})
if __name__=="__main__":
 try:
  mode=sys.argv[1]
  if mode=="controller":controller(*sys.argv[2:])
  elif mode=="admission":admission(*sys.argv[2:])
  elif mode=="scanning":scanning(*sys.argv[2:])
  elif mode=="handoff":validate_handoff(json.loads(pathlib.Path(sys.argv[2]).read_text()));print("PASS: local no-destroy plan; perform reviewed state import/rm separately")
  else:raise ValueError("Unknown collector")
 except (ValueError,KeyError,TypeError,subprocess.SubprocessError) as e:print(e,file=sys.stderr);sys.exit(1)
