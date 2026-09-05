import importlib.util,json,os,pathlib,subprocess,sys,tempfile,unittest

CLI = '''#!/usr/bin/env python3
import json,os,pathlib,sys
data=json.loads(pathlib.Path(os.environ["ARGO_FIXTURE"]).read_text())
tool=pathlib.Path(sys.argv[0]).name;args=sys.argv[1:]
if tool=="argocd":
 group,verb=args[4:6]
 assert args[:4]==["admin","settings","rbac","can"]
 assert args[6:]==["applications","*/*","--namespace","argocd"]
 decision=data["decisions"][group+":"+verb]
 sys.stdout.write(decision[1]);sys.stderr.write(decision[2]);sys.exit(decision[0])
if tool=="aws": result={"cluster":{"endpoint":"https://fixture","arn":"arn:aws:eks:ap-northeast-2:123456789012:cluster/fixture"}}
elif args[:2]==["config","view"]: result={"clusters":[{"cluster":{"server":"https://fixture"}}]}
elif args[:2]==["get","nodes"]: result=data["nodes"]
elif args[:4]==["-n","argocd","get","secret"]:
 assert args[-1]=="jsonpath={.metadata.uid}/{.metadata.resourceVersion}"
 print("uid/123");sys.exit(0)
else:
 assert args[:3]==["-n","argocd","get"]
 result=data[args[3]]
print(json.dumps(result))
'''

def collection_fixture():
 names=["argocd-server","argocd-repo-server","argocd-application-controller","argocd-applicationset-controller"]
 objects=[];pods=[]
 for name in names:
  objects.append({"kind":"Deployment","metadata":{"name":name},"spec":{"replicas":2,"selector":{"matchLabels":{"app":name}}},"status":{"readyReplicas":2}})
  objects.append({"kind":"PodDisruptionBudget","metadata":{"name":name},"status":{"disruptionsAllowed":1}})
  pods.extend({"metadata":{"labels":{"app":name}},"spec":{"nodeName":n},"status":{"conditions":[{"type":"Ready","status":"True"}]}} for n in ["node-a","node-b"])
 objects.append({"kind":"StatefulSet","metadata":{"name":"argocd-redis-ha-server"},"status":{"readyReplicas":3}})
 return {"deploy,statefulset,pdb":{"items":objects},"pods":{"items":pods},"nodes":{"items":[{"metadata":{"name":n,"labels":{"topology.kubernetes.io/zone":z}}} for n,z in [("node-a","zone-a"),("node-b","zone-b")]]},"externalsecrets":{"items":[{"spec":{"target":{"name":n}},"status":{"refreshTime":"2026-09-05T00:00:00Z","conditions":[{"type":"Ready","status":"True"}]}} for n in ["argocd-oidc","argocd-notifications-secret","argocd-repository-credentials"]]},"decisions":{"readonly:get":[0,"Yes\n",""],"readonly:delete":[1,"No\n",""],"admin:sync":[0,"Yes\n",""]}}

class Argo(unittest.TestCase):
 def collect(self,decisions):
  with tempfile.TemporaryDirectory() as d:
   root=pathlib.Path(d);cli=root/"fixture-cli";cli.write_text(CLI);cli.chmod(0o755)
   for name in ["aws","kubectl","argocd"]:(root/name).symlink_to(cli)
   fixture=collection_fixture();fixture["decisions"].update(decisions)
   (root/"fixture.json").write_text(json.dumps(fixture));output=root/"evidence.json"
   result=subprocess.run([sys.executable,str(pathlib.Path(__file__).resolve().parents[1]/"scripts/lib/argocd-ha-check.py"),"fixture","ap-northeast-2","readonly","admin",str(output)],capture_output=True,text=True,env={**os.environ,"PATH":str(root)+os.pathsep+os.environ["PATH"],"ARGO_FIXTURE":str(root/"fixture.json")})
   return result,json.loads(output.read_text()) if output.exists() else None
 def test_collector_accepts_expected_cli_deny(self):
  result,evidence=self.collect({})
  self.assertEqual(result.returncode,0,result.stderr)
  self.assertEqual(evidence["decision"],"PASS")
  self.assertEqual(evidence["rbac"],{"readonlyGet":True,"readonlyDelete":False,"adminSync":True})
 def test_collector_rejects_cli_errors_and_unexpected_pairs(self):
  for decision in [[1,"","API unavailable"],[1,"No\n","configuration error"],[2,"No\n",""],[0,"No\n",""],[1,"Yes\n",""],[0,"unexpected\n",""],[0,"Yes\n","unexpected warning"]]:
   with self.subTest(decision=decision):
    result,evidence=self.collect({"readonly:delete":decision})
    self.assertNotEqual(result.returncode,0)
    self.assertIn("ARGO_RBAC_COMMAND_FAILED",result.stderr)
    self.assertIsNone(evidence)
 def test_collector_rejects_actual_policy_misconfiguration(self):
  for key,decision in [("readonly:delete",[0,"Yes\n",""]),("readonly:get",[1,"No\n",""]),("admin:sync",[1,"No\n",""])]:
   with self.subTest(key=key):
    result,evidence=self.collect({key:decision})
    self.assertNotEqual(result.returncode,0)
    self.assertIn("ARGO_RBAC_DENIED",result.stderr)
    self.assertIsNone(evidence)
 def test_ha_observations(self):
  s=importlib.util.spec_from_file_location("a",pathlib.Path(__file__).resolve().parents[1]/"scripts/lib/argocd-ha-check.py");m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
  x={"components":{n:{"ready":2,"desired":2,"nodes":["a","b"],"zones":["a","b"]} for n in ["argocd-server","argocd-repo-server","argocd-application-controller","argocd-applicationset-controller"]},"redisReady":3,"pdbs":[1,1,1,1],"externalSecretsReady":3,"rbac":{"readonlyGet":True,"readonlyDelete":False,"adminSync":True},"secretMetadataHashes":["a","b","c"]}
  m.validate(x)
  for mutate in [lambda y:y["components"]["argocd-server"].update(ready=1),lambda y:y["components"]["argocd-server"].update(zones=["a","a"]),lambda y:y.update(pdbs=[0]),lambda y:y.update(externalSecretsReady=2),lambda y:y["rbac"].update(readonlyDelete=True)]:
   import copy
   y=copy.deepcopy(x);mutate(y)
   with self.assertRaises(ValueError):m.validate(y)
if __name__=="__main__":unittest.main()
