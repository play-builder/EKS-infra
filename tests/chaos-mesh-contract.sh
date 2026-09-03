#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin"

cat >"$tmp_dir/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$COURSE_FAKE_KUBECTL_LOG"
case "$*" in
  *"get deployment chaos-controller-manager"*)
    echo '{"metadata":{"name":"chaos-controller-manager"},"spec":{"template":{"spec":{"containers":[{"args":["--enable-filter-namespace=true"]}]}}},"status":{"replicas":1,"availableReplicas":1}}'
    ;;
  *"get crd podchaos.chaos-mesh.org networkchaos.chaos-mesh.org"*)
    echo '{"items":[{"status":{"conditions":[{"type":"Established","status":"True"}]}},{"status":{"conditions":[{"type":"Established","status":"True"}]}}]}'
    ;;
  *"get configmap chaos-mesh-course-contract"*)
    echo '{"data":{"courseId":"course-2026","allowedNamespaces":"app-dev","maxFaultDurationSeconds":"60","maxFaults":"1","costBoundary":"existing-eks-compute"}}'
    ;;
  *"get namespace app-dev"*)
    echo '{"metadata":{"name":"app-dev","labels":{"chaos-mesh.org/inject":"enabled"}}}'
    ;;
  *"auth can-i"*) echo yes ;;
  *) printf 'unexpected kubectl invocation: %s\n' "$*" >&2; exit 97 ;;
esac
EOF
chmod +x "$tmp_dir/bin/kubectl"

COURSE_CHECK_BIN_DIR="$tmp_dir/bin" COURSE_FAKE_KUBECTL_LOG="$tmp_dir/kubectl.log" \
  bash "$root/scripts/chaos-mesh-readiness-check.sh" dev-playdevops chaos-mesh course-2026 app-dev 60 1

grep -Fq -- '--context dev-playdevops' "$tmp_dir/kubectl.log"
grep -Fq -- 'get deployment chaos-controller-manager' "$tmp_dir/kubectl.log"
grep -Fq -- 'get crd podchaos.chaos-mesh.org networkchaos.chaos-mesh.org' "$tmp_dir/kubectl.log"
grep -Fq -- 'auth can-i create podchaos.chaos-mesh.org' "$tmp_dir/kubectl.log"

set +e
sed 's/"maxFaults":"1"/"maxFaults":"2"/' "$tmp_dir/bin/kubectl" >"$tmp_dir/bin/kubectl-bad"
chmod +x "$tmp_dir/bin/kubectl-bad"
mv "$tmp_dir/bin/kubectl-bad" "$tmp_dir/bin/kubectl"
COURSE_CHECK_BIN_DIR="$tmp_dir/bin" COURSE_FAKE_KUBECTL_LOG="$tmp_dir/bad.log" \
  bash "$root/scripts/chaos-mesh-readiness-check.sh" dev-playdevops chaos-mesh course-2026 app-dev 60 1 >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]] || { echo 'expected invalid Chaos Mesh contract to fail' >&2; exit 1; }

echo 'PASS: Chaos Mesh readiness and bounded Dev-only contract'
