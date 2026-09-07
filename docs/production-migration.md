# 운영 전환과 구조 정리

## 적용 전 확인

핵심 요약: 이 변경은 운영 코드와 설명을 정리합니다. 코드 병합 자체가 기존 AWS state·GitHub 설정·클러스터를 변경하지 않습니다.
기존 설치에서는 아래 입력·태그·OIDC 전환을 검토한 plan으로 반영합니다.

## 삭제한 모듈과 파일

핵심 요약: 아래 모듈은 이 저장소의 활성 Terraform root에서 호출하지 않습니다. 실제 사용 중인 root 주소나 기존 state의 resource 이름을 삭제·변경하지 않습니다.
외부 저장소가 직접 참조한다면 해당 소비자는 별도 이전이 필요합니다.

| 삭제 경로 | 이유 |
| --- | --- |
| `modules/eks/fargate-profile/` | 현재 EKS는 managed node group을 사용하며 호출 없음 |
| `modules/iam/user-roles/` | 미사용 legacy `aws-auth` 역할 구성 |
| `modules/kubernetes/app/` | 사용되지 않는 Terraform workload 배포 구조; app 소유자는 GitOps |
| `modules/kubernetes/ingress/alb-ssl/` | 미사용 별도 ingress; 현재 ALB → Istio 경로와 중복 |
| `modules/networking/security-groups/` | 호출 없는 범용 security group 모듈 |
| `images/eks-architecture.png` | 참조되지 않는 이전 그림; 현재 코드 기반 Mermaid로 교체 |

외부 module source를 이 저장소의 branch에 연결했다면 삭제 전 기준 commit `cceff021784e8bc7e8842a39e83a48134377ccab`으로 고정한 후 이전합니다. 이 안내가 외부 소비자의 Terraform state를 검사했다는 뜻은 아닙니다.

테스트에서는 README 문구·교육 챕터 표식에만 의존하던 assertion을 제거했습니다. 실제 명령 실행·거부 조건·증빙 결속·Terraform 정책·앱 동작 검증은 유지하고 잘못된 통과 조건을 보강합니다. Shell은 운영 CLI 조합, Python은 구조화된 증빙과 AWS SDK 검증에 사용합니다.

## 입력과 소유권 전환

핵심 요약: `Owner`는 담당 팀, `PlatformInstanceId`는 플랫폼 인스턴스 ID입니다. cleanup의 `OWNER_ID`에는 팀 이름이 아니라 이 인스턴스 ID를 넣습니다.
두 소유권 태그가 충돌하는 자원은 삭제 대상으로 승인하지 않습니다.

- `foundation-check.sh`의 `LAB_PROJECT_NAME` 입력을 `PLATFORM_PROJECT_NAME`으로 바꿉니다. 개인 `.envrc`는 자동 수정하지 않으므로 기존 shell/CI 설정도 갱신합니다.
- Network/EKS root는 cleanup 호환용 `OwnerId = PlatformInstanceId`를 함께 발행합니다. GitOps Terraform root의 workload ownership marker에도 이 값이 들어갑니다.
- 기존 태그와 marker는 검토한 plan으로 먼저 반영합니다. 리소스 교체가 예상되면 apply를 중단하고 원인을 확인합니다.
- Cleanup은 `OwnerId` 또는 `PlatformInstanceId`가 일치하는 자원을 검색합니다. 둘 다 존재하면 같은 인스턴스를 가리켜야 합니다. 태그가 없는 예전 자원을 임의로 소유 자원으로 간주하지 않습니다.
- `sample_app_*` 등 과거 state 주소와 실제 migration guard 식별자는 호환성 때문에 유지합니다. 이름만 일괄 치환하지 않습니다.

## IAM 역할과 ECR 소유권 전환

핵심 요약: 기존 범용 infra role의 `PowerUserAccess`와 자체 IAM 변경 허용을 제거했습니다. 역할 소유자가 준비한 plan/apply/drift 전용 role을 검증하며, 이 bootstrap state가 자기 실행 role의 권한을 만들거나 높이지 않습니다.
기존 broad role을 사용 중이라면 새 role과 GitHub 설정을 준비하기 전에 retirement plan을 적용하지 않습니다.

`environments/dev/bootstrap/ci-identity`는 `environment=dev|prod|recovery`별 contract를 생성합니다. 각 계정에서 별도 backend/state로 관리하며 기존 Dev state의 environment를 바꿔 다른 계정에 재사용하지 않습니다.
`enable_external_ci_roles=false` 상태에서 `ci_role_contract`의 exact trust, state policy, required boundary denies를 검토합니다. IAM 소유자는 여기에 실제 root에 필요한 service permissions만 별도로 추가합니다. Deny-only boundary는 권한을 부여하지 않습니다.

전용 role 세 개와 customer-managed boundary의 canonical JSON SHA-256을 `external_ci_roles`에 등록한 후 `enable_external_ci_roles=true`로 검증합니다. role ARN·계정·단일 OIDC trust·environment·boundary hash·필수 Deny를 확인하며, 잘못된 계약이면 Terraform precondition이 실패합니다. 유효 권한 전체와 Kubernetes RBAC를 증명하는 검사는 아니므로 AWS policy simulation과 실제 read-only plan을 추가로 확인합니다.

