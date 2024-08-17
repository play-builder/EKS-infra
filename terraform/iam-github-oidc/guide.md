# 1. 디렉토리 생성 및 이동

mkdir -p terraform/iam-github-oidc
cd terraform/iam-github-oidc

# 2. 위 파일들 생성 후 Terraform 실행

terraform init
terraform plan
terraform apply

# 3. 출력된 ARN 복사

terraform output github_actions_role_arn

# 예: arn:aws:iam::123456789012:role/GitHubActionsRole

# 4. GitHub Secrets에 저장

# Repository Settings → Secrets → Actions → New repository secret

# Name: AWS_ROLE_ARN

# Value: <위에서 복사한 ARN>

```

```
