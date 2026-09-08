# EKS 배포 절차

이 저장소는 dev와 prod를 **서로 다른 EKS 클러스터**로 만드는 Terraform 전체 코드입니다.
먼저 dev의 네 계층을 완성하고 서비스 요청·관측 지표를 확인한 뒤 prod를 구성합니다. 두 환경의
Terraform state, VPC CIDR, Argo CD instance, AMP workspace가 분리됩니다.

현재 플랫폼은 Mini Commerce의 business/management 포트 분리, Istio native Rollouts,
독립 Prod RDS·복구, 보호 백업 및 FinOps 계약을 사용합니다. 전체 운영 경계와 준비 순서는
[enterprise integration](runbooks/enterprise-integration.md)에 있습니다.
운영 명령은 아래 목적별 진입점을 사용합니다. 아키텍처·소유권·폴더별 코드 지도는
[아키텍처](architecture.md), 장애 대응과 제거 절차는 [운영 runbook](runbook.md),
실행 가능한 검증은 [테스트 안내](testing.md)에서 관리합니다.

Network 계정의 shared identity는 전용 계정의 Terraform-owned GitHub OIDC provider와 기존 account-wide provider를
구분합니다. 기존 provider는 삭제하지 않고 external mode로 참조하며, ECR lifecycle 변경 전에는
모든 rollback image-index digest가 보존되는지 preview gate로 확인합니다.


## 저장소 구조

핵심 요약: 배포 단위는 `environments/`, 재사용 구현은 `modules/`, 운영 명령은 `scripts/`입니다.
모든 디렉터리를 하나의 Terraform root로 실행하지 않습니다.

| 경로 | 역할 |
| --- | --- |
| `environments/network/` | 계정별 state bootstrap, DNS, ECR/OIDC, GitHub governance |
| `environments/dev/`, `environments/prod/` | 네트워크 → EKS → platform → Argo CD의 독립 state |
| `environments/prod/03-database/`, `environments/recovery/` | 운영 DB와 별도 복구 대상 |
| `modules/` | 위 root에서 사용하는 Terraform 구성 요소 |
| `terraform/platform-backup/` | workload 폐기와 분리된 보호 백업 root |
| `scripts/`, `scripts/lib/` | 운영 CLI와 구현: 저장된 plan 승인·적용, bootstrap, 소유권 인계 |
| `tests/`, 각 root의 `tests/` | 핵심 운영 안전 검사와 native 보안·데이터 보호 검사 |
| `vendor/`, `versions.lock.yaml`, `platform-images.lock.json` | 고정한 CRD·도구·chart·이미지 입력 |
| `policy/`, `.github/workflows/`, `docs/` | 검증 정책, CI, 설계·운영 절차 |

