# Shared GitHub OIDC and ECR

이 root는 course AWS 계정에서 한 번만 적용합니다. dev/prod cluster가 공통으로 사용할 ECR과
GitHub Actions OIDC role을 만듭니다.

```bash
cp terraform.tfvars.example terraform.tfvars
export AWS_REGION="ap-northeast-2"
export STATE_BUCKET_NAME="replace-with-your-state-bucket"
terraform init -reconfigure \
  -backend-config="bucket=$STATE_BUCKET_NAME" \
  -backend-config="key=shared/iam-github-oidc/terraform.tfstate" \
  -backend-config="region=$AWS_REGION" \
  -backend-config="encrypt=true" \
  -backend-config="use_lockfile=true"
terraform plan -out=tfplan
terraform apply tfplan
```

필수 출력:

```bash
terraform output -raw infra_role_arn
terraform output -raw sample_app_push_role_arn
terraform output -raw sample_app_ecr_repository_url
```

GitHub의 `cicd-course-sample-app` repository variables:

```text
AWS_REGION=ap-northeast-2  # 또는 us-east-1. Terraform에 적용한 Region과 같아야 함
AWS_ROLE_ARN=<sample_app_push_role_arn>
ECR_REPOSITORY=playdevops/sample-app
```

OIDC trust의 `sub`는 wildcard가 아니라 immutable owner/repository ID와 `main`/`dev`의 정확한
ref를 허용합니다. `gh api /users/<owner> --jq .id`와 `gh api /repos/<owner>/<repo> --jq .id`로
example의 ID를 다시 확인하십시오. 기존 repository는 AWS trust를 먼저 반영한 뒤 GitHub OIDC
설정에서 immutable subject를 opt-in하고 실제 token의 `sub`를 대조합니다. Pull Request
workflow는 AWS role을 사용하지 않으며 build-and-push workflow만 OIDC token을 요청합니다.

`terraform.tfvars`와 Terraform state에는 계정 식별 정보가 있으므로 원격 저장소에
커밋하지 않습니다.
