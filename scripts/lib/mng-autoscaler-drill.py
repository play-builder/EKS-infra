#!/usr/bin/env python3
"""Explicit user-run bounded workload drill; never changes ASG/MNG desired size."""
import datetime,hashlib,json,os,pathlib,re,signal,subprocess,sys,tempfile,time,uuid
def require(v,c):
 if not v:raise ValueError(c)
def validate(x):
 age=(datetime.datetime.now(datetime.timezone.utc)-datetime.datetime.fromisoformat(x["startedAt"])).total_seconds()
 require(0<=age<=7200,"DRILL_STALE")
 require(x["pendingObserved"],"PENDING_NOT_OBSERVED")
 require(set(x["scaleOutNodes"])-set(x["initialNodes"]),"NODE_NOT_ADDED")
 require(x["workloadReady"],"WORKLOAD_NOT_READY")
 require(len(x["scaleInNodes"])<len(x["scaleOutNodes"]),"NODE_NOT_REMOVED")
 require(x["pdbViolations"]==0,"PDB_VIOLATION")
 require(x["cleanupSucceeded"] and x["remainingWorkloads"]==0,"CLEANUP_INCOMPLETE")
def command(*args,payload=None):
 r=subprocess.run(args,input=None if payload is None else json.dumps(payload),text=True,capture_output=True,timeout=90,check=True)
 return json.loads(r.stdout) if r.stdout.strip().startswith(("{","[")) else r.stdout
def drill(cluster,region,nodegroup,image,replicas,output):
 replicas=int(replicas);require(1<=replicas<=50,"REPLICAS_OUT_OF_BOUNDS")
 require(re.fullmatch(r"[^\s]+@sha256:[0-9a-f]{64}",image),"DIGEST_REQUIRED")
 aws=lambda *a:command("aws",*a,"--region",region,"--output","json")
 c=aws("eks","describe-cluster","--name",cluster)["cluster"]
 require(command("kubectl","config","view","--minify","-o","json")["clusters"][0]["cluster"]["server"]==c["endpoint"],"CLUSTER_CONTEXT_MISMATCH")
 ng=aws("eks","describe-nodegroup","--cluster-name",cluster,"--nodegroup-name",nodegroup)["nodegroup"]
 require(ng["status"]=="ACTIVE" and ng["scalingConfig"]["desiredSize"]<ng["scalingConfig"]["maxSize"],"NO_SCALE_OUT_HEADROOM")
 selector="eks.amazonaws.com/nodegroup="+nodegroup
 nodes=lambda:command("kubectl","get","nodes","-l",selector,"-o","json")["items"]
 names=lambda ns:[n["metadata"]["name"] for n in ns]
 namespace="mng-drill-"+uuid.uuid4().hex[:12];label={"platform-drill":namespace}
 x={"startedAt":datetime.datetime.now(datetime.timezone.utc).isoformat(),"initialNodes":names(nodes()),"pendingObserved":False,"workloadReady":False,"pdbViolations":0,"cleanupSucceeded":False,"remainingWorkloads":-1,"clusterArn":c["arn"],"region":region,"nodegroup":nodegroup,"namespace":namespace}
 created=False
 def check_pdb():
  for p in command("kubectl","get","pdb","-A","-o","json")["items"]:
   s=p.get("status",{})
   require(s.get("observedGeneration",0)>=p["metadata"].get("generation",1),"PDB_STATUS_STALE")
   if s.get("currentHealthy",0)<s.get("desiredHealthy",0):x["pdbViolations"]+=1
  require(x["pdbViolations"]==0,"PDB_HEALTH_VIOLATION")
 def cleanup():
  if created:
   command("kubectl","delete","namespace",namespace,"--wait=true","--timeout=120s")
   remaining=command("kubectl","get","pods","-A","-l","platform-drill="+namespace,"-o","json")
   x.update(cleanupSucceeded=True,remainingWorkloads=len(remaining["items"]))
 def interrupted(signum,frame):raise KeyboardInterrupt()
 signal.signal(signal.SIGTERM,interrupted)
 try:
  check_pdb()
  command("kubectl","create","-f","-",payload={"apiVersion":"v1","kind":"Namespace","metadata":{"name":namespace,"labels":label}});created=True
  command("kubectl","create","-f","-",payload={"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"pause","namespace":namespace,"labels":label},"spec":{"replicas":replicas,"selector":{"matchLabels":label},"template":{"metadata":{"labels":label},"spec":{"nodeSelector":{"eks.amazonaws.com/nodegroup":nodegroup},"containers":[{"name":"pause","image":image,"resources":{"requests":{"cpu":"500m","memory":"64Mi"},"limits":{"cpu":"500m","memory":"64Mi"}}}]}}}})
  deadline=time.monotonic()+1200
  while time.monotonic()<deadline:
   check_pdb()
   pods=command("kubectl","get","pods","-n",namespace,"-l","platform-drill="+namespace,"-o","json")["items"]
   x["pendingObserved"] |= any(any(c.get("reason")=="Unschedulable" for c in p.get("status",{}).get("conditions",[])) for p in pods)
   x["scaleOutNodes"]=names(nodes())
   x["workloadReady"]=len(pods)==replicas and all(any(c["type"]=="Ready" and c["status"]=="True" for c in p.get("status",{}).get("conditions",[])) for p in pods)
   if x["pendingObserved"] and set(x["scaleOutNodes"])-set(x["initialNodes"]) and x["workloadReady"]:break
   time.sleep(10)
  require(x["pendingObserved"] and x["workloadReady"] and set(x.get("scaleOutNodes",[]))-set(x["initialNodes"]),"SCALE_OUT_TIMEOUT")
 finally:cleanup()
 deadline=time.monotonic()+2400
 while time.monotonic()<deadline:
  check_pdb();x["scaleInNodes"]=names(nodes())
  if len(x["scaleInNodes"])<len(x["scaleOutNodes"]):break
  time.sleep(15)
 validate(x)
 x.update(schemaVersion="platform.mng-autoscaler-drill/v1",evidenceGrade="CLOUD_RUNTIME",decision="PASS",observationsSha256=hashlib.sha256(json.dumps(x,sort_keys=True).encode()).hexdigest())
 p=pathlib.Path(output);p.parent.mkdir(parents=True,exist_ok=True)
 with tempfile.NamedTemporaryFile("w",dir=p.parent,delete=False) as f:json.dump(x,f);tmp=f.name
 os.replace(tmp,p)
if __name__=="__main__":
 try:drill(*sys.argv[1:])
 except (ValueError,KeyError,TypeError,subprocess.SubprocessError,KeyboardInterrupt) as e:print(e,file=sys.stderr);sys.exit(1)
