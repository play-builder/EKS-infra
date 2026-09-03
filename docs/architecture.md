# EKS CI/CD GitOps architecture

## 핵심 요약

dev와 prod는 VPC, EKS, Argo CD, AMP, Terraform state가 분리된 두 클러스터입니다. 공통 영역은
GitHub OIDC와 immutable ECR뿐이며, prod는 dev의 `DEV_READY` 판정 뒤 생성합니다.

## 구성과 흐름

```text
                       ┌──────────── shared AWS account ────────────┐
GitHub Actions ─OIDC─▶ │ scoped IAM roles ─▶ immutable ECR index    │
                       └──────────────────────┬──────────────────────┘
                                              │ same digest
                 ┌────────────────────────────┴────────────────────────────┐
                 ▼                                                         ▼
        dev VPC / EKS                                             prod VPC / EKS
  Deployment + Auto-Sync                                  Rollout + approved promotion
  dev Argo CD / dev AMP                                   prod Argo CD / prod AMP
                 │                                                         │
                 └────────── DEV_READY gate ───────────────────────────────▶
```

이 그림에서 봐야 할 핵심은 prod에서 이미지를 재빌드하지 않고, dev에서 검증한 ECR index
digest를 승격한다는 점입니다.

## 네 계층의 소유권

| 계층 | 책임 |
| --- | --- |
| `01-network` | VPC, public/private subnet, NAT, routing |
| `02-eks` | EKS 1.36, managed node group, Access Entry, cluster OIDC |
| `03-platform` | Gateway API CRD, AWS LBC, ExternalDNS, External Secrets, AMP, ADOT |
| `04-workloads/argocd` | Argo CD, Argo Rollouts, Gateway API plugin, bootstrap Application |

애플리케이션 desired state는 Terraform에 넣지 않습니다. Terraform은 Argo CD bootstrap까지만
만들고, 이후 workload lifecycle은 `argocd-gitops` 저장소가 소유합니다.

## 권한 경계

```text
GitHub sample-app workflow ─OIDC─▶ ECR push role
GitHub infra workflow      ─OIDC─▶ Terraform role
EKS worker node role       ──────▶ ECR pull only
ADOT ServiceAccount        ─IRSA─▶ AMP remote write
Rollouts ServiceAccount    ─IRSA─▶ AMP QueryMetrics
External Secrets SA        ─IRSA─▶ Secrets Manager read
```

이 그림에서 봐야 할 핵심은 image pull이 application ServiceAccount IRSA가 아니라 kubelet의
worker node role을 사용한다는 점입니다. Pod별 AWS API 권한은 별도 IRSA로 제한합니다.

## DEV_READY identity

DEV_READY는 sample-app canonical workflow와 immutable image platform 집합을 함께 확인합니다.
`workflow.name=ci`, `workflow.event=push`, digit string `runId`, positive integer
`runAttempt`를 사용합니다. `runUrl`은 canonical sample-app repository와 `runId`에 결속하고,
digit string `attestation.githubId`와 `attestation.githubUrl`은 같은 repository의
`attestations/<digits>`에 결속해야 합니다.

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
    "githubId": "<digits>",
    "githubUrl": "https://github.com/<owner>/cicd-course-sample-app/attestations/<digits>"
  }
}
```

## 네트워크와 가용성

- Worker node는 private subnet에 배치합니다.
- Internet-facing ALB는 public subnet을 사용합니다.
- dev는 비용을 줄이기 위해 single NAT, prod는 AZ별 NAT를 기본으로 합니다.
- Gateway API `HTTPRoute` weight는 prod Canary 중 Rollouts plugin이 수정합니다.
- HTTPS는 ACM certificate ARN을 설정한 뒤 명시적으로 활성화합니다.

## 관측성과 점진적 배포

```text
sample-app /metrics
        │ scrape
        ▼
ADOT Collector ─SigV4 remote_write─▶ AMP
                                        ▲
                                        │ native SigV4 QueryMetrics
                                 Argo Rollouts AnalysisRun
```

이 그림에서 봐야 할 핵심은 별도 `aws-sigv4-proxy`가 없다는 점입니다. ADOT와 Rollouts는 서로
다른 IRSA role을 사용하며 write/query 권한도 분리합니다.

## 검증 경계

Terraform `validate`와 Helm render는 스키마·참조 오류를 줄이지만 AWS 리소스 생성 성공,
Gateway `Programmed=True`, AMP 수집, Rollouts traffic weight 반영을 증명하지 않습니다. 해당
항목은 실제 dev 클러스터의 `DEV_READY`에서 확인해야 합니다.
