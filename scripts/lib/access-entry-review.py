#!/usr/bin/env python3
"""Validate operator-supplied exact state mapping and a saved plan. Never mutate state."""
import json,pathlib,re,sys
KINDS={"aws_eks_access_entry","aws_eks_access_policy_association"}
def require(v,c):
 if not v:raise ValueError(c)
def resources(m):
 yield from m.get("resources",[])
 for child in m.get("child_modules",[]):yield from resources(child)
def access_scope(value):
 require(isinstance(value,dict) and value.get("type") in {"cluster","namespace"},"MIGRATION_INVALID_SCOPE")
 namespaces=value.get("namespaces") or []
 require(isinstance(namespaces,list) and all(isinstance(n,str) and re.fullmatch(r"[a-z0-9][a-z0-9-]*",n) for n in namespaces),"MIGRATION_INVALID_SCOPE")
 require(len(set(namespaces))==len(namespaces) and bool(namespaces)==(value["type"]=="namespace"),"MIGRATION_INVALID_SCOPE")
 return value["type"],frozenset(namespaces)
def validate(state,mapping,plan):
 old_list=[r for r in resources(state["values"]["root_module"]) if r["type"] in KINDS]
 old={r["address"]:r for r in old_list}
 require(len(old)==len(old_list),"MIGRATION_DUPLICATE_ADDRESS")
 require(old,"MIGRATION_UNMAPPED_RESOURCES")
 require(len(mapping)==len(old),"MIGRATION_UNMAPPED_RESOURCES")
 require(len({m["oldAddress"] for m in mapping})==len(mapping) and len({m["newAddress"] for m in mapping})==len(mapping),"MIGRATION_DUPLICATE_ADDRESS")
 require(set(old)=={m["oldAddress"] for m in mapping},"MIGRATION_UNMAPPED_RESOURCES")
 planned_list=[r for r in resources(plan.get("planned_values",{}).get("root_module",{})) if r["type"] in KINDS]
 planned={r["address"]:r for r in planned_list}
 require(len(planned)==len(planned_list) and set(planned)=={m["newAddress"] for m in mapping},"MIGRATION_PLANNED_TARGET_SET_MISMATCH")
 targets={}
 for m in mapping:
  r=old[m["oldAddress"]]
  require(m["principalArn"]==r["values"]["principal_arn"],"MIGRATION_PRINCIPAL_MISMATCH")
  match=re.fullmatch(r'module\.access_entries\.'+re.escape(r["type"])+r'\.this\["(platform-break-glass|platform-operator|release-automation|developer-readonly)"\]',m["newAddress"])
  require(match,"MIGRATION_INVALID_TARGET")
  target=planned[m["newAddress"]];values=target.get("values") or {}
  require(target["type"]==r["type"],"MIGRATION_PLANNED_TYPE_MISMATCH")
  require(values.get("principal_arn")==m["principalArn"],"MIGRATION_PLANNED_PRINCIPAL_MISMATCH")
  cluster=r["values"].get("cluster_name")
  require(isinstance(cluster,str) and cluster and values.get("cluster_name")==cluster,"MIGRATION_CLUSTER_MISMATCH")
  if r["type"]=="aws_eks_access_policy_association":
   require(isinstance(m.get("policyArn"),str) and m["policyArn"] and values.get("policy_arn")==m["policyArn"],"MIGRATION_POLICY_MISMATCH")
   scopes=values.get("access_scope")
   require(isinstance(scopes,list) and len(scopes)==1,"MIGRATION_INVALID_SCOPE")
   require(access_scope(m.get("accessScope"))==access_scope(scopes[0]),"MIGRATION_SCOPE_MISMATCH")
  pair=(r["type"],m["principalArn"],cluster);require(pair not in targets,"MIGRATION_DUPLICATE_PRINCIPAL");targets[pair]=match[1]
 for (kind,arn,cluster),key in targets.items():
  other="aws_eks_access_policy_association" if kind=="aws_eks_access_entry" else "aws_eks_access_entry"
  require(targets.get((other,arn,cluster))==key,"MIGRATION_MISSING_ENTRY_POLICY_PAIR")
 for r in plan.get("resource_changes",[]):
  if r["type"] in KINDS:require(not set(r["change"]["actions"]) & {"create","delete"},"MIGRATION_ACCESS_REPLACEMENT")
if __name__=="__main__":
 try:
  validate(*[json.loads(pathlib.Path(p).read_text()) for p in sys.argv[1:]])
  print("PASS: exact local migration mapping; live migration not performed")
 except (ValueError,KeyError,TypeError) as e:print(e,file=sys.stderr);sys.exit(1)
