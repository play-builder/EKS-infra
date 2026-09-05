# EKS CI/CD GitOps architecture

## 핵심 요약

dev와 prod는 VPC, EKS, Argo CD, AMP, Terraform state가 분리된 두 클러스터입니다. 공통 영역은
GitHub OIDC, immutable ECR와 보호 백업 루트가 공통 영역입니다. prod는 dev의 `DEV_READY`와
별도 관리계정 FinOps readiness 판정 뒤 생성합니다.

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
| `04-workloads/argocd` | Argo CD HA/SSO, native Istio용 Argo Rollouts, bootstrap Application |
| `prod/00-finops` | 별도 billing provider의 Budget/Cost Anomaly/tag 활성화 |
| `prod/03-database`, `recovery/03-database` | private RDS와 별도 PITR 대상, metadata-only secret 연결 |
| `terraform/platform-backup` | 120일 GOVERNANCE Object Lock S3와 KMS; 일반 정리에서 보존 |

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
- AWS LBC Gateway API ingress는 유지합니다. Canary는 GitOps 소유 Istio
  `VirtualService`의 명명된 route를 Rollouts native Istio provider가 갱신합니다.
- Istio CNI, revision, gateway, mTLS/AuthorizationPolicy/Telemetry, application namespaces,
  Mini Commerce Rollout와 ClusterImagePolicy는 모두 GitOps 소유입니다.
- HTTPS는 ACM certificate ARN을 설정한 뒤 명시적으로 활성화합니다.

## 관측성과 점진적 배포

```text
mini-commerce management:3001 /metrics + istio-proxy:15090 /stats/prometheus
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

## Enterprise 권한과 보존 경계

워크로드 CI는 exact state/lock keys와 승인된 regional resource identity를 사용합니다.
FinOps management-account state와 백업 state는 별도 operator lane이며 workload OIDC에
Organizations/Budgets/CE 또는 백업 S3 객체 권한을 추가하지 않습니다.

플랫폼 이미지 publisher는 Mini Commerce build/attestation role과 분리됩니다. Sigstore reader는
application allowlist와 정확한 `${project_name}/platform/istio-proxyv2` repository만 읽습니다.
ECR enhanced scanning은 세 image prefix를 모두 포함합니다. RuntimeSecrets와 migration/database
bootstrap role의 payload 권한은 Terraform provisioner에 합치지 않습니다.

정리 그래프·수동 입력·검증은 [enterprise integration runbook](runbooks/enterprise-integration.md)을
따릅니다. STATIC_VERIFIED/LOCAL_VERIFIED는 실제 비용 발생, admission, restore, 알림 성공이 아닙니다.
