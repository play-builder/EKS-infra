# 검증 명령

## 로컬과 CI

핵심 요약: 인프라는 Terraform과 표준 정책 도구로 검사한다. 별도 테스트 실행 프레임워크는 없다.

```bash
make check
make test-terraform
```

`check`는 fmt, TFLint, Conftest와 운영 안전 검사다. `test-terraform`은 남겨둔 native 테스트가 있는 root를 초기화·validate·test한다. AWS에 apply하지 않으며 provider 다운로드는 발생할 수 있다.
Terraform 1.16.0, TFLint 0.64.0, Conftest 0.69.0, Python 3.10+, Bash, jq, Git이 필요하다.

| 검사 | 막는 실패 |
| --- | --- |
| `tests/test_inputs.py` | 다른 계정·backend 입력, 경로 이탈, 기존 tfvars 덮어쓰기, 비밀값 출력 |
| `tests/saved-plan.sh` | 승인자·source SHA·plan hash·환경이 다른 saved plan 사용 |
| root/module `tests/*.tftest.hcl` | IAM 최소 권한, 암호화/보존, 네트워크 격리, RDS 복구 제약 |
| `policy/terraform` | Rego 정책 자체의 회귀(`conftest verify` 단위 테스트); plan JSON에 정책을 적용하는 단계는 CI에 없다 |

GitHub Actions는 `contract`, `format`, `lint`, `security`, `enterprise-static`, `validate` check 이름을 유지한다. `enterprise-static`은 native Terraform 테스트만 실행한다. `validate` matrix는 운영 root 전체의 backend 없는 validate를 수행한다. `security`는 Trivy와 Conftest다.

## 운영 확인

핵심 요약: 정적 검사 성공과 실제 EKS 배포 성공을 구분한다.

실제 계정·IAM·네트워크·node·controller·Pod·트래픽·알림은 [운영 절차](runbook.md)의 AWS/Kubernetes/Argo CD 명령과 관측 화면에서 확인한다. 코드 검사는 실환경 성공을 대신하지 않는다.