새 역할과 runner가 준비되면 해당 환경의 GitHub secrets를 전환하고 operator identity로 retirement plan을 적용합니다. 기존 `aws_iam_role.infra` 주소/이름은 보존하되 trust와 inline policy를 Deny로 바꾸고 broad managed-policy attachment를 제거합니다. IAM 전파 후 이전 세션도 Deny의 영향을 받습니다. `infra_role_arn`은 폐기된 호환 output이며 더 이상 CI에 사용하지 않습니다.

Network `02-registry`의 `platform_image_publisher`를 설정하면 별도 immutable ECR와 protected `production` publisher role이 생깁니다. application publisher 권한에는 이 repository를 추가하지 않습니다. [발행 절차](runbooks/platform-image-publishing.md)를 따릅니다.

`registry_scanning.ownership_mode`는 기본 `external`입니다. 이 상태는 Enhanced scanning이 실제로 켜져 있다는 주장이 아니며, 이미지 발행의 실제 ECR scan gate가 결과를 확인합니다. Terraform 소유로 이전할 때는 해당 계정/Region의 기존 singleton을 import하고 모든 기존 필터를 보존한 설정과 `ownership_handoff`를 함께 검토합니다. 기존 관리자는 리소스 삭제 없이 state 소유권을 해제해야 합니다. `prevent_destroy`를 우회해 두 owner가 동시에 관리하지 않습니다.

## CI와 관측 설정

핵심 요약: GitHub 계정별 environment와 private runner 설정은 [Terraform CI 운영 설정](runbooks/terraform-ci.md)을 따릅니다. 미리 구성된 조직 role을 쓸 때도 정확한 environment OIDC trust가 필요합니다.
기존 IAM/registry 설정 변경은 각 bootstrap root의 검토 plan과 전환 안내를 먼저 확인합니다.

AMP의 `amp_retention_days` 및 module `retention_days` 입력은 제거했습니다. 고정된 AWS provider 5.87.0의 실제 schema에는 workspace retention 설정이 없어서 기존 입력은 AWS에 반영되지 않았습니다. 기존 private tfvars에서도 해당 입력을 제거합니다.

AMP metrics retention은 현재 별도 운영 설정입니다. AWS workspace configuration에서 현재 값을 조회하고 운영 정책에 맞게 변경·감사합니다. 서비스 문서상 새 workspace 기본 보존 기간은 150일이며, 이 저장소의 CloudWatch log retention 7일과는 별개입니다. [AWS retention 설명](https://docs.aws.amazon.com/prometheus/latest/userguide/what-is-Amazon-Managed-Service-Prometheus.html), [workspace 설정](https://docs.aws.amazon.com/prometheus/latest/userguide/AMP-workspace-configuration.html)

```bash
aws amp describe-workspace-configuration \
  --workspace-id "$AMP_WORKSPACE_ID" --region "$AWS_REGION" \
  --query 'workspaceConfiguration.{status:status.statusCode,retentionDays:retentionPeriodInDays}'
```

이 변경에는 provider major upgrade나 실제 retention 변경을 포함하지 않습니다. 기존 실제 보존 기간은 위 조회 결과를 기준으로 판단합니다.

DEV_READY 소비자는 legacy v1과 현재 앱 producer의 v2를 모두 지원합니다. v2는 immutable app repository ID도 검증합니다. Network ECR과 Dev/Prod EKS 계정은 분리하고, 같은 image repository·digest·source·region·cluster 증빙의 결속은 유지합니다.

Secret 회전 baseline과 UUID pin 절차는 [README](../README.md#4-dev-runtime와-데이터-검증)를 따릅니다. metadata만으로 AWS secret payload가 동일하다고 추정하지 않습니다. EKS upgrade snapshot은 v2로 다시 수집하며, 현재 controller readiness와 목표 Kubernetes version 지원 확인을 구분합니다.

## 적용과 되돌리기

핵심 요약: 코드 검증 → CI 설정 → 검토 plan → 승인 apply → runtime 검증 순서로 진행합니다. 로컬 테스트와 모의 응답을 실제 배포 성공으로 기록하지 않습니다.

1. 세 저장소의 새 브랜치를 PR로 검토하고 required check를 통과시킵니다.
2. 계정별 role·environment·runner와 비공개 입력을 구성합니다.
3. Terraform root를 network → EKS → platform → workloads 순으로 검토하고 적용합니다. RDS와 registry 변경은 각 root의 소유권·보존 조건을 함께 확인합니다.
4. 실제 Deployment·Secret 회전·AMP/SNS·GitOps promotion·DB 연결을 실행해 runtime evidence를 수집합니다.
5. 문제가 있으면 실행을 멈추고 직전 승인 코드로 새 plan을 생성합니다. 이전 state 파일 덮어쓰기나 IAM privilege 확장을 롤백 수단으로 사용하지 않습니다. DB 변경은 별도 backup/recovery 절차를 따릅니다.
