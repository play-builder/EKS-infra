# EKS 운영 Runbook

## 핵심 요약

항상 `01 → 02 → 03 → 04` 순서로 적용하고 `04 → 03 → 02 → 01` 역순으로 제거합니다.
장애 대응 전에는 AWS identity, kube context, 대상 environment를 먼저 확인합니다.

과정에서 검증한 `ap-northeast-2` 또는 `us-east-1` 중 클러스터를 만든 Region을 사용합니다.

```bash
export AWS_REGION="ap-northeast-2"
```

## 안전 확인

```bash
aws sts get-caller-identity
kubectl config current-context
kubectl cluster-info
```

prod 작업 전에는 출력의 account ID와 cluster name을 작업 티켓의 값과 대조합니다.

## 클러스터 접속

```bash
aws eks update-kubeconfig \
  --region "$AWS_REGION" \
  --name dev-playdevops-eks \
  --alias course-dev

kubectl --context course-dev get nodes
```

prod는 cluster name과 alias를 각각 `prod-playdevops-eks`, `course-prod`로 바꿉니다.

## 계층 상태 확인

```bash
terraform -chdir=environments/dev/01-network output
terraform -chdir=environments/dev/02-eks output
terraform -chdir=environments/dev/03-platform output
terraform -chdir=environments/dev/04-workloads/argocd output
```

```bash
kubectl --context course-dev -n kube-system get pods
kubectl --context course-dev -n argocd get application
kubectl --context course-dev get gateway,httproute -A
kubectl --context course-dev get externalsecret -A
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
kubectl --context course-dev describe gateway sample-app -n app-dev
kubectl --context course-dev describe httproute sample-app -n app-dev
kubectl --context course-dev -n kube-system logs \
  deploy/aws-load-balancer-controller --since=15m
```

`Accepted`, `Programmed`, `ResolvedRefs` condition과 subnet tag, LBC IRSA, Gateway CRD/controller
버전을 확인합니다. ALB가 생성됐는데 DNS만 실패하면 ExternalDNS log와 hosted-zone filter를
분리해 진단합니다.

## AMP 수집 또는 분석이 실패할 때

```bash
kubectl --context course-prod -n opentelemetry-operator-system get opentelemetrycollector
kubectl --context course-prod -n opentelemetry-operator-system logs \
  -l app.kubernetes.io/name=adot-collector-prometheus --since=15m
kubectl --context course-prod -n argo-rollouts logs deploy/argo-rollouts --since=15m
kubectl --context course-prod -n app-prod get analysisrun
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
kubectl --context course-prod -n app-prod get httproute sample-app -o yaml
kubectl --context course-prod -n app-prod get rollout sample-app -o yaml
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

1. GitOps Application과 Gateway를 삭제합니다.
2. ALB와 target group 삭제를 확인합니다.
3. `04 → 03 → 02 → 01` 순서로 destroy합니다.
4. prod와 dev state를 각각 확인합니다.

NAT Gateway, EKS control plane, EC2 node, ALB, AMP는 실행 시간 동안 비용이 발생합니다.
ECR은 `force_delete=false`, Secrets Manager는 recovery window를 사용하므로 별도 정리가 필요할
수 있습니다.
