# 운영 코드 검증

## 빠른 회귀 검사

핵심 요약: 한 실행기가 실제 Shell/Python 검사를 한 번씩 호출합니다. fake AWS·Terraform·Kubernetes 응답을 사용하는 검사는 운영 호출의 허용·거부와 증빙 보존을 확인합니다.
교육 자료나 챕터 dispatcher가 없는 단독 checkout에서 실행할 수 있습니다.

```bash
bash tests/run-contract-tests.sh
```

Bash, Git, jq, Python 3.10+, Ruby, ripgrep, Terraform 1.16.0이 필요합니다. fake CLI에 `PLATFORM_CHECK_BIN_DIR`를 사용하면 생성 증빙의 등급은 `STATIC`입니다. 이 등급은 promotion 입력으로 사용할 수 없습니다.

## Terraform native 검사

핵심 요약: `.tftest.hcl`은 실제 Terraform이 계산한 입력·출력·정책을 검사합니다. mock provider와 remote-state override를 사용하므로 AWS state 이전이나 실제 배포를 증명하지 않습니다.
CI의 `enterprise-static` job은 빠른 suite를 재실행하지 않습니다.

```bash
terraform fmt -check -recursive
while IFS= read -r root; do
  terraform -chdir="$root" init -backend=false -input=false -no-color
  terraform -chdir="$root" validate -no-color
  terraform -chdir="$root" test -no-color
done < <(rg --files modules environments terraform -g '*.tftest.hcl' | sed 's|/tests/[^/]*$||' | sort -u)
```

`init`은 provider와 module을 다운로드할 수 있습니다. source 문자열 수를 세던 검사는 state bucket 선택, network cluster identity, ownership tags, OTLP 출력과 NAT/Flow Log의 native assertion으로 통합했습니다. saved-plan·cleanup·drift는 실제 명령 경계와 생성 artifact를 기존 동작 테스트에서 검사합니다.

## Chart·PromQL·Lua·SDK 검사

핵심 요약: Helm 4.2.4, promtool 3.14.0, yq 4.53.6, Lua 5.1.5와 SHA-256이 검증된 chart archive를 사용합니다. CI의 도구 설치·archive pin은 `.github/workflows/terraform-validate.yml`이 기준입니다.
실제 차트 렌더와 로컬 정책 평가는 Kubernetes controller나 admission 실행과 구분합니다.

```bash
python3 -m venv /tmp/eks-check-python
/tmp/eks-check-python/bin/pip install -r scripts/requirements-argocd-backup.txt
export ENTERPRISE_PYTHON=/tmp/eks-check-python/bin/python3
```

`ARGOCD_CHART_ARCHIVE`, `ROLLOUTS_CHART_ARCHIVE`, `SIGSTORE_CHART_ARCHIVE`, `AUTOSCALER_CHART_ARCHIVE`에는 각각 CI와 동일한 archive를 지정합니다. Lua 실행 파일은 PATH 또는 `LUA_BIN`으로 선택합니다.

```bash
"$ENTERPRISE_PYTHON" tests/ownership-marker-destroy-contract.py
"$ENTERPRISE_PYTHON" tests/log-key-dag-contract.py
"$ENTERPRISE_PYTHON" tests/external-secret-lua-contract.py
bash tests/argocd-render-contract.sh
bash tests/sigstore-controller-contract.sh
bash tests/cluster-autoscaler-render-contract.sh
"$ENTERPRISE_PYTHON" tests/adot-scrape-contract.py
"$ENTERPRISE_PYTHON" tests/amp-promql-contract.py
```

```bash
"$ENTERPRISE_PYTHON" tests/amp-slo-sdk-contract.py
"$ENTERPRISE_PYTHON" tests/argocd-backup-sdk-contract.py
"$ENTERPRISE_PYTHON" tests/rds-recovery-sdk-contract.py
```

SDK 검사는 pinned boto3/botocore 1.42.59의 serialization과 stub 응답을 검사합니다. 실제 AWS 인증·권한·알림 전달·복구 성공은 별도 운영 증빙이 필요합니다. CI의 TFLint, Trivy, Conftest gate도 유지합니다.

## 운영 진입점

핵심 요약: 코드 검증과 실제 환경 확인은 명령으로 구분합니다. 운영 명령의 기존 identity, 승인, saved-plan, 증빙 등급 조건은 유지합니다.

| 목적 | 진입점 |
| --- | --- |
| 계정별 state bucket·DNS 위임·OIDC | `scripts/foundation-check.sh` |
| Dev Deployment·stateful·Secret 회전 | `scripts/dev-ready-check.sh core\|stateful\|secret-freshness` |
| Dev 배포·SLO 증빙 | `scripts/capture-dev-evidence.sh deployment\|slo` |
| 세 파일의 DEV_READY 결속 | `scripts/dev-ready-check.sh deployment.json slo.json ready.json` |
| teardown 사전 검사·실행 | `scripts/cleanup-preflight.sh`, `checkpoint-teardown.sh`, `final-cleanup.sh` |

`foundation-check.sh`는 기존 `NETWORK_AWS_PROFILE`, `DEV_AWS_PROFILE`, `AWS_REGION`, `LAB_PROJECT_NAME`, `ROOT_DOMAIN`, `INFRA_GH_REPO`, `APP_GH_REPO`, `GITOPS_GH_REPO` 입력을 사용합니다. teardown은 저장된 검토 plan과 명시적인 실행 승인이 있어야 변경을 수행합니다.
