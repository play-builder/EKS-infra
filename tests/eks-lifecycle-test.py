import copy, datetime, json, pathlib, subprocess, tempfile, unittest
ROOT = pathlib.Path(__file__).resolve().parents[1]
class Lifecycle(unittest.TestCase):
 def fixture(self):
  return {"cluster":"fixture","region":"ap-northeast-2","fromVersion":"1.35","toVersion":"1.36","observedAt":datetime.datetime.now(datetime.timezone.utc).isoformat(),"refresh":{"status":"COMPLETED","startedAt":datetime.datetime.now(datetime.timezone.utc).isoformat(),"endedAt":datetime.datetime.now(datetime.timezone.utc).isoformat()},"insights":[{"id":"i","kubernetesVersion":"1.36","insightStatus":{"status":"PASSING"}}],"details":[{"insight":{"id":"i","insightStatus":{"status":"PASSING"},"resources":[]}}],"nodes":{"items":[{"metadata":{"name":"node"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]},"pdbs":{"items":[{"status":{"disruptionsAllowed":1}}]},"addons":{"coredns":"v1.0.0-eksbuild.1","kube-proxy":"v1.36.0-eksbuild.1","vpc-cni":"v1.0.0-eksbuild.1","aws-ebs-csi-driver":"v1.0.0-eksbuild.1","snapshot-controller":"v1.0.0-eksbuild.1"},"controllers":{"items":[{"metadata":{"name":n},"spec":{"template":{"spec":{"containers":[{"image":"fixture@sha256:"+"a"*64}]}}}} for n in ["cluster-autoscaler","argocd-server","argo-rollouts","external-secrets","adot-collector","istiod"]]},"nodegroup":{"status":"ACTIVE","releaseVersion":"1.36.0-20260901","health":{"issues":[]}},"expectedRelease":"1.36.0-20260901"}
 def check(self,data,ok):
  with tempfile.TemporaryDirectory() as d:
   p=pathlib.Path(d)/"input.json"; p.write_text(json.dumps(data))
   r=subprocess.run(["python3",str(ROOT/"scripts/lib/eks-lifecycle.py"),"validate",str(p)],capture_output=True,text=True)
   self.assertEqual(r.returncode==0,ok,r.stdout+r.stderr)
 def test_valid(self): self.check(self.fixture(),True)
 def test_fail_closed(self):
  for mutate in [
   lambda x:x["refresh"].update(status="FAILED"),
   lambda x:x["insights"][0]["insightStatus"].update(status="UNKNOWN"),
   lambda x:x.update(insights=[]),
   lambda x:x.update(observedAt="2020-01-01T00:00:00Z"),
   lambda x:x["refresh"].update(endedAt="2020-01-01T00:00:00Z"),
   lambda x:x["nodes"]["items"][0]["status"]["conditions"][0].update(status="False"),
   lambda x:x["pdbs"]["items"][0]["status"].update(disruptionsAllowed=0),
   lambda x:x["nodegroup"].update(releaseVersion="wrong"),
   lambda x:x["controllers"].update(items=[]),
   lambda x:x["addons"].pop("coredns"),
   lambda x:x["details"][0]["insight"].update(resources=[{"insightStatus":{"status":"ERROR"}}]),
  ]:
   x=self.fixture(); mutate(x)
   with self.subTest(data=x): self.check(x,False)
if __name__=="__main__": unittest.main()
