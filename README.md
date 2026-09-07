# EKS Infrastructure

Mini Commerce를 배포할 AWS 기반을 Terraform으로 관리한다. Network 계정의 ECR·DNS, Dev/Prod 계정의 EKS·IAM·네트워크, Prod RDS와 관측 수집기가 대상이다.
애플리케이션 변경은 이 저장소를 거치지 않는다. 앱 CI가 이미지를 만들고 GitOps 값을 갱신하면 Argo CD가 EKS에 반영한다.

## 구조와 변경 영향

핵심 요약: 운영자는 환경 root의 입력을 변경하고 plan을 검토한다. module은 root가 공유하는 구현이다.

| 경로 | 목적·변경 대상 | 검증 |
| --- | --- | --- |
| `environments/network/` | 공용 ECR·DNS·GitHub governance | root validate, plan |
| `environments/dev/`, `environments/prod/` | VPC → EKS → controller → Argo CD | root validate, plan |
| `environments/recovery/` | 원본과 분리된 RDS 복구 root | native RDS tests, 별도 plan |
| `modules/` | IAM·네트워크·EKS·RDS·controller 재사용 정의 | fmt, TFLint, native tests |
| `terraform/platform-backup/` | 장기 보존 S3/KMS | validate, 보존 정책 검토 |
| `scripts/` | 승인된 Terraform plan, 계정 bootstrap·소유권 인계 | `make test` |
| `policy/` | plan의 운영 정책 | `make policy` |
| `tests/` | 입력 투영과 saved plan의 실패 방지 | `make test` |
| `.github/workflows/` | 인프라 검증·승인 apply·drift·플랫폼 이미지 발행 | PR checks |
| `docs/` | 배포, 운영, 아키텍처, state 이전 절차 | 코드와 명령 대조 |

`versions.lock.yaml`과 `platform-images.lock.json`은 도구·controller·이미지 기준이다. `vendor/`는 고정한 공급자 정책 자료이며 일반 수정 대상이 아니다.

## 시작 순서

핵심 요약: 인프라를 먼저 구성한 뒤 GitOps와 앱 전달 설정을 연결한다. 클러스터 변경과 매번의 앱 배포는 별개다.

1. [배포 절차](docs/deployment.md)에 따라 계정별 state backend와 OIDC·ECR·DNS를 준비한다.
2. Dev의 network → EKS → platform → Argo CD root 순서로 plan/apply한다.
3. GitOps README에 따라 실제 EKS output, ECR, 인증서, 내부 caller CIDR을 연결한다.
4. 앱 저장소의 GitHub 변수와 GitHub App을 구성하고 코드 변경으로 Dev 배포를 확인한다.
5. Prod 기반을 구성한 뒤 승인 PR과 Argo CD 수동 sync로 같은 이미지를 승격한다.

## 검증

핵심 요약: 표준 도구와 두 가지 핵심 운영 검사만 공개한다. 실제 환경 확인은 별도로 수행한다.

```bash
make check
make test-terraform
```

도구 버전과 CI 대응은 [검증 명령](docs/testing.md), 실제 장애 확인은 [운영 절차](docs/runbook.md)에 있다. 배포에는 AWS 자격 증명·실제 입력·승인된 plan이 필요하다. 로컬 검사로 리소스를 생성하지 않는다.

## 운영 도구

핵심 요약: `scripts/lib`는 아래 CLI 또는 CI에서 호출하는 구현이다. 임의로 순서대로 실행하는 목록이 아니다.

| 목적 | 진입점 |
| --- | --- |
| 기반 계정 확인 | `foundation-check.sh`, `validate-external-oidc.sh` |
| 기존 소유권 인계 | `oidc-ownership-handoff.sh`, `external-secrets-owner-handoff.sh`, `ecr-scanning-owner-handoff.sh` |
| ECR scanning 확인 | `ecr-scanning-status-check.sh` |
| 승인된 plan 적용 | `create-saved-plan.sh`, `bind-saved-plan-approval.sh`, `verify-saved-plan.sh` |
| Drift | `terraform-drift-check.sh` |
| 계정 비용 설정 확인 | `finops-readiness-check.sh` |
| DB 계정 bootstrap | `bootstrap-mini-commerce-db.sh` |
| private EKS 운영자 접속 확인 | `prod-operator-access-check.sh` |
| CI 이미지 발행·scanner 설치 | `lib/platform-image-mirror.py`, `install-trivy.sh` |

일상적인 Pod·서비스·Argo 상태는 `kubectl`, `argocd`, AWS CLI와 관측 도구로 확인한다. 별도의 runtime 증빙 조립기·전체 teardown 실행기는 제공하지 않는다.

## 참고

핵심 요약: state와 데이터 소유권을 유지하면서 변경한다. 기존 리소스의 주소를 임의로 바꾸지 않는다.

- [아키텍처](docs/architecture.md)
- [기존 환경 이전](docs/production-migration.md)
- [Terraform CI와 입력](docs/runbooks/terraform-ci.md)
- [Logging/KMS 보안](docs/logging-security.md)

고객 인증·결제·tenant 인가는 앱의 구현 범위 밖이다. 현재 내부 API의 접근 경계를 지키고, 상용 고객 공개에는 별도의 애플리케이션 보안 구현이 필요하다.
