#!/usr/bin/env python3
"""Check the actual collector config and target port selection, entirely offline."""
import json, pathlib, re, subprocess, tempfile
root=pathlib.Path(__file__).resolve().parents[1]
result=subprocess.run(["terraform","-chdir="+str(root/"modules/addons/adot-collector"),"test","-filter=tests/scrape-contract.tftest.hcl","-json","-verbose"],capture_output=True,text=True,check=True)
state=next(json.loads(x)["test_state"] for x in result.stdout.splitlines() if json.loads(x).get("type")=="test_state")
manifest=next(r["values"]["manifest"] for r in state["root_module"]["resources"] if r["type"]=="kubernetes_manifest")
config=manifest["spec"]["config"]
jobs=config["receivers"]["prometheus"]["config"]["scrape_configs"]
app,proxy=jobs[:2]
assert app["metrics_path"]=="/metrics" and proxy["metrics_path"]=="/stats/prometheus"
def kept(job,namespace,container,port,number):
    labels={"__meta_kubernetes_namespace":namespace,"__meta_kubernetes_pod_label_app_kubernetes_io_name":"mini-commerce",
            "__meta_kubernetes_pod_container_name":container,"__meta_kubernetes_pod_container_port_name":port,
            "__meta_kubernetes_pod_container_port_number":str(number),"__meta_kubernetes_pod_phase":"Running"}
    return all(re.fullmatch(rule["regex"],";".join(labels.get(x,"") for x in rule["source_labels"])) for rule in job["relabel_configs"] if rule.get("action")=="keep")
for namespace in ("app-dev","app-prod"):
    targets=[("application","http",3000),("application","management",3001),("istio-proxy","http-envoy-prom",15090),("istio-proxy","status-port",15020)]
    assert [t for t in targets if kept(app,namespace,*t)] == ([targets[1]] if namespace=="app-dev" else [])
    assert [t for t in targets if kept(proxy,namespace,*t)] == ([targets[2]] if namespace=="app-dev" else [])
assert not any(r.get("action")=="labelmap" for j in jobs[:2] for r in j["relabel_configs"])
assert all(next(r["replacement"] for r in j["relabel_configs"] if r.get("target_label")=="environment")=="dev" for j in jobs[:2])
assert config["receivers"]["otlp"]["protocols"]["http"]["endpoint"]=="0.0.0.0:4318"
assert config["service"]["pipelines"]["traces"]["exporters"]==["awsxray"]
with tempfile.TemporaryDirectory(prefix="adot-config-") as folder:
    path=pathlib.Path(folder)/"prometheus.json";path.write_text(json.dumps(config["receivers"]["prometheus"]["config"]))
    subprocess.run(["promtool","check","config","--syntax-only",str(path)],check=True)
print("PASS: distinct management/proxy target selection and preserved OTLP/X-Ray")
