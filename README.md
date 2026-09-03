# EKS Infrastructure — CI/CD GitOps course

이 저장소는 dev와 prod를 **서로 다른 EKS 클러스터**로 만드는 Terraform 전체 코드입니다.
먼저 dev의 네 계층을 완성하고 `DEV_READY`를 확인한 뒤에만 prod를 만듭니다. 두 환경의
Terraform state, VPC CIDR, Argo CD instance, AMP workspace가 분리됩니다.

Shared identity는 전용 계정의 Terraform-owned GitHub OIDC provider와 기존 account-wide provider를
구분합니다. 기존 provider는 삭제하지 않고 external mode로 참조하며, ECR lifecycle 변경 전에는
모든 rollback image-index digest가 보존되는지 preview gate로 확인합니다.

## 배포 순서

```text
[shared, 한 번]
GitHub OIDC + ECR
        │
        ▼
[dev cluster]
01-network → 02-eks → 03-platform → 04-workloads/argocd → DEV_READY
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
| 03-platform | Gateway CRD, AWS LBC, External Secrets, AMP/ADOT, IRSA, `course-gp3`, Ch23 snapshot add-on (opt-in) | sample-app/PVC |
| 04-workloads | Argo CD, Argo Rollouts, Gateway plugin, bootstrap Application | app manifest 원본 |

## 전제 도구

- Terraform 1.15.9
- AWS CLI 2
- kubectl 1.36 계열
- Helm 4.2.4
- AWS 계정과 Route53 hosted zone

버전 계약은 [versions.lock.yaml](./versions.lock.yaml)에 있습니다.

과정 시작 시 두 검증 Region 중 하나를 선택하고 모든 Terraform root와 AWS CLI에서 같은 값을
사용합니다. 아래 예시는 서울이며 버지니아 북부를 선택하면 `us-east-1`로 바꿉니다.

```bash
export AWS_REGION="ap-northeast-2"
export STATE_BUCKET_NAME="replace-with-your-state-bucket"
```

## 0. 공통 GitHub OIDC와 ECR

```bash
cd terraform/iam-github-oidc
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars`에서 GitHub owner/repository subject를 실제 값으로 교체한 다음 실행합니다.

```bash
terraform init -reconfigure \
  -backend-config="bucket=$STATE_BUCKET_NAME" \
  -backend-config="key=shared/iam-github-oidc/terraform.tfstate" \
  -backend-config="region=$AWS_REGION" \
  -backend-config="encrypt=true" \
  -backend-config="use_lockfile=true"
terraform plan -out=tfplan
terraform apply tfplan
terraform output
```

정상 결과에서 다음 값을 기록합니다.

- `sample_app_push_role_arn` → sample-app의 `AWS_ROLE_ARN` variable
- `sample_app_ecr_repository_url` → GitOps values의 `image.repository`
- `infra_role_arn` → EKS-infra workflow role

## 1. dev 클러스터

각 계층에서 example을 복사하고 placeholder를 교체합니다. 실제 `.tfvars`는 gitignore 대상입니다.

```bash
cp environments/dev/01-network/terraform.tfvars.example environments/dev/01-network/terraform.tfvars
cp environments/dev/02-eks/terraform.tfvars.example environments/dev/02-eks/terraform.tfvars
cp environments/dev/03-platform/terraform.tfvars.example environments/dev/03-platform/terraform.tfvars
cp environments/dev/04-workloads/argocd/terraform.tfvars.example environments/dev/04-workloads/argocd/terraform.tfvars
```

계층별 실행 패턴은 같습니다. 아래에서 `<layer>`와 backend 파일만 바꿉니다.

```bash
terraform -chdir=environments/dev/<layer> init \
  -backend-config=../config/<backend>.tfbackend \
  -backend-config="bucket=$STATE_BUCKET_NAME" \
  -backend-config="region=$AWS_REGION" \
  -reconfigure

terraform -chdir=environments/dev/<layer> plan -out=tfplan
terraform -chdir=environments/dev/<layer> apply tfplan
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

`03-platform`은 EBS CSI Driver와 non-default `course-gp3` StorageClass도 만듭니다. StorageClass는
encrypted gp3, volume expansion, `WaitForFirstConsumer`를 사용합니다. Ch01~Ch14에서는 PVC가
없으므로 EBS volume 비용이 추가되지 않고, Ch14 이후 Stateful 실습에서 처음 provisioning됩니다.

Platform controller는 Chapter가 처음 필요로 할 때만 활성화합니다.

