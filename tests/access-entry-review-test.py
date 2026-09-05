import importlib.util,pathlib,unittest
class Migration(unittest.TestCase):
 def test_exact_mapping(self):
  s=importlib.util.spec_from_file_location("review",pathlib.Path(__file__).resolve().parents[1]/"scripts/lib/access-entry-review.py");m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
  arn="arn:aws:iam::123456789012:role/operator"
  resources=[{"address":"module.operator_access.aws_eks_access_entry.operator","type":"aws_eks_access_entry","values":{"principal_arn":arn}},{"address":"module.operator_access.aws_eks_access_policy_association.operator","type":"aws_eks_access_policy_association","values":{"principal_arn":arn}}]
  state={"values":{"root_module":{"resources":resources}}}
  mapping=[{"oldAddress":r["address"],"newAddress":"module.access_entries."+r["type"]+'.this["platform-operator"]',"principalArn":arn} for r in resources]
  m.validate(state,mapping,{"resource_changes":[]})
  for bad in [mapping[:1],mapping+mapping[:1],[dict(mapping[0],principalArn="wrong"),mapping[1]]]:
   with self.assertRaises(ValueError):m.validate(state,bad,{"resource_changes":[]})
  with self.assertRaises(ValueError):m.validate(state,mapping,{"resource_changes":[{"type":"aws_eks_access_entry","change":{"actions":["delete","create"]}}]})
if __name__=="__main__":unittest.main()
