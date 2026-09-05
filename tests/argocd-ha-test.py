import importlib.util,pathlib,unittest
class Argo(unittest.TestCase):
 def test_ha_observations(self):
  s=importlib.util.spec_from_file_location("a",pathlib.Path(__file__).resolve().parents[1]/"scripts/lib/argocd-ha-check.py");m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
  x={"components":{n:{"ready":2,"desired":2,"nodes":["a","b"],"zones":["a","b"]} for n in ["argocd-server","argocd-repo-server","argocd-application-controller","argocd-applicationset-controller"]},"redisReady":3,"pdbs":[1,1,1,1],"externalSecretsReady":3,"rbac":{"readonlyGet":True,"readonlyDelete":False,"adminSync":True},"secretMetadataHashes":["a","b","c"]}
  m.validate(x)
  for mutate in [lambda y:y["components"]["argocd-server"].update(ready=1),lambda y:y["components"]["argocd-server"].update(zones=["a","a"]),lambda y:y.update(pdbs=[0]),lambda y:y.update(externalSecretsReady=2),lambda y:y["rbac"].update(readonlyDelete=True)]:
   import copy
   y=copy.deepcopy(x);mutate(y)
   with self.assertRaises(ValueError):m.validate(y)
if __name__=="__main__":unittest.main()
