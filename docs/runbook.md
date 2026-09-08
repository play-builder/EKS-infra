# EKS 운영 Runbook

Enterprise root/state/IAM wiring과 보존 리소스 정리는
[enterprise integration runbook](runbooks/enterprise-integration.md)을 따릅니다.
FinOps management와 protected backup은 별도 operator lane입니다. AWS LBC가 Gateway API로
내부 ALB를 만들고 Istio ingress로 전달하며, Rollouts는 Istio VirtualService의 가중치를 관리합니다.

## 핵심 요약

적용은 `01 → 02 → 03 → 04` 순서로 수행합니다. Prod DB는 platform 출력 준비 후 별도
`03-database` root에서 구성합니다. 제거할 때는 위 retained-resource cleanup 절차에 따라
리소스별 보존 여부와 삭제 plan을 검토합니다. 전체 teardown 실행기는 제공하지 않습니다.
장애 대응 전에는 AWS identity, kube context, 대상 environment를 먼저 확인합니다.

이 저장소에서 지원하는 `ap-northeast-2` 또는 `us-east-1` 중 클러스터를 만든 Region을 사용합니다.

```bash
export AWS_REGION="ap-northeast-2"
export AWS_PROFILE="mini-commerce"
```

## 안전 확인

```bash
aws sts get-caller-identity --region "$AWS_REGION" --profile "$AWS_PROFILE"
kubectl config current-context
kubectl cluster-info
```

prod 작업 전에는 출력의 account ID와 cluster name을 작업 티켓의 값과 대조합니다.

## Reviewed Terraform apply 설정

계정별 GitHub environment와 private EKS에 도달하는 runner를 [Terraform CI 운영 설정](runbooks/terraform-ci.md)에 따라 준비합니다.
Plan과 apply는 별도 OIDC role을 사용합니다. Apply environment `dev`, `production`, `recovery`에는
required reviewer와 self-review 차단을 설정합니다.

Apply job은 live STS account, source SHA, backend root/key, Terraform executable/version, tracked provider
lock, plan digests와 GitHub environment approval history가 모두 일치할 때만 저장된 binary plan을
실행합니다. `STATE_BUCKET_NAME`은 dispatch input이 아니라 environment-managed Variable이므로 state
선택을 실행자가 임의로 바꿀 수 없습니다.

## 클러스터 접속

```bash
aws eks update-kubeconfig \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE" \
  --name dev-playdevops-eks \
  --alias mini-commerce-dev

kubectl --context mini-commerce-dev get nodes
```

prod는 cluster name과 alias를 각각 `prod-playdevops-eks`, `mini-commerce-prod`로 바꿉니다.

## 계층 상태 확인

```bash
terraform -chdir=environments/dev/01-network output
terraform -chdir=environments/dev/02-eks output
terraform -chdir=environments/dev/03-platform output
terraform -chdir=environments/dev/04-workloads/argocd output
```

## Production network egress

`environments/prod/01-network` requires `production_nat_topology = "per_az"`: each selected AZ has its
own NAT Gateway and private route table. The module also delivers `ALL` VPC Flow Logs to
`/aws/vpc/<name>/flow-logs`; retain the log group and delivery role during incident investigation. The
log-group KMS key is owned by the network root's log-key module.

## Private EKS operator access

Production API access is private-only. Use the `operator_access` SSM instance in a private subnet and the
customer-managed EKS operator role; the production node group and operator instance have no SSH key or
public IP. The selected AMI must be Amazon Linux 2023 with SSM Agent. Resolve it from the public parameter
`/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64` for the selected Region.

The SSO permission set is a trust principal only; Terraform does not attach policies to the protected
`AWSReservedSSO_*` role. `scripts/prod-operator-access-check.sh --execute` sends an SSM Run Command, assumes
the customer-managed role on the instance, checks the exact cluster ARN, and records a successful
`kubectl auth can-i get pods -n platform-system` result before an operator change.

```bash
kubectl --context mini-commerce-dev -n kube-system get pods
kubectl --context mini-commerce-dev -n argocd get application
kubectl --context mini-commerce-dev get gateway,httproute -A
kubectl --context mini-commerce-dev get externalsecret -A
```

## Nodes가 join하지 못할 때

