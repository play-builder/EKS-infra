# EKS Infrastructure (Terraform)

Production-Ready Amazon EKS cluster built and managed with Terraform.

## Key Features

- **Layer-based Architecture**: Network → EKS → Platform → Workloads 4-stage separation to minimize Blast Radius
- **IRSA (IAM Roles for Service Accounts)**: Pod-level least privilege principle
- **Partial Backend Configuration**: Environment-specific state separation and CI/CD pipeline compatibility
- **Multi-Environment Support**: Independent dev/prod environment operation

![EKS Architecture](./images/eks-architecture.png)

### Layer Structure

```
Layer 1: Network        Layer 2: EKS           Layer 3: Platform       Layer 4: Workloads
┌──────────────┐       ┌──────────────┐       ┌──────────────┐        ┌──────────────┐
│ VPC          │       │ EKS Cluster  │       │ ALB Controller│       │ Applications │
│ Subnets      │──────▶│ Node Groups  │──────▶│ EBS CSI      │───────▶│ Ingress      │
│ NAT Gateway  │       │ OIDC Provider│       │ External DNS │        │ HPA          │
│ Route Tables │       │ Bastion Host │       │ Autoscaler   │        │              │
└──────────────┘       └──────────────┘       └──────────────┘        └──────────────┘
     ▲                       ▲                      ▲                       ▲
     │                       │                      │                       │
  network.              eks.tfbackend          platform.              app-tier.
  tfbackend                                    tfbackend               tfbackend
```

## Directory Structure

```
.
├── environments/                    # Environment-specific Root Modules
│   ├── dev/
│   │   ├── config/                  # Partial Backend Configuration
│   │   │   ├── network.tfbackend
│   │   │   ├── eks.tfbackend
│   │   │   ├── platform.tfbackend
│   │   │   └── app-tier.tfbackend
│   │   ├── 01-network/              # Layer 1: VPC, Subnets
│   │   ├── 02-eks/                  # Layer 2: EKS Cluster, Node Groups
│   │   ├── 03-platform/             # Layer 3: Addons (IRSA-based)
│   │   └── 04-workloads/
│   │       └── app-tier/            # Layer 4: Applications
│   └── prod/                        # Production (same structure)
│
├── modules/                         # Reusable Terraform Modules
│   ├── networking/
│   │   ├── vpc/                    # VPC, Subnets, NAT, IGW
│   │   └── security-groups/
│   ├── compute/
│   │   └── bastion/                 # Bastion Host
│   ├── eks/
│   │   ├── cluster/                 # EKS Control Plane + OIDC
│   │   ├── node-group/              # Managed Node Groups
│   │   └── fargate-profile/         # Fargate Profile (optional)
│   ├── addons/
│   │   ├── aws-load-balancer-controller/
│   │   ├── ebs-csi-driver/
│   │   ├── external-dns/
│   │   ├── cluster-autoscaler/
│   │   ├── metrics-server/
│   │   └── container-insights/
│   ├── iam/
│   │   ├── irsa/                    # IRSA common pattern
│   │   └── user-roles/
│   ├── kubernetes/
│   │   ├── app/                     # Deployment + Service
│   │   └── ingress/
│   │       └── alb-ssl/             # ALB Ingress + ACM
│   └── security/
│       └── acm/                     # ACM Certificate
│
├── scripts/
│   ├── deploy.sh                    # Full deployment script
│   ├── destroy.sh                   # Full destroy script
│   └── backup-state.sh
│
├── terraform/
│   └── iam-github-oidc/             # GitHub Actions OIDC configuration
│
├── docs/
│   ├── architecture.md              # Detailed architecture documentation
│   └── runbook.md                   # Operations manual
│
└── .github/
    └── workflows/
        ├── terraform-plan.yml       # Plan on PR
        └── terraform-apply.yml      # Apply on merge to main
```

## Quick Start

### Prerequisites

- Terraform >= 1.5.0
- AWS CLI (configured)
- kubectl
- Helm 3.x

### Deploy

```bash
# Full deployment (01-network → 02-eks → 03-platform → 04-workloads)
./scripts/deploy.sh dev

# Deploy specific layer only
./scripts/deploy.sh dev -l 02-eks

# Dry-run (output commands only)
./scripts/deploy.sh dev -d
```

### Destroy

```bash
# Full destroy (reverse: 04 → 03 → 02 → 01)
./scripts/destroy.sh dev

# Destroy specific layer only
./scripts/destroy.sh dev -l 03-platform
```

## Documentation

- [Architecture](./docs/architecture.md) - Detailed architecture documentation
- [Runbook](./docs/runbook.md) - Operations manual

## Tech Stack

| Component     | Version   | Description            |
| ------------- | --------- | ---------------------- |
| Terraform     | >= 1.5.0  | IaC                    |
| EKS           | 1.31      | Kubernetes             |
| AWS Provider  | ~> 5.87.0 | Terraform Provider     |
| Helm Provider | ~> 2.17.0 | Helm Charts Management |
