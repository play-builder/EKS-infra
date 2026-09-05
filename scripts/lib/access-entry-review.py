#!/usr/bin/env python3
"""Validate operator-supplied exact state mapping and a saved plan. Never mutate state."""
import json,pathlib,re,sys
KINDS={"aws_eks_access_entry","aws_eks_access_policy_association"}
def require(v,c):
 if not v:raise ValueError(c)
def resources(m):
 yield from m.get("resources",[])
 for child in m.get("child_modules",[]):yield from resources(child)
def validate(state,mapping,plan):
 old={r["address"]:r for r in resources(state["values"]["root_module"]) if r["type"] in KINDS}
 require(len(mapping)==len(old),"MIGRATION_UNMAPPED_RESOURCES")
 require(len({m["oldAddress"] for m in mapping})==len(mapping) and len({m["newAddress"] for m in mapping})==len(mapping),"MIGRATION_DUPLICATE_ADDRESS")
 require(set(old)=={m["oldAddress"] for m in mapping},"MIGRATION_UNMAPPED_RESOURCES")
 targets={}
 for m in mapping:
  r=old[m["oldAddress"]]
  require(m["principalArn"]==r["values"]["principal_arn"],"MIGRATION_PRINCIPAL_MISMATCH")
  match=re.fullmatch(r'module.access_entries.'+re.escape(r["type"])+r'.this\["(platform-break-glass|platform-operator|release-automation|developer-readonly)"\]',m["newAddress"])
  require(match,"MIGRATION_INVALID_TARGET")
  pair=(r["type"],m["principalArn"]);require(pair not in targets,"MIGRATION_DUPLICATE_PRINCIPAL");targets[pair]=match[1]
 for (kind,arn),key in targets.items():
  other="aws_eks_access_policy_association" if kind=="aws_eks_access_entry" else "aws_eks_access_entry"
  require(targets.get((other,arn))==key,"MIGRATION_MISSING_ENTRY_POLICY_PAIR")
 for r in plan.get("resource_changes",[]):
  if r["type"] in KINDS:require(not set(r["change"]["actions"]) & {"create","delete"},"MIGRATION_ACCESS_REPLACEMENT")
if __name__=="__main__":
 try:
  validate(*[json.loads(pathlib.Path(p).read_text()) for p in sys.argv[1:]])
  print("PASS: exact local migration mapping; live migration not performed")
 except (ValueError,KeyError,TypeError) as e:print(e,file=sys.stderr);sys.exit(1)
