# Terraform CI 운영 설정

## 실행 경계

핵심 요약: PR과 `main` push는 AWS 권한 없이 정적 검증을 실행합니다. Terraform plan/apply는 `main`의 수동 dispatch에서만 실행하며, 모든 정적 검증이 성공해야 합니다.
운영 job은 private EKS API에 연결할 수 있는 별도 runner를 사용합니다.

| Terraform root | Plan environment | Apply environment | Drift environment |
| --- | --- | --- | --- |
| `environments/dev/**` | `dev-plan` | `dev` | `dev-drift` |
| `environments/prod/**` | `production-plan` | `production` | `production-drift` |
| `environments/recovery/**` | `recovery-plan` | `recovery` | `recovery-drift` |

`workflow_dispatch`의 `terraform_root`와 `backend_config`는 고정 allowlist입니다. 실제 스크립트도 두 경로의 조합을 검증합니다. FinOps·공유 backup root는 정기 workload drift 대상이 아니며 별도 operator identity로 관리합니다.

## GitHub environment 설정

핵심 요약: 아래 이름은 workflow가 읽는 정확한 입력입니다. 각 environment에 해당 AWS 계정의 값을 설정해야 하며 repository 공통값으로 다른 계정을 대신하지 않습니다.
저장소 코드만으로 실제 account ID, role ARN, 비공개 tfvars를 알 수 없으므로 operator가 검증한 값을 등록합니다.

| 범위 | Variables | Secrets |
| --- | --- | --- |
| 모든 운영 environment | `AWS_ACCOUNT_ID`, `AWS_REGION`, `STATE_BUCKET_NAME` | 해당 작업의 전용 role ARN |
| Plan | 필요 시 `PLATFORM_INSTANCE_ID`, `FINOPS_CONTRACT_PATH`, `FINOPS_CONTRACT_SHA256`, `FINOPS_BILLING_MONITOR_ROLE_ARN` | `TERRAFORM_PLAN_ROLE_ARN`, `TERRAFORM_PLAN_INPUTS_JSON` |
| Apply | 해당 plan과 같은 account/region/bucket 및 FinOps 설정 | `TERRAFORM_APPLY_ROLE_ARN` |
| Drift | 해당 root의 account/region/bucket | `TERRAFORM_DRIFT_ROLE_ARN`, `TERRAFORM_DRIFT_INPUTS_JSON` |

Private 입력 JSON의 형식과 root별 account/bucket 검증은 [입력 계약](enterprise-integration.md#scheduled-read-only-drift)을 따릅니다. Plan 생성 시 입력은 저장된 binary plan에 포함되므로 apply에 새 tfvars를 주입하지 않습니다.

모든 environment는 deployment branch를 `main`으로 제한합니다. Apply environment 세 개에는 required reviewer와 prevent self-review를 설정합니다. Apply 코드는 실제 GitHub approval history의 environment와 요청자·승인자를 확인합니다. 다른 environment의 승인은 해당 plan을 승인하지 않습니다.

이 저장소의 IAM contract는 immutable repository subject인 `repo:<owner>@<owner-id>/EKS-infra@<repository-id>:environment:<environment>`를 사용합니다. GitHub가 발급하는 token subject도 이 형식이어야 하며, 일반적인 기본 subject와 다릅니다. `ci_role_contract` output과 실제 조직의 GitHub OIDC 설정을 대조합니다. 기존 `ref:refs/heads/main` 조건만 허용하는 role은 이 job을 인증하지 못합니다. role trust에 정확한 environment와 repository identity를 등록하고, main 제한은 GitHub environment protection으로 유지합니다. [GitHub OIDC subject 규칙](https://docs.github.com/en/actions/reference/security/oidc#example-subject-claims)

## 운영 runner

핵심 요약: 기본 runner label은 `["self-hosted","linux","x64","eks-operations"]`입니다. repository variable `TERRAFORM_RUNNER_LABELS`에는 승인된 runner의 label 배열을 JSON으로 지정할 수 있습니다.
PR용 정적 job은 GitHub hosted runner에 남아 있으며 운영 runner에서 외부 PR 코드를 실행하지 않습니다.

Runner는 작업마다 폐기하는 ephemeral 방식으로 배치합니다. 저장된 Terraform plan은 민감한 입력을 포함할 수 있습니다. Actions artifact 보존 기간은 1일이며 다운로드 권한을 제한합니다. 재사용 runner를 선택하면 workspace와 임시 plan/credential 파일의 삭제 책임이 운영팀에 있습니다.

실행 이미지에는 Bash, Python 3.10+와 venv, AWS CLI v2, Git, jq, GitHub CLI, CA certificate가 필요합니다. Terraform 1.16.0은 workflow가 설치합니다. Runner의 파일시스템 mount 경로와 CPU 아키텍처는 plan/apply 사이에 같아야 하며, source SHA·Terraform 실행 파일 SHA-256·provider lock이 모두 일치해야 저장된 plan을 사용할 수 있습니다.

Runner는 대상 VPC의 private EKS endpoint DNS와 TCP 443에 접근해야 합니다. 다른 계정/Region도 처리하는 label pool이면 각 대상까지의 라우팅과 DNS가 필요합니다. 연결성을 준비하지 않은 hosted runner로 label을 바꾸면 Kubernetes/Helm provider refresh가 실패합니다. [AWS private endpoint 요구사항](https://docs.aws.amazon.com/eks/latest/userguide/cluster-endpoint.html)

Plan/drift IAM role에는 조회 권한과 필요한 state 조회·잠금 권한만 부여합니다. Kubernetes 접근이 필요한 root에서는 해당 role의 EKS Access Entry/RBAC도 별도로 구성합니다. AWS API 인증 성공은 Kubernetes 권한이나 네트워크 도달성을 증명하지 않습니다.

## 정상 결과와 실패 확인

핵심 요약: 정적 검증 성공 후 plan artifact가 생성되고, 별도 승인 뒤 동일한 binary plan만 apply됩니다. Drift는 변경을 적용하지 않고 redacted `drift.json`만 업로드합니다.

- Job이 대기하면 runner label·runner group 접근·environment reviewer를 확인합니다.
- OIDC 실패는 role의 environment subject와 GitHub branch protection을 확인합니다.
- `*_ACCOUNT_MISMATCH`는 environment의 role/account/region/bucket 설정을 대조합니다.
- Private endpoint timeout은 runner DNS·라우팅·security group을 확인합니다.
- Saved-plan 결속 실패는 기존 artifact를 수정하지 않고 새 plan부터 생성합니다.
- 운영 job과 실제 AWS apply를 실행하지 않은 검증 결과는 로컬/정적 검증으로 기록합니다.
