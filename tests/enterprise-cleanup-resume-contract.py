"""Exercise the actual RC resume engine with ten enterprise fixture plans."""
import hashlib
import json
import os
import pathlib
import re
import subprocess
import tempfile

root=pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="enterprise-resume-") as directory:
    work=pathlib.Path(directory)
    (work/"evidence").mkdir()
    setup='set -euo pipefail; source "$1/tests/cleanup-fixture-helpers.sh"; prepare_cleanup_fixtures "$1" "$2/evidence" ap-northeast-2; prepare_saved_plan_manifest "$2/plans" "$2/manifest.json"; prepare_realistic_destroy_plan_jsons "$2/json"'
    subprocess.run(["bash","-c",setup,"fixture",str(root),str(work)],check=True)
    manifest=json.loads((work/"manifest.json").read_text())
    inventory=json.loads((work/"evidence/inventory.json").read_text())
    added=[]
    for env in ("recovery","prod"):
        layer=f"environments/{env}/03-database"
        arn=f"arn:aws:rds:ap-northeast-2:123456789012:db:{env}-commerce"
        snapshot=f"{env}-commerce-final"
        entry={"kind":"RdsInstance","id":arn,"decision":"DELETE","environment":env,"owner":"course","managedBy":"terraform","classification":"database","billable":True,"reason":"","followUpAction":""}
        inventory["resources"].append(entry)
        inventory["resources"].append({**entry,"kind":"RdsSnapshot","id":f"arn:aws:rds:ap-northeast-2:123456789012:snapshot:{snapshot}","decision":"RETAIN","reason":"approved final snapshot","followUpAction":"operator retention review"})
        binary=work/"plans"/(layer.replace("/","__")+".tfplan")
        binary.write_bytes(("fixture binary "+layer).encode())
        added.append({"layer":layer,"path":str(binary),"sha256":hashlib.sha256(binary.read_bytes()).hexdigest()})
        plan={"format_version":"1.2","resource_changes":[{"address":"module.database.aws_db_instance.this","mode":"managed","type":"aws_db_instance","change":{"actions":["delete"],"before":{"arn":arn,"deletion_protection":False,"skip_final_snapshot":False,"final_snapshot_identifier":snapshot,"tags_all":{"CourseId":"course-2026","Project":"playdevops","Environment":"prod","Layer":"recovery-database" if env=="recovery" else "database","ManagedBy":"Terraform"}}}}]}
        (work/"json"/(layer.replace("/","__")+".json")).write_text(json.dumps(plan))
    inventory["resources"].sort(key=lambda x:(x["kind"],x["id"]))
    (work/"evidence/inventory.json").write_text(json.dumps(inventory))
    manifest["plans"][2:2]=added
    (work/"manifest.json").write_text(json.dumps(manifest))
    (work/"bin").mkdir()
    fake=work/"bin/terraform"
    fake.write_text('#!/usr/bin/env python3\nimport os,pathlib,sys\nlayer=sys.argv[1].split(os.environ["TEST_REPO"]+"/",1)[1]\nif sys.argv[2:4]==["show","-json"]: print((pathlib.Path(os.environ["TEST_WORK"])/"json"/(layer.replace("/","__")+".json")).read_text())\nelif sys.argv[2]=="apply": pass\nelse: raise SystemExit(97)\n')
    fake.chmod(0o755)
    env={**os.environ,"PATH":str(work/"bin")+":"+os.environ["PATH"],"TEST_WORK":str(work),"TEST_REPO":str(root),"COURSE_CHECK_BIN_DIR":str(work/"bin")}
    script='source "$1/scripts/lib/evidence-common.sh"; source "$1/scripts/lib/cleanup-evidence.sh"; cleanup_apply_saved_plans "$2/manifest.json" "$1" "$2/evidence/inventory.json" "$2/progress.json" playdevops'
    # A retained live DB must reject the whole sequence before any progress is created.
    inventory["resources"][next(i for i,x in enumerate(inventory["resources"]) if x["kind"]=="RdsInstance")]["decision"]="RETAIN"
    (work/"evidence/inventory.json").write_text(json.dumps(inventory))
    result=subprocess.run(["bash","-c",script,"fixture",str(root),str(work)],env=env,capture_output=True,text=True)
    assert result.returncode!=0 and "RETAINED_DATABASE_BLOCKS_NETWORK_TEARDOWN" in result.stderr,result.stderr
    assert not (work/"progress.json").exists()
    for entry in inventory["resources"]:
        if entry["kind"]=="RdsInstance": entry["decision"]="DELETE"
    (work/"evidence/inventory.json").write_text(json.dumps(inventory))
    result=subprocess.run(["bash","-c",script,"fixture",str(root),str(work)],env=env,capture_output=True,text=True)
    assert result.returncode==0,result.stderr
    progress=json.loads((work/"progress.json").read_text())
    assert progress["status"]=="COMPLETE" and len(progress["completed"])==10
    assert [x["layer"] for x in progress["completed"]][2:4]==["environments/recovery/03-database","environments/prod/03-database"]
    assert all(not pathlib.Path(x["path"]).exists() for x in manifest["plans"])
print("PASS: ten-root enterprise cleanup uses RC progress, rejects retained DB, and removes completed fixture binaries")

