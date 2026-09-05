#!/usr/bin/env python3
"""Evaluate the actual Terraform provider YAML with real Prometheus fixtures."""
import json, os, pathlib, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parents[1]
result = subprocess.run(["terraform", "-chdir=" + str(root / "modules/addons/amp-alerting"), "test", "-filter=tests/enterprise-slo.tftest.hcl", "-json", "-verbose"], capture_output=True, text=True, check=True)
states = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
state = next(e["test_state"] for e in states if e.get("type") == "test_state")
payload = next(r["values"]["data"] for r in state["root_module"]["resources"] if r["type"] == "aws_prometheus_rule_group_namespace")
with tempfile.TemporaryDirectory(prefix="amp-promql-") as folder:
    path = pathlib.Path(folder)
    (path / "rules.yaml").write_text(payload)
    subprocess.run(["promtool", "check", "rules", str(path / "rules.yaml")], check=True)
    labels = {"service": "mini-commerce", "environment": "dev", "severity": "critical", "runbook": "https://github.com/play-builder/EKS-infra/blob/main/docs/runbooks/amp-slo.md"}
    selector = 'reporter="destination",destination_canonical_service="mini-commerce",destination_workload_namespace="app-dev",environment="dev"'
    def series(ok, errors, sel=selector):
        return [{"series": f'istio_requests_total{{{sel},destination_service_name="mini-commerce-stable",response_code="200"}}', "values": ok},
                {"series": f'istio_requests_total{{{sel},destination_service_name="mini-commerce-stable",response_code="500"}}', "values": errors}]
    tests = []
    for name, inputs, firing in [
        ("no traffic", [], False),
        ("zero traffic", series("0+0x90", "0+0x90"), False),
        ("low traffic", series("0+0x90", "0+1x90"), False),
        ("normal", series("0+60x90", "0+0x90"), False),
        ("short only", series("0+60x58 3480+0x32", "0+0x58 0+60x32"), False),
        ("both windows", series("0+54x90", "0+6x90"), True),
        ("above floor with fractional RPS", series("0+11.8x90", "0+0.2x90"), True),
        ("canary service contributes", [{"series":s["series"].replace("mini-commerce-stable","mini-commerce-canary"),"values":s["values"]} for s in series("0+54x90","0+6x90")], True),
        ("wrong namespace", series("0+54x90", "0+6x90", selector.replace("app-dev", "app-prod")), False),
    ]:
        # 62m: short-only has 4m error traffic, long-window burn below the test's long threshold.
        tests.append({"name": name, "interval": "1m", "input_series": inputs,
                      "alert_rule_test": [{"eval_time": "62m", "alertname": "MiniCommerceSuccessBurn",
                          "exp_alerts": ([{"exp_labels": labels, "exp_annotations": {
                              "summary": "Mini Commerce success error budget burns in both windows",
                              "owner": "platform",
                              "query": '(sum(rate(istio_requests_total{' + selector + ',response_code=~"5.."}[5m])) / sum(rate(istio_requests_total{' + selector + '}[5m]))) / (1 - 0.999)'
                          }}] if firing else [])}]})
    # Two minutes of 10% failures breach short-window burn but leave the hour below threshold.
    tests[4]["input_series"] = series("0+60x60 3600+54x30", "0+0x60 0+6x30")
    tests.append({"name": "recovery", "interval": "1m", "input_series": series("0+54x65 3510+60x30", "0+6x65 390+0x30"),
                  "alert_rule_test": [{"eval_time": "80m", "alertname": "MiniCommerceSuccessBurn", "exp_alerts": []}]})
    tests.append({"name":"pool errors without operation series","interval":"1m","input_series":[
        {"series":'mini_commerce_db_pool_errors_total{namespace="app-dev",environment="dev"}',"values":"0+1x10"}],
        "promql_expr_test":[{"expr":'ALERTS{alertname="MiniCommerceDBErrors",alertstate="firing"}',"eval_time":"6m",
            "exp_samples":[{"labels":'ALERTS{alertname="MiniCommerceDBErrors",alertstate="firing",service="mini-commerce",environment="dev",severity="critical",runbook="https://github.com/play-builder/EKS-infra/blob/main/docs/runbooks/amp-slo.md"}',"value":1}]}]})
    (path / "tests.json").write_text(json.dumps({"rule_files": [str(path / "rules.yaml")], "evaluation_interval": "1m", "tests": tests}))
    subprocess.run(["promtool", "test", "rules", str(path / "tests.json")], check=True)
