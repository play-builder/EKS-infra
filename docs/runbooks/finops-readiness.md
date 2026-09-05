# Production FinOps 구성 게이트

목차: [계정·소유권](#계정소유권), [설정과 실행](#설정과-실행), [증거와-게이트](#증거와-게이트), [실패와-운영](#실패와-운영).

## 계정·소유권

핵심 요약: `00-finops`는 기존 Organizations management account의 Budget, CUSTOM anomaly monitor, anomaly subscription만 생성한다. billing provider와 별도 billing SNS는 `us-east-1`, workload는 명시한 계정과 Region을 사용한다. 이 문서는 운영자 실행 절차이며 현재 AWS 실행 증거가 아니다.

Budget은 월 USD 금액과 `LinkedAccount + PlatformInstanceId` 필터를 사용한다. 실제 지출 비율이 50/80/100%를 넘으면 SNS에 알린다. Anomaly monitor는 조직 전체에서 해당 태그 값만 감시한다. 따라서 `PlatformInstanceId`는 조직 전체에서 고유하게 예약하고 모든 비용 리소스에 적용해야 한다. 지난 30일 조회에 충돌이 없다는 사실은 미래의 고유성이나 태그 없는 리소스의 비용까지 증명하지 않는다.

외부 billing SNS topic, policy, KMS key 및 구독 대상은 별도 소유자가 관리한다. 이후 생성되는 AMP topic에 의존하지 않는다. 이 root는 Organizations 생성, 계정 이동, SNS 변경 또는 알림 전송을 수행하지 않는다. `Owner`와 `CostCenter`는 팀·비용분류 식별자이며 이메일, 전화번호, 토큰 같은 개인 연락처나 비밀값을 넣지 않는다.

## 설정과 실행

핵심 요약: root 출력은 설정 메타데이터다. `finops-readiness-check.sh collect`가 다시 AWS를 읽어 검증해야 구성 증거가 된다. 각 명령은 운영자가 적절한 권한·변경 절차에서 실행하며 여기서는 실행하지 않았다.

1. `environments/prod/00-finops/terraform.tfvars.example`을 로컬 설정으로 복사하여 billing/workload 계정, workload Region, 비용 태그, 예산과 별도 SNS ARN을 지정한다. `billing_access.profile`과 `billing_access.role_arn`은 동시에 설정하지 않는다. role 방식은 기존 역할만 사용하고 자격증명을 파일이나 CLI 인자로 출력하지 않는다.
2. `environments/prod/config/finops.tfbackend`의 key/암호화/잠금 설정과 함께 기존 S3 state backend의 bucket·Region 설정을 제공한다. 상태 key는 `prod/00-finops/terraform.tfstate`다. 승인된 저장 계획을 확인하여 이 root를 workload root보다 먼저 적용한다. Terraform `plan`/`apply`에는 billing 관리계정 접근 권한이 필요하다.
3. billing 소유자가 `PlatformInstanceId`를 비용 할당 태그로 활성화하고 모든 SNS 수신 구독을 확인한다. 신규 태그가 billing 목록에 표시되기까지 지연될 수 있으며 비활성/미존재 태그 상태에서는 구성 GO가 나오지 않는다.

```bash
terraform -chdir=environments/prod/00-finops output -json finops > /private/tmp/finops-contract.json
chmod 600 /private/tmp/finops-contract.json
python3 -m venv /private/tmp/finops-venv
/private/tmp/finops-venv/bin/pip install -r scripts/requirements-amp-slo.txt
```

컬렉터는 기존 공통 AWS SDK requirements를 재사용한다. AWS CLI의 내장 Python에 설치하지 않는다. wrapper는 `python3 -I`로 실행하므로 활성 venv 또는 아래 PATH 선택이 필요하다.

```bash
export PATH="/private/tmp/finops-venv/bin:$PATH"
export FINOPS_CONTRACT_JSON=/private/tmp/finops-contract.json
export PLATFORM_INSTANCE_ID=commerce-prod-unique-id
export FINOPS_GATE_POLICY=configuration-only
export FINOPS_BILLING_PROFILE=billing-management

bash scripts/finops-readiness-check.sh collect \
  --contract "$FINOPS_CONTRACT_JSON" \
  --account "$AWS_ACCOUNT_ID" --region "$AWS_REGION" \
  --platform-id "$PLATFORM_INSTANCE_ID" \
  --profile "$FINOPS_BILLING_PROFILE" \
  --gate-policy "$FINOPS_GATE_POLICY" \
  --output /private/tmp/finops-readiness.json
```

`AWS_ACCOUNT_ID`와 `AWS_REGION`은 workload 대상이다. billing role 입력을 사용하는 운영자는 `--profile` 대신 `--role-arn`을 사용한다. preflight에서도 `FINOPS_BILLING_PROFILE` 대신 `FINOPS_BILLING_ROLE_ARN`을 설정한다. 이때 기본 AWS 자격증명이 기존 management-account role을 AssumeRole할 수 있어야 한다. collector는 받은 임시 자격증명을 메모리에서만 사용하고 계정 일치를 STS로 다시 확인한다.

Production estimate 명령의 기존 7개 positional 인자는 유지한다. 위 환경변수와 `COURSE_ID`, workload의 `AWS_ACCOUNT_ID`, `AWS_REGION`, `AWS_PROFILE`을 설정하고 실행한다.

```bash
bash scripts/prod-preflight.sh \
  dev-deployment.json dev-slo.json dev-ready.json \
  design-decision.json eks-plan-summary.json capacity-input.json estimate-decision.json
```

이 명령은 기존 readiness 파일을 신뢰하여 재사용하지 않고 FinOps API를 새로 수집한 뒤 EC2 용량을 조회한다. standalone 수집 결과는 검토용이며 preflight의 입력 GO 토큰이 아니다. 예산 API나 Organizations 읽기가 거부되면 출력 GO를 만들지 않는다.

## 증거와 게이트

핵심 요약: `CONFIGURED`, `DATA_PENDING`, `deliveryStatus=NOT_VERIFIED`는 동시에 정상일 수 있다. 명시적인 `configuration-only` 정책은 설정 완료 상태에서 production 생성 준비를 허용하지만 비용 감시의 운영 검증을 의미하지 않는다.

| 필드 | 의미 |
| --- | --- |
| `configurationStatus=CONFIGURED` | caller/조직/리소스/필터/알림/태그/SNS/KMS 구성을 실제 응답으로 검사 |
| `dataStatus=DATA_PENDING` | 조회에 그룹이 없거나 CE의 정확한 `DataUnavailableException`; 지출 0을 뜻하지 않음 |
| `dataStatus=DATA_OBSERVED` | 해당 계정에 태그가 붙은 비용 그룹 존재; 결산 확정이나 이상 감지 학습 완료를 뜻하지 않음 |
| `uniquenessStatus` | 지난 30일 내 충돌 미관측 또는 아직 관측 불가; 다른 계정 그룹은 금액 0이어도 실패 |
| `deliveryStatus=NOT_VERIFIED` | SNS confirmation은 수신 증거가 아님; 실제 Budget/Anomaly 알림 및 수신자 receipt 검증은 별도 |

`platform.finops-readiness/v1`은 workload/billing 계정·Region, 플랫폼 ID, 관측 시각, 계약 파일 SHA-256, 원시 응답 SHA-256, collector 소스 SHA-256을 묶는다. 실제 조회 결과는 `CLOUD_RUNTIME` **구성 관측 범위**이고, 로컬 `fixture` 모드는 항상 `LOCAL_VERIFIED`다. fixture/사용자가 쓴 `true` 플래그는 runtime/delivery 검증으로 승격되지 않는다. runtime 모드는 command double, 임의 endpoint 환경변수, replay observations를 거부한다. JSON 증거 자체는 서명되지 않았으므로 생산 환경에서는 실행 주체·로그·아티팩트 무결성을 별도 신뢰 경계에서 보존해야 한다.

기존 design은 `course.prod-preflight/v1` 그대로다. estimate 생산자와 bootstrap 소비자는 `course.prod-preflight/v2`를 사용하며 v1 estimate를 거부한다. v2는 `finops` 객체와 `bindings.finopsContractSha256`를 추가했다. bootstrap 실행 시 동일 `FINOPS_CONTRACT_JSON`과 `PLATFORM_INSTANCE_ID`를 제공한다. FinOps 증거는 15분 이내 관측이어야 하므로 기존 estimate TTL보다 일찍 재수집이 필요할 수 있다.

## 실패와 운영

핵심 요약: 거부·누락·중복·판별 불가능 응답은 닫힌 상태로 실패한다. 범용 IAM 정책 시뮬레이터를 구현하지 않았으므로 지원하는 정책 형태 밖의 조건은 SNS/KMS 소유자 검토가 필요하다. 강제 GO 옵션은 없다.

- SNS publish 문장은 서비스별 `budgets.amazonaws.com`, `costalerts.amazonaws.com`, 정확한 topic ARN, `StringEquals aws:SourceAccount`, 정확한 해당 Budget/Anomaly subscription `aws:SourceArn` 조건을 사용한다. SourceArn 연산자는 `ArnEquals`/`ArnLike`/`StringEquals`를 지원하지만 wildcard ARN은 이 게이트에서 허용하지 않는다. AWS가 더 넓은 정책을 지원한다는 사실과 이 게이트의 보수적인 계약은 다르다.
- 암호화 topic은 실제 연결 key를 DescribeKey한 후 그 key 정책을 조회한다. enabled, customer-managed, `ENCRYPT_DECRYPT`, 동일 billing 계정/us-east-1 key여야 하며 두 서비스 모두 `kms:GenerateDataKey` 또는 `kms:GenerateDataKey*`와 `kms:Decrypt`가 필요하다. AWS 문서의 무조건 서비스 문장 및 정확한 SourceAccount/SourceArn 조건만 처리한다. 정책에 explicit Deny가 있으면 관련성 추정 없이 실패한다.
- 두 비용 API의 태그 조회 파라미터는 다르다: Budgets `ResourceARN`, CE `ResourceArn`. Organizations, Budget 알림/구독, CE, SNS, 비용 그룹 조회는 끝까지 페이지를 순회한다.
- 런타임 읽기 권한: `sts:GetCallerIdentity`, 필요 시 기존 billing role에 대한 `sts:AssumeRole`; `organizations:DescribeOrganization`, `organizations:ListAccounts`; `budgets:ViewBudget`, `budgets:ListTagsForResource`; `ce:GetAnomalyMonitors`, `ce:GetAnomalySubscriptions`, `ce:ListCostAllocationTags`, `ce:ListTagsForResource`, `ce:GetCostAndUsage`; `sns:GetTopicAttributes`, `sns:ListSubscriptionsByTopic`; 암호화 시 `kms:DescribeKey`, `kms:GetKeyPolicy`. 서비스가 지원하는 ARN 범위와 condition을 적용하며 GitHub workload role에 management-account 권한을 자동 부여하지 않는다.
- collector는 저장·전송·구독 변경을 수행하지 않지만 Cost Explorer 조회는 계정의 API 가격 정책에 따라 비용을 발생시킬 수 있다. 반복 주기를 운영자가 정한다.
- 정상 수신 확인은 billing 소유자가 승인한 별도 실제 알림/receipt 절차로 수행한다. 이 collector는 임계치를 인위적으로 낮추거나 SNS publish를 실행하지 않는다.
- 실패하면 stderr의 단계와 원본 계정/Region/실제 리소스 상태를 확인한다. 원시 응답의 endpoint/email은 출력하지 않는다. 출력 경로가 이전 실행 파일을 포함하면 exit code를 먼저 확인하고 실패 실행의 결과로 재사용하지 않는다.
- workload cleanup 및 retained billable resource 결정을 마칠 때까지 FinOps 리소스를 보존한다. root 제거는 Budget/monitor/subscription만 제거하며 외부 SNS/KMS와 retained 리소스의 비용은 남는다. 롤백은 승인된 Terraform 저장 계획으로 수행하고 외부 topic policy를 덮어쓰지 않는다.

검증 명령: `bash tests/finops-readiness-contract.sh`, `bash tests/prod-preflight-contract.sh`, `bash tests/prod-bootstrap-contract.sh`. 이 테스트들은 로컬 계약만 검증하며 **LIVE_NOT_VERIFIED**다.

근거: [Budget SNS/KMS](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-sns-policy.html), [Anomaly SNS/KMS](https://docs.aws.amazon.com/cost-management/latest/userguide/ad-SNS.html), [Anomaly subscription API](https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/API_AnomalySubscription.html), [Cost allocation tag API](https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/API_ListCostAllocationTags.html), [Cost usage API와 DataUnavailableException](https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/API_GetCostAndUsage.html).