[상세 코드 지도와 운영 규모별 선택](architecture.md#폴더와-코드-지도)을 먼저 읽고
실제 계정·Region·기존 state 경계를 결정합니다. 로컬 검증 PASS를 운영 배포 완료로 표시하지 않습니다.

## 배포 순서

```text
[shared, 한 번]
GitHub OIDC + ECR
        │
        ▼
[dev cluster]
01-network → 02-eks → 03-platform → 04-workloads/argocd → Dev 서비스 확인
                                                         │
                                                         ▼
[prod cluster]
01-network → 02-eks → 03-platform → 04-workloads/argocd
```

이 그림에서 봐야 할 핵심은 prod가 dev와 동시에 생성되는 것이 아니라, dev의 빌드·GitOps
배포·관측성 검증이 끝난 뒤 별도 단계로 생성된다는 점입니다.

## 계층별 책임

| 계층 | 만드는 것 | 만들지 않는 것 |
| --- | --- | --- |
| shared | GitHub OIDC, ECR, GitHub Actions IAM role | EKS cluster |
| 01-network | VPC, subnet, NAT, route | EKS |
| 02-eks | EKS 1.36, node group, Access Entry, OIDC provider | platform chart |
| 03-platform | Gateway CRD, AWS LBC, External Secrets, AMP/ADOT, IRSA, `mini-commerce-gp3`, snapshot add-on (opt-in) | application/PVC |
| 04-workloads | HA Argo CD, Argo Rollouts native Istio RBAC, bootstrap Application | app manifest 원본 |

## 전제 도구

- Terraform 1.16.0
- AWS CLI 2
- kubectl 1.36 계열
- Helm 4.2.4
- AWS 계정과 Route53 hosted zone

버전 계약은 [versions.lock.yaml](../versions.lock.yaml)에 있습니다.

배포 시작 시 두 지원 Region 중 하나를 선택하고 모든 Terraform root와 AWS CLI에서 같은 값을
사용합니다. 아래 예시는 서울이며 버지니아 북부를 선택하면 `us-east-1`로 바꿉니다.

```bash
export AWS_REGION="ap-northeast-2"
export STATE_BUCKET_NAME="replace-with-your-state-bucket"
```

ADOT를 활성화할 때 `03-platform`의 `adot_addon_version`은 대상 Region과 EKS 버전에서
실제로 지원되는 값으로 지정합니다. 기본 버전을 AWS가 자동 선택하도록 두지 않습니다.
아래 조회에서 승인한 버전을 선택하여 해당 root의 private tfvars/CI 입력에 넣습니다.

```bash
aws eks describe-addon-versions --addon-name adot \
  --kubernetes-version 1.36 --region "$AWS_REGION" \
  --query 'addons[].addonVersions[].{version:addonVersion,compatibilities:compatibilities}'
```

`terraform.tfvars.example`의 `REPLACE_WITH_VERIFIED_ADOT_ADDON_VERSION`은 실제 버전이 아니며,
그대로 사용하면 validation에서 거부됩니다. ADOT operator add-on 버전과 collector image 버전은
서로 다른 입력입니다. collector는 `versions.lock.yaml`에 기록한 amd64/arm64 index digest로 고정했습니다.
이 플랫폼에서 `enable_adot_collector=true`는 `enable_amp=true`를 요구합니다.
[AWS add-on 설치 문서](https://aws-otel.github.io/docs/getting-started/adot-eks-add-on/installation/)

collector 리소스 수는 plan 시점에 알려진 활성화 값으로 결정합니다. 새 AMP의 endpoint가
apply 이후에 확정되어도 `count` 계산이 막히지 않습니다. collector CR은 add-on 설치가 끝난 뒤
`kubectl_manifest`로 적용하므로 첫 plan에서 아직 없는 CRD schema를 요구하지 않습니다.
이는 설치 순서에 대한 코드 보장이고, 실제 operator와 AMP 수집 성공은 별도로 확인합니다.


`.github/workflows/terraform-validate.yml`은 선택한 root에서 계정별 GitHub environment를 결정합니다.
Dev는 `dev-plan` → `dev`, Prod는 `production-plan` → `production`, Recovery는
`recovery-plan` → `recovery`를 사용합니다. 각 environment에 해당 계정의
`AWS_ACCOUNT_ID`, `AWS_REGION`, `STATE_BUCKET_NAME`과 역할·입력 secret을 등록합니다.
Apply environment는 required reviewer, self-review 차단, `main` branch 제한을 설정합니다.
Plan/apply는 모든 정적 검증이 성공한 뒤 실행됩니다.

운영 job은 VPC에 접근할 수 있는 self-hosted runner를 기본으로 사용합니다.
계정별 설정 목록, runner 준비, OIDC 신뢰 조건은 [CI 운영 설정](runbooks/terraform-ci.md)을 따릅니다.
CI는 Git에 없는 로컬 tfvars를 읽지 않습니다. 기존 설치의 변경 절차는
[운영 전환 안내](production-migration.md)에 있습니다.

## 0. Network 계정의 GitHub OIDC와 ECR

저장소 루트에서 Network 계정의 AWS profile과 해당 계정의 state bucket을 선택합니다.
`environments/network/02-registry/terraform.tfvars.example`을 같은 위치의
`terraform.tfvars`로 복사하고 Organization ID, GitHub owner/repository 숫자 ID를 설정합니다.
계정에 GitHub OIDC provider가 이미 있으면 `external` mode와 기존 ARN을 사용합니다.

```bash
terraform -chdir=environments/network/02-registry init -reconfigure \
  -backend-config="bucket=$STATE_BUCKET_NAME" \
  -backend-config="key=network/02-registry/terraform.tfstate" \
  -backend-config="region=$AWS_REGION" \
  -backend-config="encrypt=true" \
  -backend-config="use_lockfile=true"
terraform -chdir=environments/network/02-registry plan -out=tfplan
```

계획의 account/region과 변경 대상을 검토한 뒤 같은 root에서 저장한 plan을 적용합니다.

```bash
terraform -chdir=environments/network/02-registry apply tfplan
terraform -chdir=environments/network/02-registry output
```

- `image_push_role_arn` → 앱의 `AWS_ROLE_ARN`
- `attest_verify_role_arn` → 앱의 `AWS_ATTEST_VERIFY_ROLE_ARN`
- `image_repository_url` → 앱 이미지 발행 및 GitOps `image.repository`
- `chart_repository_url` → chart 발행·소비 위치
- `image_repository_arn` → 플랫폼의 sigstore ECR 권한 입력

이 root는 앱 artifact 발행 권한을 만듭니다. Dev 인프라 실행 identity는
`environments/dev/bootstrap/ci-identity`의 별도 root에서 구성합니다.
기존 state가 있으면 실제 backend key를 그대로 사용하며 위 새 설치 예시로 바꾸지 않습니다.
전체 계정·root 입력은 [운영 통합 안내](runbooks/enterprise-integration.md)를 따릅니다.

## 1. dev 클러스터

각 계층에서 example을 복사하고 placeholder를 교체합니다. 모든 downstream root의
`state_bucket_name`은 backend에 전달한 `STATE_BUCKET_NAME`과 동일해야 합니다. 실제 `.tfvars`는
gitignore 대상이며 아래 `-var`도 같은 값을 명시해 backend와 remote-state 조회가 갈라지지 않게 합니다.

```bash
cp environments/dev/01-network/terraform.tfvars.example environments/dev/01-network/terraform.tfvars
cp environments/dev/02-eks/terraform.tfvars.example environments/dev/02-eks/terraform.tfvars
cp environments/dev/03-platform/terraform.tfvars.example environments/dev/03-platform/terraform.tfvars
cp environments/dev/04-workloads/argocd/terraform.tfvars.example environments/dev/04-workloads/argocd/terraform.tfvars
```

계층별 backend 초기화 패턴은 같습니다. 아래에서 `<layer>`와 backend 파일만 바꿉니다.

```bash
terraform -chdir=environments/dev/<layer> init \
  -backend-config=../config/<backend>.tfbackend \
  -backend-config="bucket=$STATE_BUCKET_NAME" \
  -backend-config="region=$AWS_REGION" \
  -reconfigure

terraform -chdir=environments/dev/<layer> plan -out=tfplan
terraform -chdir=environments/dev/<layer> apply tfplan
```

`01-network`에는 remote-state input이 없으므로 위 명령 그대로 실행합니다. `02-eks`,
`03-platform`, `04-workloads/argocd` plan에만 다음 required input을 추가합니다.

```bash
terraform -chdir=environments/dev/<downstream-layer> plan \
  -var="state_bucket_name=$STATE_BUCKET_NAME" \
  -out=tfplan
```

실제 매핑:

| layer | backend 파일 |
| --- | --- |
| `01-network` | `network.tfbackend` |
| `02-eks` | `eks.tfbackend` |
| `03-platform` | `platform.tfbackend` |
| `04-workloads/argocd` | `../../config/argocd.tfbackend` 경로를 사용 |

`04-workloads/argocd`는 처음에 `enable_bootstrap=false`로 적용합니다. GitOps 저장소의
placeholder, secret value, repository 접근을 준비한 뒤 `true`로 바꾸고 다시 적용합니다.

`03-platform`은 EBS CSI Driver와 non-default `mini-commerce-gp3` StorageClass도 만듭니다. StorageClass는
encrypted gp3, volume expansion, `WaitForFirstConsumer`를 사용합니다. StorageClass 생성만으로는
EBS volume이 생성되지 않습니다. PVC를 소비하는 Pod가 스케줄링될 때 volume이 provisioning됩니다.

Platform controller는 해당 운영 기능과 선행 조건이 준비됐을 때 활성화합니다.

| 시점 | `03-platform` flag | 결과 |
| --- | --- | --- |
| controller 초기화 | `enable_external_secrets=true` | Terraform이 External Secrets의 유일한 writer |
| secret rotation | `enable_reloader=true` | runtime secret rotation이 Rollout의 새 Pod를 생성 |
| Dev 부하 검증 | `enable_k6_operator=true`, `enable_amp_alerting=true` | 제한된 부하와 SLO/alert 검증 |
| Prod | `enable_k6_operator=false` | 부하 생성 controller 설치 차단 |
| snapshot 복구 준비 | `enable_snapshot_controller=true` | EKS managed `snapshot-controller`와 Retain `VolumeSnapshotClass` 설치 |

ADOT X-Ray trace 입력은 애플리케이션과 OTLP/HTTP protobuf 계약을 사용합니다. `enable_adot_xray=true`일
때 platform output의 `otlp_http_traces_endpoint`를 `OTEL_EXPORTER_OTLP_ENDPOINT`에 그대로
설정하며, endpoint는 `:4318/v1/traces`, protocol은 `http/protobuf`입니다. gRPC `4317` 입력은
이 과정의 애플리케이션 계약에 포함하지 않습니다. 이 active phase에서만 endpoint, protocol,
`otlp_http_port=4318`, `otlp_http_traces_path=/v1/traces`, `adot_xray_enabled=true`가 함께 게시됩니다.
AMP metric discovery는 `namespace`, `pod`, `app`, `rollouts_pod_template_hash`만 application label
계약으로 보존하며 임의 Kubernetes label을 복사하지 않습니다.

신규 Mini Commerce의 Secret shell은 `module.mini_commerce_secrets`가 runtime·database·migration으로
분리합니다. 실제 이름·ARN·대상 Kubernetes Secret·reader IRSA는 `mini_commerce_secrets` 출력으로
연결하며, 비밀값은 Terraform으로 전달하지 않습니다. 기존 `sample_app_*` state 주소와 Secret은
이전 경로의 소유권·복구 호환성을 위해 유지될 수 있습니다. 신규/기존 writer를 함께 활성화하지
않으며, [운영 통합 안내](runbooks/enterprise-integration.md)의 전환 절차를 따릅니다.

기존 Argo CD Application이 External Secrets를 관리 중이라면 두 writer를 동시에 켜지 않습니다.
Phase A에서 automated sync와 resources finalizer를 제거한 runtime handoff evidence를 받은 뒤 다음
검증/가져오기 절차를 실행합니다. 이 스크립트는 `terraform apply`를 실행하지 않습니다.

```bash
bash scripts/external-secrets-owner-handoff.sh validate-handoff handoff.json
bash scripts/external-secrets-owner-handoff.sh adopt \
  environments/dev/03-platform handoff.json adoption.json mini-commerce-dev
```

저장된 plan이 no-op이고 UID가 유지된 adoption evidence가 승인된 뒤에만 GitOps Phase B에서 비활성
Application을 삭제합니다. adoption evidence의 `release.before`는 승인된 handoff release 전체를
그대로 결속하고, `release.after`는 import 직후 Terraform state, Helm release/values, Kubernetes Helm
storage object·controller·CRD를 다시 조회해 구성합니다. 두 객체가 정확히 같고 Terraform owner가
exact address에 존재하며 전체 plan이 no-op일 때만 evidence를 원자적으로 게시합니다. 호출자는
`release.after`를 입력할 수 없습니다. 마지막으로 `verify-phase-b`가 Application 부재와 live release
identity/UID 불변을 확인합니다.

## 3. prod 클러스터

`environments/prod`에서 같은 네 계층을 순서대로 실행합니다. prod VPC는 기본 example의
`10.1.0.0/16`으로 dev와 겹치지 않습니다. prod bootstrap은 `argocd/bootstrap/prod`만
읽으며 `envs/prod/values.yaml`을 `Rollout`으로 렌더링합니다.

신규 Mini Commerce에서는 native Istio 경로를 확인합니다.

```bash
kubectl -n app-prod get rollout mini-commerce
kubectl -n app-prod get analysistemplate
kubectl -n app-prod get virtualservice
```

Prod 승격은 성공한 앱 CI의 run/attempt와 Dev digest를 선택하고 승인 PR을 만든다. Dev 상태와 지표를 확인한 뒤 승인하고 Prod를 수동 sync한다.

## GitHub governance state

`terraform/github-governance`는 기존 `argocd-gitops` repository를 declarative import한 뒤 다음
delivery 설정과 Ruleset을 함께 관리합니다.

- auto-merge와 squash merge 활성화
- merge commit과 rebase merge 비활성화
- merge 후 branch 자동 삭제
- Dependabot vulnerability alerts 활성화
- `main-protection` Ruleset

`prevent_destroy=true`이므로 이 Terraform root로 repository를 삭제하지 못합니다. Plan에서 기존
repository import와 위 설정 외의 예상하지 않은 변경이 없는지 확인한 뒤 apply합니다.

## 제거와 비용

핵심 요약: 리소스 정리는 별도 변경 작업이다. 이 저장소에는 전체 환경을 자동 폐기하는 도구가 없다.

Argo CD sync/prune 영향, RDS/PVC/backup 보존, DNS와 IAM 의존성을 확인하고 root별 destroy plan을 검토한다. `prevent_destroy`와 보존 정책을 일괄 해제하지 않는다. [운영 절차](runbook.md)를 따른다.

## 검증 범위

```bash
terraform fmt -check -recursive
terraform -chdir=<root> init -backend=false
terraform -chdir=<root> validate
```

이 정적 검증은 AWS apply, Gateway `Programmed`, AMP ingestion, 실제 Canary 성공을 증명하지
않습니다. 해당 항목은 Argo CD·kubectl·AWS CLI와 실제 서비스 요청으로 별도 확인합니다.

운영 테스트 실행 방법과 검증 한계는 [테스트 안내](testing.md)를 참고하십시오.
