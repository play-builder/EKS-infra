# FinOps saved-plan / apply gate

## 적용 범위

FinOps gate는 기존 billing 설정이 승인한 계약과 일치하는지 확인하는 **configuration-only** 검사다. 실제 비용 데이터, SNS 수신, 조직 전체의 미래 tag 유일성 또는 0원 지출을 증명하지 않는다. `DATA_PENDING`은 설정 준비와 양립하며 delivery는 계속 `NOT_VERIFIED`다.

`create-saved-plan.sh`와 `verify-saved-plan.sh`의 위치 인수는 그대로다. prod 및 recovery apply에는 아래 환경 계약이 추가된다. dev apply와 destroy는 기존 동작을 유지한다. `environments/prod/00-finops`와 `terraform/platform-backup`은 operator-only이며 workflow 선택지에서 제외하고 GitHub 실행에서는 script도 거부한다.

## Operator가 먼저 준비할 입력과 권한

계약은 operator가 실제 `00-finops` output을 export한 비밀값 없는 JSON이다. 파일 내용을 검토하여 소스 저장소에 포함하고 그 **원문 bytes**의 SHA-256을 신뢰된 설정으로 등록한다. Terraform state 자체나 AWS credential은 artifact에 넣지 않는다.

| 환경변수 | 계약 |
| --- | --- |
| `FINOPS_CONTRACT_JSON` | plan 생성 시 읽을 `platform.finops/v1` JSON 파일 경로 |
| `FINOPS_CONTRACT_SHA256` | `sha256:` + 계약 원문 bytes의 64자리 hash; plan/apply 동일 값 |
| `PLATFORM_INSTANCE_ID` | 승인된 계약의 정확한 `requiredTags.PlatformInstanceId` |
| `FINOPS_GATE_POLICY` | 반드시 `configuration-only` |
| `FINOPS_BILLING_ROLE_ARN` | management-account의 기존 read-only monitoring role ARN |
| `FINOPS_BILLING_PROFILE` | local operator만 role 대신 사용할 명시 profile; 둘 중 정확히 하나 |

GitHub workflow는 `vars.FINOPS_CONTRACT_PATH`, `vars.FINOPS_CONTRACT_SHA256`, `vars.PLATFORM_INSTANCE_ID`, `vars.FINOPS_BILLING_MONITOR_ROLE_ARN`을 사용한다. plan은 repository vars, apply는 protected `production` environment의 유효 vars를 사용하므로 의도한 동일 계약을 설정해야 한다. role ARN을 dispatch 입력으로 받지 않는다. workload credential은 기존 `TERRAFORM_PLAN_ROLE_ARN`/`TERRAFORM_APPLY_ROLE_ARN` secrets로만 구성한다.

management monitoring role은 operator가 미리 준비해야 한다. workload plan/apply identity에 정확한 monitoring role의 `sts:AssumeRole` 허용이 필요하고, management role trust에도 그 두 실제 role만 명시해야 한다. IAM root의 optional `billing_monitor_role_arn`은 그 root가 관리하는 workload role에 한정된 권한이며, 별도로 관리하는 plan/apply role의 policy/trust를 자동 생성하지 않는다. management 권한은 기존 collector에 필요한 Organizations membership, Budgets, CE, SNS 및 조건부 KMS read API로 제한한다. provision/apply/delete 권한을 monitoring role에 추가하지 않는다.

billing SDK는 `us-east-1`로 고정한다. workload account/Region은 실제 workload STS identity와 contract로 대조한다. monitoring STS principal, management account, organization membership 및 구성은 기존 collector가 조회하고 검증한다. role 접근은 응답의 assumed-role principal이 설정한 role 이름 및 billing account와 일치하는지도 확인한다. 임시 assume-role credential은 memory에서만 사용하며 artifact/log로 출력하지 않는다.

## 실행 흐름과 정상 결과

plan 단계에서 설정을 조회한 뒤 contract/readiness를 saved binary plan과 함께 게시한다. manifest의 `finops` 객체는 두 파일의 raw-byte SHA-256, workload/billing identity, PlatformInstanceId, monitoring identity, observation/expiry를 결합한다. 기존 binary-plan/JSON/lock/binary/source/approval 바인딩은 유지된다.

apply에서는 protected-environment approval을 먼저 결합하고 FinOps artifact의 누락·변조·identity·collector-source·TTL을 검증한다. 이어 같은 승인 계약으로 **실제 설정을 재조회**한다. 이 검사가 성공해야 Terraform version 검증, readonly-provider init, saved binary apply로 진행한다. 새 관측은 `finops-apply-readiness.json`에 남는다.

readiness 유효기간은 `observedAt + 15분`이며 재평가로 기존 증거 TTL을 연장하지 않는다. 승인을 기다리는 동안 만료되면 새 plan과 새 승인이 필요하다. contract를 변경했다면 hash와 plan도 함께 새로 만들어야 한다. 관측 만료·API 거부·member/role/config 불일치에는 override/PASS 문자열 우회가 없다.

workflow 도구 전제는 Terraform `1.16.0` (wrapper 비활성), Python >=3.10 isolated venv와 `scripts/requirements-amp-slo.txt`의 exact boto3/botocore `1.42.59`다. AWS CLI/`gh`는 GitHub runner의 도구를 사용한다. 전체 static job은 별도로 Helm `4.2.4`, promtool `3.14.0`, yq `4.53.6`, pinned Python requirements, hash-locked chart archives 및 `jq/ruby/rg/go`를 요구한다. 실제 SDK serialization test도 여전히 로컬 static 검증이다.

## 로컬 검증과 한계

테스트는 실제 saved-plan shell scripts와 실제 readiness evaluator를 실행하고 외부 AWS/Terraform I/O만 double로 바꾼다. `COURSE_CHECK_BIN_DIR` + `FINOPS_FIXTURE_JSON`은 로컬 테스트에서만 사용하며 manifest grade를 `STATIC`으로 고정한다. GitHub 실행은 fixture를 거부하고 runtime lane은 STATIC/fixture artifact를 거부한다. fixture 결과를 비용 runtime 검증으로 승격하지 않는다.

```bash
bash tests/finops-saved-plan-contract.sh
bash tests/saved-plan-apply-workflow-contract.sh
bash tests/install-trivy-contract.sh
```

Trivy 설치는 승인한 `0.74.0` archive checksum을 **추출·실행 전에** 검증하고 설치된 binary version도 확인한다. pinned `trivy-action` v0.36.0의 `skip-setup-trivy: true`로 재설치를 막는다. [정확한 action 입력](https://github.com/aquasecurity/trivy-action/blob/ed142fd0673e97e23eac54620cfb913e5ce36c25/action.yaml).

이 검사는 unsigned artifact에 대한 trusted-runner 검증이다. repo/environment 설정 변경자, workflow 변경자, credential 소유자가 직접 Terraform을 실행하는 것을 script로 막는다고 주장하지 않는다. main branch protection, protected environment 승인자 분리, IAM/runner governance, artifact provenance와 실행 로그 보존은 별도 운영 통제다. AWS/DB/cluster runtime, 실제 비용 발생·SNS 전달, GitHub protected apply 및 Linux installer 다운로드 실행은 이 변경의 로컬 테스트로 증명되지 않는다. **LIVE_NOT_VERIFIED.**