```bash
aws eks describe-nodegroup \
  --region "$AWS_REGION" \
  --cluster-name dev-playdevops-eks \
  --nodegroup-name dev-playdevops-node-group
```

확인 순서:

1. Node group health issue code
2. private subnet route와 NAT egress
3. node IAM role의 EKS worker/ECR pull policy
4. security group의 cluster-to-node 통신
5. EKS Access Entry는 사용자 접근용이며 node bootstrap 문제와 혼동하지 않음

## Gateway가 Programmed되지 않을 때

```bash
kubectl --context mini-commerce-dev describe gateways.gateway.networking.k8s.io mini-commerce-mesh -n istio-system
kubectl --context mini-commerce-dev describe httproutes.gateway.networking.k8s.io mini-commerce-mesh -n istio-system
kubectl --context mini-commerce-dev -n kube-system logs \
  deploy/aws-load-balancer-controller --since=15m
```

`Accepted`, `Programmed`, `ResolvedRefs` condition과 subnet tag, LBC IRSA, Gateway CRD/controller
버전을 확인합니다. ALB가 생성됐는데 DNS만 실패하면 ExternalDNS log와 hosted-zone filter를
분리해 진단합니다.

## AMP 수집 또는 분석이 실패할 때

```bash
kubectl --context mini-commerce-prod -n opentelemetry-operator-system get opentelemetrycollector
kubectl --context mini-commerce-prod -n opentelemetry-operator-system logs \
  -l app.kubernetes.io/name=adot-collector-prometheus --since=15m
kubectl --context mini-commerce-prod -n argo-rollouts logs deploy/argo-rollouts --since=15m
kubectl --context mini-commerce-prod -n app-prod get analysisrun
```

- ADOT: `aps:RemoteWrite` IRSA와 workspace endpoint 확인
- Rollouts: `aps:QueryMetrics` IRSA와 native SigV4 region 확인
- PromQL: 최신 ReplicaSet의 `rollouts_pod_template_hash` label과 request rate 확인
- `Error`: 인증·timeout·query 문제, `Failed`: 측정값이 threshold 미달인 문제로 구분

분석 장애를 이유로 바로 수동 승격하지 않습니다. 실제 서비스 정상성과 지표 경로 장애가
분리 확인되고 incident commander가 승인한 경우에만 다음 명령을 사용합니다.

```bash
kubectl argo rollouts promote sample-app -n app-prod
```

## OutOfSync 반복

HPA가 활성화된 chart는 `spec.replicas`를 렌더하지 않습니다. prod Canary 동안 Rollouts plugin이
수정하는 `HTTPRoute.spec.rules`만 조건부로 ignore합니다. 리소스 전체를 ignore하지 않습니다.

```bash
argocd app diff sample-app-prod
kubectl --context mini-commerce-prod -n app-prod get httproute sample-app -o yaml
kubectl --context mini-commerce-prod -n app-prod get rollout sample-app -o yaml
```

## 안전한 rollback

GitOps desired state가 권위입니다. 정상 digest 커밋을 되돌린 후 Argo CD가 동기화하도록 합니다.

```bash
git log --oneline -- envs/prod/values.yaml
git revert <bad-promotion-commit>
```

즉시 트래픽을 안정 ReplicaSet으로 돌려야 할 때:

```bash
kubectl argo rollouts abort sample-app -n app-prod
kubectl argo rollouts status sample-app -n app-prod --watch
```

CLI 조치는 긴급 복구이며 Git의 desired state도 반드시 일치시켜 drift를 제거합니다.

## Upgrade 원칙

EKS는 한 minor씩 올리고 control plane → add-on compatibility → node group 순으로 검증합니다.
현재 계약 버전은 `versions.lock.yaml`을 수정하고, dev에서 runtime 검증한 뒤 prod PR로
승격합니다. runbook에 버전 숫자를 중복 하드코딩하지 않습니다.

## 제거와 비용

핵심 요약: 앱 종료와 인프라 폐기는 별도 승인 작업이다. root별 Terraform plan으로 범위를 확인한다.

