"""Exercise the actual RC resume engine with ten enterprise fixture plans."""
import hashlib
import json
import os
import pathlib
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
