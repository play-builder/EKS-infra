"""Compile real root/module configuration with local state; never plan/apply AWS."""
import os
import pathlib
import re
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
for env in ("dev", "prod"):
    source = root / f"environments/{env}/01-network"
    with tempfile.TemporaryDirectory(prefix="log-key-graph-") as directory:
        work = pathlib.Path(directory)
        for path in source.glob("*.tf"):
            if path.name == "backend.tf":
                continue
            content = re.sub(r'(source\s*=\s*")([.][.]/[^"\n]+)(")',
                             lambda m: m[1] + str((source / m[2]).resolve()) + m[3], path.read_text())
            (work / path.name).write_text(content)
        (work / ".terraform.lock.hcl").write_bytes((source / ".terraform.lock.hcl").read_bytes())
        providers = os.environ.get("TF_GRAPH_PROVIDER_DIR", str(source / ".terraform/providers"))
        subprocess.run(["terraform", "-chdir=" + directory, "init", "-backend=false", "-input=false",
                        "-lockfile=readonly", "-plugin-dir=" + providers], check=True, capture_output=True)
        result = subprocess.run(["terraform", "-chdir=" + directory, "graph"], check=True, text=True, capture_output=True)
        assert '"module.vpc.aws_cloudwatch_log_group.vpc_flow" -> "module.log_key.aws_kms_key.this"' in result.stdout, result.stdout
print("PASS: real Terraform network graph binds Flow Log Group to log KMS key; destroy reverses this dependency")
