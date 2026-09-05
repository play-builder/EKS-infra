import json
import pathlib
import re
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
for env in ("dev", "prod"):
    source = (root / f"environments/{env}/04-workloads/argocd/main.tf").read_text()
    start = source.index('resource "terraform_data" "course_ownership"')
    end = source.index("\n}\n", start) + 3
    block = source[start:end].replace("local.course_ownership", '"fixture"')
    with tempfile.TemporaryDirectory(prefix="ownership-destroy-") as directory:
        work = pathlib.Path(directory)
        (work / "main.tf").write_text(block)
        (work / "terraform.tfstate").write_text(json.dumps({
            "version": 4, "terraform_version": "1.16.0", "serial": 1,
            "lineage": "00000000-0000-0000-0000-000000000001", "outputs": {},
            "resources": [{"mode": "managed", "type": "terraform_data", "name": "course_ownership",
                "provider": 'provider["terraform.io/builtin/terraform"]',
                "instances": [{"schema_version": 0, "attributes": {"id": "fixture",
                    "input": {"value": "fixture", "type": "string"},
                    "output": {"value": "fixture", "type": "string"},
                    "triggers_replace": None}, "sensitive_attributes": []}]}]}))
        subprocess.run(["terraform", "-chdir=" + directory, "init", "-backend=false", "-input=false"], check=True, capture_output=True)
        result = subprocess.run(["terraform", "-chdir=" + directory, "plan", "-destroy", "-refresh=false", "-input=false", "-no-color"],
                                text=True, capture_output=True)
        assert result.returncode == 0, result.stdout + result.stderr
        assert "1 to destroy" in result.stdout
print("PASS: actual local Terraform destroy planning removes metadata markers; no apply or external provider")
