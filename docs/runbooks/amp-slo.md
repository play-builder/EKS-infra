# AMP SLO와 알림 실측

핵심 요약: Terraform은 룰과 SNS 경로를 선언하고 ADOT는 실제 앱·Istio 지표를 수집한다.
로컬 mock/Prometheus 테스트는 실제 ingestion이나 알림 수신의 증거가 아니다.
이 runbook의 runtime 단계는 승인된 계정·환경·실험 시간에 운영자가 수행한다.

목차: [신호와 정책](#신호와-정책), [수집 계약](#수집-계약), [실측](#실측), [증거 한계](#증거-한계), [실패와 복구](#실패와-복구).

## 신호와 정책

핵심 요약: SLI는 측정값, SLO는 목표, burn rate는 허용 실패 비율 대비 실제 실패 비율이다.
성공률 burn은 두 독립 window가 모두 임계치를 초과하고 각 window의 트래픽이 floor 이상일 때 경보가 된다.

- 성공률: `error_ratio / (1 - success_target)`. 기본 short/long은 5m/1h, 목표 99.9%, burn threshold 각각 14.4, floor 각각 0.1 RPS다.
- 지표 selector: `reporter="destination",destination_canonical_service="mini-commerce",destination_workload_namespace="app-dev|app-prod",environment="dev|prod"`. 실제 룰에는 환경별 정확한 단일 namespace가 들어간다.
- GitOps는 pod에 `service.istio.io/canonical-name=mini-commerce`를 설정한다. 이 논리 서비스가 stable/canary Kubernetes Service를 함께 포괄한다. `destination_service_name="mini-commerce"`만 사용하면 Rollout 서비스의 트래픽을 놓친다.
- HTTP 5xx가 실패 numerator다. 빈 시계열을 100% 성공으로 만들거나 denominator를 임의 1 RPS로 올리지 않는다. floor 미만이면 page를 보류한다.
- p95 duration은 `istio_request_duration_milliseconds_bucket`에서 별도 latency alert로 계산한다. latency error-budget fraction이 없으므로 latency burn이라고 부르지 않는다.
- 별도 업무 경보는 주문 실패 reason, inventory conflict, DB pool/operation 오류, waiting requests와 idle connection을 사용한다. operation counter가 아직 없더라도 pool error 경보는 동작한다. 기본 업무 경보는 5m rate가 양수인 상태가 1m 지속될 때 발생하므로 업무상 허용 오류를 실제 운영 정책과 비교한다.
- aggregation 후 경보 label은 `service/environment/severity/runbook`과 Prometheus 내장 `alertname`이다. owner와 query는 annotation에 둔다. 사용자 ID·URL·Git SHA를 metric label로 추가하지 않는다.

AMP workspace와 SNS topic은 동일 계정·Region이며 policy는 exact workspace SourceArn/SourceAccount를 사용한다.
receiver는 `slo.escalation_route` 이름으로 SNS를 참조하고 firing/resolved를 모두 보낸다.
이 이름 자체가 PagerDuty 연결 증거는 아니다. 승인된 SNS subscriber와 후속 paging 연동은 알림 owner가 준비한다.
email subscription은 endpoint와 enable flag를 명시했을 때만 선언되며 AWS confirmation은 별도 단계다.

## 수집 계약

핵심 요약: annotation의 merged endpoint 대신 두 target을 별도로 scrape한다.
ADOT replica는 하나이며 정확한 container port 선택으로 한 pod의 복수 port가 같은 endpoint로 중복 수집되지 않게 한다.

| 대상 | endpoint | 발견 조건 |
| --- | --- | --- |
| 앱 | Pod IP:3001/metrics | app-dev/prod, name=mini-commerce, named port management |
| Istio | Pod IP:15090/stats/prometheus | app-dev/prod, container istio-proxy, named port http-envoy-prom |

두 job 모두 Running pod만 선택하고 `environment`를 명시적으로 부여한다. 앱 job은 `mini_commerce_*`,
proxy job은 HTTP request/duration만 유지한다. 기존 cAdvisor, OTLP/HTTP 4318, AMP SigV4 remote write, X-Ray 경로는 유지한다.
기존 임의 annotation 기반 pod job은 Mini Commerce 전용 job으로 대체되었으므로 다른 workload의 annotation만으로 수집되던 지표가 있다면 별도 job을 설계한다.

GitOps 소유 전제:

1. `prometheus.istio.io/merge-metrics: "false"`를 Mini Commerce pod에 지정한다.
2. `opentelemetry-operator-system`의 collector pod만 3001/15090에 접근하도록 NetworkPolicy를 허용한다. 해당 ServiceAccount는 `adot-collector`다.
3. STRICT namespace에서 앱 3001은 해당 workload의 `PeerAuthentication.portLevelMtls[3001].mode=DISABLE` 예외와 좁은 NetworkPolicy를 함께 사용한다. 관리 port를 ALB/public Service로 노출하지 않는다.
4. sidecar가 실제 주입된 destination HTTP 지표와 collector 접근을 확인한다. Ambient L4만으로 HTTP 지표가 만들어지지는 않는다.

15090/http-envoy-prom은 checksummed Istio chart 1.30.4/1.31.0 injection template와 일치한다.
Istio는 15090을 inbound redirection에서 제외한다. 15020의 merged metrics/probe 경로를 이 scrape job과 혼용하지 않는다.
[Istio Prometheus integration](https://istio.io/latest/docs/ops/integrations/prometheus/),
[Istio Standard Metrics](https://istio.io/latest/docs/reference/config/metrics/).

## 실측

핵심 요약: `collect`는 읽기 전용 API snapshot을 모으고 `validate`는 캡처 간 일관성을 검사한다.
fault 시작/중지와 subscriber 수신 증거 확보는 operator 단계이며 스크립트가 수행하지 않는다.

### 설치

runtime collector만 Python 3.10+와 별도 SDK venv가 필요하다. AWS CLI 설치가 시스템 Python에 boto3를 제공한다고 가정하지 않는다.

```bash
python3 -m venv .venv-amp-slo
. .venv-amp-slo/bin/activate
python -m pip install -r scripts/requirements-amp-slo.txt
```

boto3/botocore 1.42.59와 검증한 transitive dependency를 pin한다. `validate`는 표준 라이브러리만 사용한다.
SDK 설치/검증은 cloud 접속 검증이 아니다.

### 준비 및 채집

1. 승인된 환경에서 실제 배포 image index digest, GitOps commit, Istio revision, workspace/topic/cluster ARN을 확인하고 operator record의 `binding`에 넣는다. 이 값들의 배포 일치 증거도 별도 보존한다.
2. `schemaVersion=platform.amp-slo-drill/v1`, `source=captured`, `evidenceGrade=LIVE_NOT_VERIFIED`인 JSON을 준비한다. `tests/amp-slo-drill-contract.py`의 fixture가 전체 필드 예시이며 fixture 서명/시각을 실측값으로 사용하지 않는다.
3. 사용자 승인된 bounded fault를 시작하고 `fault.startedAt`과 변경 티켓/실행 로그를 기록한다. 충분한 시간과 트래픽으로 두 window burn이 모두 발생해야 한다. 실험 종료·중단 조건을 미리 정한다.
4. firing 상태에서 아래 읽기 전용 snapshot을 채집한다.

```bash
bash scripts/amp-slo-drill.sh collect --input operator-record.json \
  --phase firing --output firing-capture.json --short-window 5m --long-window 1h
```

5. fault를 중지하고 stoppedAt 및 rollback 결과를 기록한다. 승인된 HTTPS subscriber에서 firing/resolved **실제 HTTP Notification body**와 `x-amz-sns-subscription-arn`, 수신 시각을 확보한다. 원본 SNS envelope는 `Type, MessageId, TopicArn, Message, Timestamp, SignatureVersion, Signature, SigningCertURL`을 유지한다. `observations.deliveryReceipt.firing/resolved`에 `envelope/headers/receivedAt` 형태로 넣는다. 이 repo의 Alertmanager message template는 각 alert의 status/fingerprint/labels/startsAt/endsAt를 JSON으로 보낸다.
6. 수정한 firing snapshot을 새 input 파일로 보존하고 resolved 시점의 Alertmanager 목록을 채집한다.

```bash
bash scripts/amp-slo-drill.sh collect --input operator-completed-record.json \
  --phase resolved --output resolved-capture.json
bash scripts/amp-slo-drill.sh validate --input resolved-capture.json \
  --traffic-floor-rps 0.1 --resolve-timeout-minutes 15 --max-age-minutes 120
```

정상 결과는 `CAPTURED_VALIDATED`와 `LIVE_NOT_VERIFIED`다. CLI policy 값은 배포된 `slo` output과 같아야 한다.
collect는 기존 output을 덮어쓰지 않고 mode 0600으로 새 파일을 만든다.
API 권한은 STS identity, AMP DescribeWorkspace/QueryMetrics/ListRules/ListAlertManagerAlerts, EKS DescribeCluster 읽기에 한정한다.
공식 [QueryMetrics](https://docs.aws.amazon.com/prometheus/latest/userguide/AMP-APIReference-QueryMetrics.html),
[ListRules](https://docs.aws.amazon.com/prometheus/latest/userguide/AMP-APIReference-ListRules.html),
[ListAlertManagerAlerts](https://docs.aws.amazon.com/prometheus/latest/userguide/AMP-APIReference-ListAlertManagerAlerts.html)를 사용하며
가상의 boto3 query 메서드를 호출하지 않는다.

## 증거 한계

핵심 요약: captured validation은 source가 제출한 문서의 일관성 검사다.
SNS 서명 암호 검증, subscriber audit log 출처 및 실제 배포 revision 일치는 별도 신뢰 경계다.

- boolean `snsDelivered=true`는 수신 증거가 아니다. 공식 SNS HTTP envelope와 subscriber metadata가 없으면 거부한다.
- 잘못된 계정/Region/topic, stale/future timestamp, 빈/오류 query, 각 window의 floor 미달, firing 미관측, 미해소 fingerprint, 수신 ID 중복을 거부한다.
- validator는 Signature 필드의 존재·형식 경계를 확인하지만 서명 인증서를 취득하거나 signature를 암호학적으로 검증하지 않는다. 따라서 제출 파일만으로 subscriber가 실제 수신했다고 보증하거나 `CLOUD_RUNTIME`을 발급하지 않는다.
- 운영자는 신뢰할 수 있는 subscriber의 원본 수신 로그와 SNS signature verification 결과를 별도로 제출해야 한다. 이메일 본문만 있는 경로는 이 validator가 지원하는 HTTP receipt가 아니다.
- fixture 실행은 항상 `LOCAL_VERIFIED`; fixture를 `CLOUD_RUNTIME`으로 표시하면 거부한다. source를 임의로 변경해도 이 도구는 live grade를 생성하지 않는다.

[SNS HTTP Notification envelope](https://docs.aws.amazon.com/sns/latest/dg/http-notification-json.html),
[SNS signature verification](https://docs.aws.amazon.com/sns/latest/dg/sns-verify-signature-of-message.html).

## 실패와 복구

핵심 요약: 무트래픽/미수집, 룰 미평가, 알림 전송·수신 실패를 각각 구분한다.
복구는 fault 제거와 실제 app 상태 확인부터 시작하고, 증거 검증 실패를 임계값 완화로 해결하지 않는다.

- query 없음: proxy 주입, canonical label, destination namespace, NetworkPolicy, mTLS 예외, AMP ingestion/remote-write IAM을 확인한다.
- burn 불발: 두 window traffic/error ratio와 floor를 확인한다. short만 높으면 정상적으로 page를 보류한다.
- alert는 firing인데 SNS 없음: exact workspace SNS policy, receiver Region, subscriber confirmation, delivery failure 로그를 확인한다.
- resolved 없음: fault가 제거되고 error counter rate가 window 밖으로 빠졌는지 확인한다. 수신 지연과 resolve timeout을 분리해서 기록한다.
- 과다 알림: 업무 오류 허용 정책과 window/hold 시간을 평가하고 승인된 변경으로 조정한다. 실제 SNS/PagerDuty는 별도 owner가 관리한다.
- 비용/영향: AMP 수집 sample·보관, CloudWatch 로그 및 SNS 전송 비용이 발생한다. fault는 주문 실패/지연을 유발하므로 Prod 자동 실행을 금지하고 중단 후 app/DB 상태를 확인한다.

소스 검증 명령:

```bash
terraform -chdir=modules/addons/amp-alerting test
python3 tests/amp-promql-contract.py
python3 tests/adot-scrape-contract.py
bash tests/amp-slo-drill-contract.sh
# optional collector venv
python tests/amp-slo-sdk-contract.py
```