| 시점 | `03-platform` flag | 결과 |
| --- | --- | --- |
| Ch03 baseline | `enable_external_secrets=true` | Terraform이 External Secrets의 유일한 writer |
| Ch12 | `enable_reloader=true` | runtime secret rotation이 Rollout의 새 Pod를 생성 |
| Ch16 Dev | `enable_k6_operator=true`, `enable_amp_alerting=true` | 제한된 부하와 SLO/alert 검증 |
| Prod | `enable_k6_operator=false` | 강의 load controller 설치 차단 |
| Ch23 | `enable_snapshot_controller=true` | EKS managed `snapshot-controller`와 Retain `VolumeSnapshotClass` 설치 |

ADOT X-Ray trace 입력은 애플리케이션과 OTLP/HTTP protobuf 계약을 사용합니다. `enable_adot_xray=true`일
때 platform output의 `otlp_http_traces_endpoint`를 `OTEL_EXPORTER_OTLP_ENDPOINT`에 그대로
설정하며, endpoint는 `:4318/v1/traces`, protocol은 `http/protobuf`입니다. gRPC `4317` 입력은
이 과정의 애플리케이션 계약에 포함하지 않습니다.

Secrets Manager에는 `sample-app-runtime`과 `sample-app-db` 두 shell만 만들며 값은 Terraform으로
전달하지 않습니다. application reader IRSA는 두 exact ARN의 `DescribeSecret`/`GetSecretValue`만
허용합니다. Reloader 대상은 runtime secret뿐이며 DB secret rotation은 application Pod reload
증거로 인정하지 않습니다.

기존 Argo CD Application이 External Secrets를 관리 중이라면 두 writer를 동시에 켜지 않습니다.
Phase A에서 automated sync와 resources finalizer를 제거한 runtime handoff evidence를 받은 뒤 다음
검증/가져오기 절차를 실행합니다. 이 스크립트는 `terraform apply`를 실행하지 않습니다.

```bash
bash scripts/external-secrets-owner-handoff.sh validate-handoff handoff.json
bash scripts/external-secrets-owner-handoff.sh adopt \
  environments/dev/03-platform handoff.json adoption.json course-dev
```

저장된 plan이 no-op이고 UID가 유지된 adoption evidence가 승인된 뒤에만 GitOps Phase B에서 비활성
Application을 삭제합니다. 마지막으로 `verify-phase-b`가 Application 부재와 controller/CRD UID
불변을 확인합니다.

## 2. DEV_READY 게이트

다음 명령이 모두 정상이어야 prod를 시작합니다.

```bash
aws eks update-kubeconfig --region "$AWS_REGION" --name dev-playdevops-eks

kubectl get nodes
kubectl -n kube-system get deploy aws-load-balancer-controller
kubectl -n argocd get pods
kubectl -n argo-rollouts get pods
kubectl -n external-secrets get pods
kubectl -n app-dev get deploy,pod,hpa,externalsecret,gateway,httproute
```

정상 기준:

- 모든 EKS node `Ready`
- `ExternalSecret`의 `Ready=True`
- `Gateway`의 `Programmed=True`
- Argo CD Application `Synced/Healthy`
- sample-app `/version`의 digest 앞 12자리가 GitOps values와 일치
- AMP에서 `http_requests_total{namespace="app-dev"}` 조회 가능

DEV_READY의 workflow identity는 sample-app의 canonical `ci` workflow에 결속합니다. `runId`는
숫자로 파싱하지 않고 digit string으로 보존하며, `runUrl`의 마지막 run ID와 일치해야 합니다.
`runUrl`은 `https://github.com/<owner>/cicd-course-sample-app/actions/runs/<runId>` 형식이어야
하고, attestation URL은 같은 repository의 `attestations/<githubId>`로 결속합니다. multi-architecture
image는 두 platform을 모두 포함해야 합니다.

```json
{
  "workflow": {
    "name": "ci",
    "event": "push",
    "runId": "<digits>",
    "runAttempt": 1,
    "runUrl": "https://github.com/play-builder/cicd-course-sample-app/actions/runs/<digits>"
  },
  "image": {
    "platforms": ["linux/amd64", "linux/arm64"]
  },
  "attestation": {
    "githubId": "<githubId>",
    "githubUrl": "https://github.com/<owner>/cicd-course-sample-app/attestations/<githubId>"
  }
}
```

