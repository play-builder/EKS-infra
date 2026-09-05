import importlib.util,pathlib,unittest
class SupplyChain(unittest.TestCase):
 def test_scanning_and_handoff(self):
  s=importlib.util.spec_from_file_location("s",pathlib.Path(__file__).resolve().parents[1]/"scripts/lib/supply-chain-check.py");m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
  config={"scanningConfiguration":{"scanType":"ENHANCED","rules":[{"scanFrequency":"CONTINUOUS_SCAN","repositoryFilters":[{"filter":"playdevops/sample-app*","filterType":"WILDCARD"},{"filter":"playdevops/mini-commerce*","filterType":"WILDCARD"}]}]}}
  m.validate_scanning(config,["playdevops/sample-app","playdevops/mini-commerce"])
  for bad in [{"scanningConfiguration":{"scanType":"BASIC","rules":[]}},{"scanningConfiguration":{"scanType":"ENHANCED","rules":[]}}]:
   with self.assertRaises(ValueError):m.validate_scanning(bad,["playdevops/mini-commerce"])
  m.validate_handoff({"resource_changes":[]})
  with self.assertRaises(ValueError):m.validate_handoff({"resource_changes":[{"type":"aws_ecr_registry_scanning_configuration","change":{"actions":["delete"]}}]})
 def test_digest_and_admission(self):
  s=importlib.util.spec_from_file_location("s",pathlib.Path(__file__).resolve().parents[1]/"scripts/lib/supply-chain-check.py");m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
  m.validate_admission("registry.example/repo@sha256:"+"a"*64,"registry.example/repo@sha256:"+"b"*64,0,1,'admission webhook "policy.sigstore.dev" denied the request')
  for args in [("repo:latest","repo:latest",0,1,"denied"),("repo@sha256:"+"a"*64,"repo@sha256:"+"b"*64,0,0,""),("repo@sha256:"+"a"*64,"repo@sha256:"+"b"*64,0,1,"Forbidden")]:
   with self.assertRaises(ValueError):m.validate_admission(*args)
if __name__=="__main__":unittest.main()
