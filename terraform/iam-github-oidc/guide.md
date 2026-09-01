# Shared GitHub OIDC and ECR

이 root는 course AWS 계정에서 한 번만 적용합니다. dev/prod cluster가 공통으로 사용할 ECR과
GitHub Actions OIDC role을 만듭니다.

```bash
cp terraform.tfvars.example terraform.tfvars
terraform init
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
AWS_REGION=us-east-1
AWS_ROLE_ARN=<sample_app_push_role_arn>
ECR_REPOSITORY=playdevops/sample-app
```


`terraform.tfvars`와 Terraform state에는 계정 식별 정보가 있으므로 원격 저장소에
커밋하지 않습니다.