Ch15와 Ch16 runtime evidence는 EKS-infra가 호출자가 지정한 임시 경로에만 원자적으로 씁니다.
`argocd-gitops/evidence/dev` 경로에는 직접 쓰지 않으며, 사람이 검토한 뒤 GitOps 변경으로 반영합니다.
fixture/fake CLI가 활성화된 실행은 항상 `STATIC`이고 promotion input으로 사용할 수 없습니다.

```bash
bash scripts/course-check.sh ch15 <context> <namespace> <application> \
  <source-repository> <source-sha> <image-repository> <image-digest> \
  <gitops-revision> <cluster-arn> <region> --output <temporary-path>

ALERT_DELIVERY_EVIDENCE=<firing-and-resolved.json> \
bash scripts/course-check.sh ch16 <ch15-evidence> <context> <k6-namespace> \
  <testrun> <amp-workspace-id> <sns-topic-arn> <region> --output <temporary-path>
```

Ch15는 Stateless deployment 상태만 증명합니다. DB endpoint, DB query span, PostgreSQL PVC는 Ch20
이후 evidence에서만 다룹니다. Ch16은 현재 Ch15 identity와 동일한 source/image/GitOps/cluster/Region,
k6 controller와 bounded TestRun, AMP query, confirmed SNS subscription, Firing/Resolved 전달을 모두
확인해야 `course.dev-slo/v1`을 생성합니다.

## 3. prod 클러스터

`environments/prod`에서 같은 네 계층을 순서대로 실행합니다. prod VPC는 기본 example의
`10.1.0.0/16`으로 dev와 겹치지 않습니다. prod bootstrap은 `argocd/bootstrap/prod`만
읽으며 `envs/prod/values.yaml`을 `Rollout`으로 렌더링합니다.

prod에서 추가로 확인합니다.

```bash
kubectl -n app-prod get rollout sample-app
kubectl -n app-prod get analysistemplate sample-app-success-rate
kubectl -n argo-rollouts logs deploy/argo-rollouts | rg 'gatewayAPI|plugin'
```

## 4. Ch14 이후 Stateful runtime 검증

GitOps의 `stateful-values.yaml`을 활성화하고 Argo CD 동기화가 끝난 뒤 consolidated checker로
StorageClass, PVC, PostgreSQL, migration Job, application Pod, 상품·재고·멱등 주문 API를 함께 확인합니다.

```bash
bash scripts/course-check.sh stateful course-dev app-dev https://sample-app.dev.example.com
```

정상 종료는 `PASS: Stateful Mini Commerce...`이고, 상품 수와 첫 SKU, 상품 1번의 재고가 함께
출력됩니다. 이 검증은 secret 값을 출력하지 않습니다. 단일 replica PostgreSQL은 schema migration과
rollback을 관찰하기 위한 교육용이며 운영 HA 구성으로 간주하지 않습니다.

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

## 제거 순서와 비용

Stateful 실습을 했다면 먼저 GitOps switch를 `false`로 되돌리고 동기화해 PostgreSQL StatefulSet을
제거합니다. 그다음 PVC를 명시적으로 삭제하고 PV가 사라질 때까지 확인합니다.

```bash
kubectl --context course-dev -n app-dev get pvc -l app.kubernetes.io/component=database
kubectl --context course-dev -n app-dev delete pvc -l app.kubernetes.io/component=database
kubectl --context course-dev get pv
```

PVC 삭제는 EBS data를 되돌릴 수 없게 삭제하는 작업입니다. namespace와 label을 먼저 조회하고,
필요한 data가 없음을 확인한 후 실행합니다.

이후 클러스터는 반드시 `04 → 03 → 02 → 01` 역순으로 제거합니다. Gateway가 만든 ALB와
target group이 삭제된 것을 먼저 확인해야 VPC 삭제가 막히지 않습니다. ECR의
`force_delete=false`와 Secrets Manager의 7일 recovery window는 실수 삭제를 막기 위한
의도된 보호 장치입니다.

운영 비용이 발생하는 핵심 항목은 NAT Gateway, EKS control plane, EC2 node, ALB, AMP입니다.
교육 종료 후 `terraform plan -destroy`로 대상 범위를 검토하고, GitOps Application을 먼저
삭제한 다음 역순으로 destroy합니다.

## 검증 범위

```bash
terraform fmt -check -recursive
terraform -chdir=<root> init -backend=false
terraform -chdir=<root> validate
```

이 정적 검증은 AWS apply, Gateway `Programmed`, AMP ingestion, 실제 Canary 성공을 증명하지
않습니다. 해당 항목은 위의 `DEV_READY`와 prod runtime 명령으로 별도 확인합니다.
