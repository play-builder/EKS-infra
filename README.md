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

- Terraform >= 1.12.0
- AWS CLI (configured)
- kubectl
- Helm 3.x

### Deploy

Deploy layers **in order** (01 → 02 → 03 → 04). Each layer depends on the previous one.

> Replace `{env}` with `dev` or `prod`.

#### Step 1: Network

```bash
cd environments/{env}/01-network
rm -rf .terraform .terraform.lock.hcl
terraform init -input=false -backend-config=../config/network.tfbackend -reconfigure
terraform fmt -recursive
terraform validate
terraform plan -out=tfplan
terraform apply -auto-approve tfplan
```

#### Step 2: EKS

```bash
cd environments/{env}/02-eks
rm -rf .terraform .terraform.lock.hcl
terraform init -input=false -backend-config=../config/eks.tfbackend -reconfigure
terraform fmt -recursive
terraform validate
terraform plan -out=tfplan
terraform apply -auto-approve tfplan
```

After EKS is deployed, update your kubeconfig:

```bash
aws eks update-kubeconfig \
  --region us-east-1 \
  --name "$(terraform output -raw cluster_name)"

kubectl get nodes
```

#### Step 3: Platform

```bash
cd environments/{env}/03-platform
rm -rf .terraform .terraform.lock.hcl
terraform init -input=false -backend-config=../config/platform.tfbackend -reconfigure
terraform fmt -recursive
terraform validate
terraform plan -out=tfplan
terraform apply -auto-approve tfplan
```

Verify add-ons:

```bash
kubectl get pods -n kube-system
```

#### Step 4: Workloads

```bash
cd environments/{env}/04-workloads/app-tier
rm -rf .terraform .terraform.lock.hcl
terraform init -input=false -backend-config=../../config/app-tier.tfbackend -reconfigure
terraform fmt -recursive
terraform validate
terraform plan -out=tfplan
terraform apply -auto-approve tfplan
```

### Destroy

> **⚠️ Destroy in REVERSE order only (04 → 03 → 02 → 01).** Never destroy Network first — it will leave orphaned resources.

#### Step 1: Workloads

```bash
cd environments/{env}/04-workloads/app-tier
rm -rf .terraform .terraform.lock.hcl
terraform init -input=false -backend-config=../../config/app-tier.tfbackend -reconfigure
terraform destroy -auto-approve
```

#### Step 2: Platform

```bash
cd environments/{env}/03-platform
rm -rf .terraform .terraform.lock.hcl
terraform init -input=false -backend-config=../config/platform.tfbackend -reconfigure
terraform destroy -auto-approve
```

#### Step 3: EKS

```bash
cd environments/{env}/02-eks
rm -rf .terraform .terraform.lock.hcl
terraform init -input=false -backend-config=../config/eks.tfbackend -reconfigure
terraform destroy -auto-approve
```

#### Step 4: Network

```bash
cd environments/{env}/01-network
rm -rf .terraform .terraform.lock.hcl
terraform init -input=false -backend-config=../config/network.tfbackend -reconfigure
terraform destroy -auto-approve
```

## Documentation

- [Architecture](./docs/architecture.md) - Detailed architecture documentation
- [Runbook](./docs/runbook.md) - Operations manual

## Tech Stack

| Component                 | Version   | Description            |
| ------------------------- | --------- | ---------------------- |
| Terraform                 | >= 1.12.0 | IaC                    |
| EKS                       | 1.35      | Kubernetes             |
| AWS Provider              | ~> 5.87.0 | Terraform Provider     |
| Helm Provider             | ~> 2.17.0 | Helm Charts Management |
| Cluster Autoscaler        | 9.55.0    | Node auto-scaling      |
| Metrics Server            | 3.13.0    | Pod metrics for HPA    |
| ADOT Collector            | EKS Addon | Metrics collection     |
| Amazon Managed Prometheus | -         | Metrics storage        |
| Amazon Managed Grafana    | -         | Dashboards & Alerts    |
