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

| Component                  | Version    | Description            |
| -------------------------- | ---------- | ---------------------- |
| Terraform                  | >= 1.12.0  | IaC                    |
| EKS                        | 1.35       | Kubernetes             |
| AWS Provider               | ~> 5.87.0  | Terraform Provider     |
| Helm Provider              | ~> 2.17.0  | Helm Charts Management |
| Cluster Autoscaler         | 9.55.0     | Node auto-scaling      |
| Metrics Server             | 3.13.0     | Pod metrics for HPA    |
| ADOT Collector             | EKS Addon  | Metrics collection     |
| Amazon Managed Prometheus  | -          | Metrics storage        |
| Amazon Managed Grafana     | -          | Dashboards & Alerts    |
