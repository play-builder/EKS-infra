import copy,importlib.util,json,pathlib,subprocess,tempfile,unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location("review",ROOT/"scripts/lib/access-entry-review.py")
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
ARN="arn:aws:iam::123456789012:role/operator"
VIEW="arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
ADMIN="arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
def fixture():
 old=[{"address":"module.operator_access."+kind+".operator","type":kind,"values":{"principal_arn":ARN,"cluster_name":"prod"}} for kind in ["aws_eks_access_entry","aws_eks_access_policy_association"]]
 old[1]["values"].update(policy_arn=ADMIN,access_scope=[{"type":"cluster","namespaces":[]}])
 mapping=[{"oldAddress":r["address"],"newAddress":"module.access_entries."+r["type"]+'.this["platform-operator"]',"principalArn":ARN} for r in old]
 mapping[1].update(policyArn=VIEW,accessScope={"type":"namespace","namespaces":["app-prod","platform-system"]})
 planned=copy.deepcopy(old)
 for r,target in zip(planned,mapping):r["address"]=target["newAddress"]
 planned[1]["values"].update(policy_arn=VIEW,access_scope=[{"type":"namespace","namespaces":["platform-system","app-prod"]}])
 state={"values":{"root_module":{"child_modules":[{"resources":old}]}}}
 plan={"planned_values":{"root_module":{"child_modules":[{"resources":planned}]}},"resource_changes":[{"address":r["address"],"type":r["type"],"change":{"actions":["no-op"],"after":r["values"]}} for r in planned]}
 plan["resource_changes"][0]["change"]["before"]=copy.deepcopy(old[0]["values"])
 plan["resource_changes"][1]["change"].update(actions=["update"],before=copy.deepcopy(old[1]["values"]))
 return state,mapping,plan
def targets(plan):return plan["planned_values"]["root_module"]["child_modules"][0]["resources"]
class Migration(unittest.TestCase):
 def test_full_workflow_allows_reviewed_reduction(self):
  state,mapping,plan=fixture()
  with tempfile.TemporaryDirectory() as d:
   paths=[pathlib.Path(d)/n for n in ["old-state.json","mapping.json","plan.json"]]
   for p,v in zip(paths,[state,mapping,plan]):p.write_text(json.dumps(v))
   result=subprocess.run(["bash",str(ROOT/"scripts/access-entry-review.sh"),*map(str,paths)],capture_output=True,text=True)
   self.assertEqual(result.returncode,0,result.stderr);self.assertIn("PASS",result.stdout)
 def test_rejects_unbound_planned_resources(self):
  mutations=[lambda p:p.pop("planned_values"),lambda p:p.update(planned_values={"root_module":{"resources":[]}}),lambda p:targets(p).pop(),lambda p:targets(p)[0]["values"].update(principal_arn="arn:aws:iam::123456789012:role/unrelated"),lambda p:targets(p)[1]["values"].update(principal_arn="arn:aws:iam::123456789012:role/unrelated"),lambda p:targets(p)[0]["values"].update(cluster_name="wrong"),lambda p:targets(p)[1]["values"].update(cluster_name="wrong"),lambda p:targets(p)[0].update(address='module.access_entries.aws_eks_access_entry.this["developer-readonly"]'),lambda p:targets(p)[1]["values"].update(policy_arn=ADMIN),lambda p:targets(p)[1]["values"].update(access_scope=[{"type":"cluster","namespaces":[]}]),lambda p:targets(p)[1]["values"].update(access_scope=[{"type":"namespace","namespaces":["other"]}]),lambda p:targets(p).append(copy.deepcopy(targets(p)[0])),lambda p:targets(p)[0].update(type="aws_eks_access_policy_association")]
  for i,mutate in enumerate(mutations):
   with self.subTest(case=i):
    state,mapping,plan=fixture();mutate(plan)
    with self.assertRaises(ValueError):m.validate(state,mapping,plan)
 def test_rejects_unreviewed_or_incomplete_mappings(self):
  mutations=[lambda x:x.pop(),lambda x:x.append(copy.deepcopy(x[0])),lambda x:x[0].update(principalArn="wrong"),lambda x:x[1].pop("policyArn"),lambda x:x[1].pop("accessScope"),lambda x:x[1].update(newAddress='module.access_entries.aws_eks_access_policy_association.this["developer-readonly"]')]
  for i,mutate in enumerate(mutations):
   with self.subTest(case=i):
    state,mapping,plan=fixture();mutate(mapping)
    with self.assertRaises(ValueError):m.validate(state,mapping,plan)
 def test_rejects_create_delete_even_with_valid_targets(self):
  for actions in [["create"],["delete"],["delete","create"]]:
   state,mapping,plan=fixture();plan["resource_changes"][0]["change"]["actions"]=actions
   with self.assertRaisesRegex(ValueError,"MIGRATION_ACCESS_REPLACEMENT"):m.validate(state,mapping,plan)
 def test_rejects_duplicated_old_state_addresses(self):
  state,mapping,plan=fixture()
  old=state["values"]["root_module"]["child_modules"][0]["resources"]
  old.append(copy.deepcopy(old[0]))
  with self.assertRaises(ValueError):m.validate(state,mapping,plan)
 def test_rejects_old_noop_plan_instead_of_migrated_plan(self):
  state,mapping,plan=fixture()
  plan["planned_values"]=copy.deepcopy(state["values"])
  plan["resource_changes"]=[]
  with self.assertRaises(ValueError):m.validate(state,mapping,plan)
if __name__=="__main__":unittest.main()
