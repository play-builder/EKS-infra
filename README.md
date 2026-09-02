# EKS Infrastructure — CI/CD GitOps course

이 저장소는 dev와 prod를 **서로 다른 EKS 클러스터**로 만드는 Terraform 전체 코드입니다.
먼저 dev의 네 계층을 완성하고 `DEV_READY`를 확인한 뒤에만 prod를 만듭니다. 두 환경의
Terraform state, VPC CIDR, Argo CD instance, AMP workspace가 분리됩니다.

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
| 03-platform | Gateway CRD, AWS LBC, ExternalDNS, AMP, ADOT, IRSA | sample-app |
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

## 제거 순서와 비용

클러스터를 제거할 때는 반드시 `04 → 03 → 02 → 01` 역순입니다. Gateway가 만든 ALB와
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
