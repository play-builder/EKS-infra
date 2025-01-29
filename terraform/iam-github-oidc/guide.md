# 1. Create and navigate to the directory

mkdir -p terraform/iam-github-oidc
cd terraform/iam-github-oidc

# 2. Create the files above and run Terraform

terraform init
terraform plan
terraform apply

# 3. Copy the output ARN

terraform output github_actions_role_arn

# Example: arn:aws:iam::123456789012:role/GitHubActionsRole

# 4. Save to GitHub Secrets

# Repository Settings → Secrets → Actions → New repository secret

# Name: AWS_ROLE_ARN

# Value: <ARN copied above>
