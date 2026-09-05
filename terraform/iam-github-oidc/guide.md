# Shared GitHub OIDC and ECR

이 root는 course AWS 계정에서 한 번만 적용합니다. dev/prod cluster가 공통으로 사용할 ECR과
GitHub Actions OIDC role을 만듭니다.

먼저 계정에 GitHub issuer가 이미 있는지 확인합니다. account-wide provider는 repository마다
새로 만드는 resource가 아닙니다.

```bash
aws iam list-open-id-connect-providers --region "$AWS_REGION" --profile "$AWS_PROFILE"
```

- 전용 실습 계정에 provider가 없으면 `oidc_provider_mode="create"`를 사용합니다.
- 기존 provider가 있으면 삭제하지 않고 `oidc_provider_mode="external"`과 ARN을 지정합니다.
- `EntityAlreadyExists`를 피하려고 기존 provider를 임의 삭제하면 그 provider를 신뢰하는 다른
  workflow가 동시에 중단될 수 있습니다.

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

create/external mode는 최초 ownership 결정입니다. mode 변경은 일반 apply가 아니라
`course.oidc-ownership-handoff/v1` evidence, source state backup, destination import와 no-op plan을
먼저 확보한 뒤 수행합니다. 검증 명령은 다음과 같습니다.

```bash
bash ../../scripts/oidc-ownership-handoff.sh \
  --evidence /secure/path/oidc-handoff.json --validate-only
```

`terraform state rm`은 IAM provider를 삭제하지 않고 state의 bookkeeping만 이전합니다. 실제 provider
삭제는 course-owned 전용 계정임을 확인한 별도 cleanup에서만 허용하며, `prevent_destroy`를 임시 해제한
변경은 반드시 별도 review를 거칩니다.

ECR lifecycle policy를 적용하기 전 retained rollback digest를 preview로 보호합니다.

```bash
bash ../../scripts/ecr-lifecycle-preview.sh \
  "$ECR_REPOSITORY" "$V1_INDEX_DIGEST" "$V2_PRIME_INDEX_DIGEST"
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
## Mini Commerce migration and attestation role

The legacy image/chart resources keep their state addresses. New immutable
playdevops/mini-commerce and playdevops/mini-commerce-chart repositories are
separate resources. Obtain actual URLs/ARNs from outputs after reviewed deployment.

Map sample_app_push_role_arn to GitHub vars.AWS_ROLE_ARN,
sample_app_attest_verify_role_arn to vars.AWS_ATTEST_VERIFY_ROLE_ARN and the new
image repository name to vars.ECR_REPOSITORY. This code does not register GitHub
variables. Only the user changes remote GitHub settings and pushes code.

Both roles trust the approved numeric old/new main subjects. A main job can request
either role: separate ARNs provide policy/audit separation, not enforced job isolation.
The attestation job needs repository-scoped read and OCI upload, including PutImage.
AWS authorizes ListImageReferrers through BatchGetImage, not an invented same-name
IAM action. PutImage cannot be restricted here to attestation manifests alone.
Sources: [ECR IAM actions](https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazonelasticcontainerregistry.html),
[ListImageReferrers](https://docs.aws.amazon.com/AmazonECR/latest/APIReference/API_ListImageReferrers.html).

Registry scanning is a regional singleton. Default external ownership creates no
Terraform scanning resource. For transfer into Terraform, first read live state,
review/import the exact registry, and require a no-change saved plan. To transfer
out, obtain external-owner acceptance, use reviewed state rm, and verify live state.
Never apply a count-to-zero delete; prevent_destroy and the no-destroy validator
block that route. Keep the approval/state backup as rollback evidence.
