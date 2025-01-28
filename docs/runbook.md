# EKS Infrastructure Runbook

> **Minimal operational guide for Amazon EKS deployed via Terraform.** > **Audience:** DevOps / Platform Engineers

---

**Verify AWS identity:**

```bash
aws sts get-caller-identity

```

---

## 🚀 Terraform Deployment Order

**Always deploy layers in the following order.** Terraform is the single source of truth.

1. `01-network`
2. `02-eks`
3. `03-platform`
4. `04-workloads`

---

## 🔗 Connect to EKS (MANDATORY)

After the EKS layer (`02-eks`) is applied, the local kubeconfig must be updated to interact with the cluster.

**Update Kubeconfig:**

```bash
aws eks update-kubeconfig \
  --region us-east-1 \
  --name "$(terraform output -raw cluster_name)"

```

**Validate access:**

If this step is skipped, the cluster is unreachable via kubectl.

```bash
kubectl get nodes
kubectl get pods -A

```

---

## ✅ Platform Add-ons Check

After deploying `03-platform`, verify that all critical add-ons are operational.

**Check Pod Status:**

```bash
kubectl get pods -n kube-system

```

**Required components (All must be `Running`):**

- `aws-load-balancer-controller`
- `external-dns`
- `aws-ebs-csi-driver`
- `cluster-autoscaler`

---

## ⚙️ Common Day-2 Operations

### Scale Node Group (Terraform)

Modify your `variables.tf` or `tfvars`:

```hcl
node_group_desired_size = 3
node_group_min_size     = 2
node_group_max_size     = 5

```

Apply changes:

```bash
terraform apply

```

### Upgrade EKS Version

Update the version in Terraform:

```hcl
cluster_version = "1.32"

```

Apply changes (Node groups will follow automatically):

```bash
terraform apply

```

### Update Platform Add-ons

Navigate to the platform layer directory:

```bash
cd environments/dev/03-platform
terraform apply

```

---

## 🔧 Quick Troubleshooting

### `kubectl` not working

Refesh your kubeconfig token:

```bash
aws eks update-kubeconfig \
  --region us-east-1 \
  --name "$(terraform output -raw cluster_name)"

```

### Nodes not joining

Check the following:

1. Node Group status in AWS Console/CLI.
2. Subnet tags (ensure private subnets are tagged correctly).
3. `aws-auth` ConfigMap:

```bash
kubectl describe configmap aws-auth -n kube-system

```

### ALB not created

Check logs for the Load Balancer Controller:

```bash
kubectl logs -n kube-system \
  -l app.kubernetes.io/name=aws-load-balancer-controller

```

**Verify:**

- Ingress annotations are correct.
- IRSA role is correctly attached to the ServiceAccount.

---

## 🔐 CI/CD Authentication

GitHub Actions uses **OIDC** for authentication. No static AWS credentials are allowed.

**Required permissions in Workflow YAML:**

```yaml
permissions:
  id-token: write
  contents: read
```

---

## ⚠️ Safe Teardown Rule

**DESTROY IN REVERSE ORDER ONLY.**

1. `04-workloads`
2. `03-platform`
3. `02-eks`
4. `01-network`

> **WARNING:** Never destroy the `01-network` layer first. Doing so will leave orphaned resources.
