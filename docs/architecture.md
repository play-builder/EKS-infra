# EKS Infrastructure Architecture

## Overview

This document describes the core architecture and design decisions of the **PlayDevOps EKS infrastructure**.  
The system is designed with a **4-layer model** to ensure clear ownership, security isolation, and operational scalability.

---

## Architecture Model (4 Layers)

| Layer | Responsibility |
|------|---------------|
| Layer 1 | Network (VPC, Subnets, NAT, Routing) |
| Layer 2 | EKS (Cluster, Node Groups, OIDC) |
| Layer 3 | Platform (Shared Add-ons) |
| Layer 4 | Workloads (Applications) |

---

## Layer 1 – Network

**Purpose**: Isolate traffic, control egress, and provide a secure foundation for EKS.

- VPC (`/16`)
- Public Subnets  
  - ALB, NAT Gateway, Bastion
- Private Subnets  
  - EKS Worker Nodes
- Optional DB Subnets

**NAT Strategy**
- `dev`: Single NAT Gateway (cost optimized)
- `prod`: NAT Gateway per AZ (high availability)

---

## Layer 2 – EKS

**Purpose**: Provide a managed Kubernetes control plane and scalable compute.

- Amazon EKS (Managed Control Plane)
- Managed Node Groups
- Private subnet placement only
- OIDC Provider enabled (required for IRSA)

**Access Control**
- IAM authentication + Kubernetes RBAC
- No direct public access to nodes

---

## Layer 3 – Platform

**Purpose**: Provide cluster-wide capabilities shared across workloads.

- AWS Load Balancer Controller
- External DNS (Route53)
- Cluster Autoscaler
- EBS CSI Driver

**Key Principle**
- All components use **IRSA**
- No permissions on node IAM role

---

## Layer 4 – Workloads

**Purpose**: Run application-specific resources.

- Applications (Pods)
- Ingress (ALB-backed)
- HPA (Horizontal Pod Autoscaler)

**Responsibility**
- Teams manage only this layer
- No direct AWS IAM access required

---

## Security Model

### IAM & Identity

- IRSA for all platform components
- Pod-level IAM isolation
- No static AWS credentials

### Network

- Worker nodes in private subnets only
- ALB terminates HTTPS (ACM)
- Bastion / SSM for operational access

### Audit

- CloudTrail for all AWS API calls
- Pod-level attribution via IRSA

---

## CI/CD (Terraform)

- GitHub Actions with OIDC
- IAM Role assumption (no access keys)
- Environment-isolated state

```yaml
permissions:
  id-token: write
  contents: read









































































