1. Argo CD 자동 sync를 동결하고 업무 트래픽·배치·외부 쓰기를 중지한다.
2. RDS backup/PITR, S3/KMS, Secret, PVC/PV/snapshot 보존 여부와 소유 계정을 확인한다.
3. 앱을 먼저 제거하고 controller·로드밸런서·volume attachment 종료를 확인한다.
4. root별 `terraform plan -destroy -out=destroy.tfplan`을 검토한다. 검토한 binary plan만 적용한다.
5. EKS/VPC 제거 후 ECR·NAT·EBS·snapshot·RDS·backup의 잔여 비용을 AWS에서 확인한다.

전체 계정을 묶은 자동 teardown은 제공하지 않는다. 보존 리소스를 삭제하려면 별도 데이터 폐기 승인이 필요하다.

## EKS와 노드 변경

핵심 요약: Terraform plan과 EKS 지원 버전을 확인하고, 실제 node 상태와 rollout 결과를 확인한다.

```bash
kubectl get nodes -o wide
kubectl get pods -A --field-selector=status.phase!=Running
kubectl get pdb -A
```

업그레이드는 지원되는 minor 순서대로 진행한다. EKS upgrade insight, addon 호환성, 노드 AMI release, AZ별 여유 용량과 PDB를 확인한다. drain을 강제로 우회하지 않는다.

## Argo HA, SSO and secret bootstrap

The 04-workloads/argocd roots move the existing Helm address to module.argocd with
a static moved block, retain ExternalSecret/VolumeSnapshot Lua health checks and
leave the Rollouts Gateway plugin until the coordinated GitOps native Istio cutover.
Prod requires 3 nodes/AZs, four controller replica counts >=2, Redis HA and PDBs.
Dev accepts one replica/non-HA. Configure the HTTPS public URL and its IdP callback.

Terraform creates three empty Secrets Manager shells and an exact IRSA reader,
ServiceAccount and namespace SecretStore. GitOps owns their ExternalSecrets and
subscriptions. Set source JSON properties out of Terraform using the argocd output.
Bootstrap uses the public GitOps repository. Private bootstrap needs a pre-existing
credential and is not supported by this path. Built-in admin remains enabled until
actual SSO login and admin/readonly authorization are verified.

Notifications use on-sync-failed, on-health-degraded, on-sync-status-unknown and
on-deployed. PagerDuty v2 maps platform-prod through serviceKeys to the secret
reference; successful deployment goes to Slack/platform-deployments. See
[official service format](https://argo-cd.readthedocs.io/en/stable/operator-manual/notifications/services/pagerduty_v2/).

checks production replica/node/AZ distribution, PDBs, projected-secret metadata
hashes and RBAC. It never records Secret data. Static render and this read-only
collector do not prove an interactive corporate OIDC login; record that separately.
## Sigstore and ECR prerequisites

03-platform installs policy-controller 0.10.5/0.13.1 with immutable controller and
cleanup images, an exact ECR read-only IRSA role, fail-closed webhook and bounded
HTTPS/API/DNS egress. Supply current destination CIDRs; changing public service IPs
requires updating the reviewed egress list. This is not DNS-based egress enforcement.
The vendored chart CRDs carry no policy instances. GitOps alone owns TrustRoot,
ClusterImagePolicy and namespace opt-in; Dev warn/Prod enforce are GitOps inputs.

Use sigstore-controller-check.sh for controller/CRD readiness. The admission
preflight requires a pre-existing GitOps-owned dedicated drill namespace with
opt-in, then submits two digest-pinned server-dry-run Pods. It verifies signed
allow and Sigstore webhook unsigned deny. No Pods persist; scheduling/image-pull
and application rollout are not tested by this admission check.

ecr-scanning-status-check.sh validates actual regional registry rules and image
scan identity/status; ACTIVE/COMPLETE does not mean vulnerability-free. Scanning
never substitutes for attestation verification. ecr-scanning-owner-handoff.sh only
checks a saved plan for destructive registry transitions; operators perform the
reviewed import/state-rm procedure in the IAM root guide.

03-platform owns new runtime/DML/DDL empty secret containers at
ENV-PROJECT/mini-commerce/{runtime,database,migration}. Runtime reader can read
runtime+database; the separate migration reader can read migration only. Output
application_credentials supplies database/migration ARN/name to the future database
root, avoiding duplicate secret ownership. Secret values, actual DB users and
privileges are provisioned outside Terraform. Legacy consumers remain on their
existing SecretStore until the explicit GitOps cutover.