# Missing real module addresses must not block the destructive-plan gate. Derive the resource
# declarations from the local Terraform producer, but exercise the actual shell/JSON guard.
with tempfile.TemporaryDirectory(prefix="enterprise-addresses-") as directory:
    work = pathlib.Path(directory)
    (work / "bin").mkdir()
    fake = work / "bin/terraform"
    fake.write_text('#!/usr/bin/env python3\nimport os,pathlib,sys\nassert sys.argv[2:4]==["show","-json"]\nprint(pathlib.Path(os.environ["ADDRESS_PLAN"]).read_text())\n')
    fake.chmod(0o755)
    env = {**os.environ, "PATH": str(work / "bin") + ":" + os.environ["PATH"], "ADDRESS_PLAN": str(work / "plan.json")}
    inventory = json.loads((root / "tests/fixtures/cleanup-ownership-valid.json").read_text())
    (work / "inventory.json").write_text(json.dumps(inventory))
    script = 'set -euo pipefail; source "$1/scripts/lib/evidence-common.sh"; source "$1/scripts/lib/cleanup-evidence.sh"; cleanup_inspect_saved_destroy_plan "$3" "$2/binary.tfplan" "$2/inventory.json" "$1" course-2026 123456789012 ap-northeast-2 playdevops'

    def inspect(layer, address, resource_type, before=None):
        environment = layer.split("/")[1]
        semantic = "eks" if layer.endswith("02-eks") else "platform" if layer.endswith("03-platform") else "workloads"
        values = {"id": "fixture-resource", "tags_all": {"CourseId": "course-2026", "Project": "playdevops", "Environment": environment, "Layer": semantic, "ManagedBy": "Terraform"}} if before is None else before
        plan = {"format_version": "1.2", "resource_changes": [{"address": address, "mode": "managed", "type": resource_type, "change": {"actions": ["delete"], "before": values}}]}
        (work / "plan.json").write_text(json.dumps(plan))
        return subprocess.run(["bash", "-c", script, "fixture", str(root), str(work), layer], env=env, capture_output=True, text=True)

    tested = 0
    for environment in ("dev", "prod"):
        modules = {"managed_addons": "modules/eks/managed-addons", "access_entries": "modules/eks/access-entries"}
        if environment == "prod":
            modules["operator_access"] = "modules/compute/operator-access"
        for module_name, source in modules.items():
            declarations = re.findall(r'^resource "([^"]+)" "([^"]+)"', (root / source / "main.tf").read_text(), re.M)
            assert declarations
            for resource_type, name in declarations:
                suffix = '["platform-operator"]' if module_name == "access_entries" else ""
                address = f"module.{module_name}.{resource_type}.{name}{suffix}"
                untagged = resource_type in ("aws_iam_role_policy", "aws_iam_role_policy_attachment", "aws_eks_access_policy_association")
                result = inspect(f"environments/{environment}/02-eks", address, resource_type, {"id": "fixture-resource"} if untagged else None)
                assert result.returncode == 0 and result.stdout.strip() == "DELETE", (address, result.stderr)
                tested += 1
        result = inspect(f"environments/{environment}/02-eks", "terraform_data.logging_identity", "terraform_data", {"id": "local-marker", "input": f"{environment}-playdevops-eks"})
        assert result.returncode == 0, result.stderr

        # Enterprise modules in adjacent roots were already allowed; retain their actual producers.
        for layer, address, resource_type, before in [
            ("03-platform", "terraform_data.logging_identity", "terraform_data", {"id": "local-marker", "input": {}}),
            ("03-platform", "module.sigstore_policy_controller.helm_release.policy_controller", "helm_release", {"id": "policy-controller"}),
            ("03-platform", 'module.mini_commerce_secrets.aws_secretsmanager_secret.this["database"]', "aws_secretsmanager_secret", None),
            ("04-workloads/argocd", "module.argocd.helm_release.argocd", "helm_release", {"id": "argocd"}),
        ]:
            result = inspect(f"environments/{environment}/{layer}", address, resource_type, before)
            assert result.returncode == 0, (address, result.stderr)

    for layer, address, resource_type in [
        ("environments/unknown/02-eks", "module.managed_addons.aws_eks_addon.coredns", "aws_eks_addon"),
        ("environments/dev/02-eks", "module.operator_access.aws_instance.operator", "aws_instance"),
        ("environments/prod/03-platform", "module.operator_access.aws_instance.operator", "aws_instance"),
        ("environments/prod/02-eks", "module.unknown.aws_eks_addon.coredns", "aws_eks_addon"),
        ("environments/prod/02-eks", "module.managed_addons.aws_unknown.coredns", "aws_unknown"),
        ("environments/prod/02-eks", "module.managed_addons.aws_eks_addon.unknown", "aws_eks_addon"),
        ("environments/prod/02-eks", "module.operator_access.aws_s3_bucket.unknown", "aws_s3_bucket"),
        ("environments/prod/02-eks", "module.managed_addons.aws_eks_addon.coredns", "helm_release"),
        ("environments/prod/02-eks", "terraform_data.unknown", "terraform_data"),
        ("environments/prod/02-eks", "module.operator_access.aws_kms_key.this", "aws_kms_key"),
    ]:
        result = inspect(layer, address, resource_type)
        assert result.returncode != 0, (layer, address, "unexpected DELETE")
    wrong_owner = {"id": "fixture-resource", "tags_all": {"CourseId": "foreign", "Project": "playdevops", "Environment": "prod", "Layer": "eks", "ManagedBy": "Terraform"}}
    assert inspect("environments/prod/02-eks", "module.managed_addons.aws_eks_addon.coredns", "aws_eks_addon", wrong_owner).returncode != 0
    inventory["resources"].append({"kind": "EksCluster", "id": "fixture-resource", "environment": "prod", "decision": "RETAIN", "owner": "course", "managedBy": "terraform"})
    (work / "inventory.json").write_text(json.dumps(inventory))
    assert inspect("environments/prod/02-eks", "module.managed_addons.aws_eks_addon.coredns", "aws_eks_addon").returncode != 0
    print(f"PASS: {tested} declared EKS module resources, root markers and adjacent enterprise addresses; unknown scope/type and foreign ownership rejected")
