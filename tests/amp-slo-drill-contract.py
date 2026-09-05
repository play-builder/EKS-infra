#!/usr/bin/env python3
import copy, datetime, json, pathlib, subprocess, tempfile, unittest
ROOT = pathlib.Path(__file__).resolve().parents[1]
NOW = datetime.datetime.now(datetime.timezone.utc)
def stamp(seconds=0):
    return (NOW + datetime.timedelta(seconds=seconds)).isoformat().replace("+00:00", "Z")
ACCOUNT = "123456789012"
REGION = "ap-northeast-2"
WORKSPACE = f"arn:aws:aps:{REGION}:{ACCOUNT}:workspace/ws-test"
TOPIC = f"arn:aws:sns:{REGION}:{ACCOUNT}:test-alerts"
CLUSTER = f"arn:aws:eks:{REGION}:{ACCOUNT}:cluster/test"
LABELS = {"alertname":"MiniCommerceSuccessBurn","service":"mini-commerce","environment":"prod","severity":"critical","runbook":"https://example.com/runbook"}
def receipt(state, when):
    return {"receivedAt": stamp(when+1), "headers": {"x-amz-sns-subscription-arn": TOPIC + ":00000000-0000-0000-0000-000000000001"},
            "envelope": {"Type":"Notification","MessageId":"00000000-0000-0000-0000-" + ("000000000001" if state=="firing" else "000000000002"),"TopicArn":TOPIC,"Timestamp":stamp(when),
                         "SignatureVersion":"2","Signature":"Zml4dHVyZQ==","SigningCertURL":f"https://sns.{REGION}.amazonaws.com/SimpleNotificationService-fixture.pem",
                         "Message":json.dumps({"status":state,"alerts":[{"status":state,"fingerprint":"0123456789abcdef","labels":LABELS,"startsAt":stamp(-600),"endsAt":stamp(-100) if state=="resolved" else "0001-01-01T00:00:00Z"}]})}}
def fixture():
    return {"schemaVersion":"platform.amp-slo-drill/v1","evidenceGrade":"LOCAL_VERIFIED","source":"fixture","capturedAt":stamp(-10),
        "binding":{"accountId":ACCOUNT,"region":REGION,"workspaceArn":WORKSPACE,"topicArn":TOPIC,"clusterArn":CLUSTER,"environment":"prod","imageIndexDigest":"sha256:"+"a"*64,"gitopsRevision":"b"*40,"istioRevision":"1-30-4"},
        "fault":{"startedAt":stamp(-700),"stoppedAt":stamp(-150),"operatorEvidence":"change-123/bounded-fault-log"},
        "observations":{
            "identity":{"Account":ACCOUNT},"workspace":{"workspace":{"arn":WORKSPACE,"workspaceId":"ws-test","status":{"statusCode":"ACTIVE"}}},"cluster":{"cluster":{"arn":CLUSTER,"status":"ACTIVE"}},
            "query":{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[NOW.timestamp()-500,"1"]}]}},
            "longQuery":{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[NOW.timestamp()-500,"1"]}]}},
            "rules":{"status":"success","data":{"groups":[{"name":"course-release-slo","file":"course-release-slo","interval":60,"lastEvaluation":stamp(-500),"evaluationTime":0.01,"rules":[{"type":"alerting","name":"MiniCommerceSuccessBurn","health":"ok","state":"firing","lastError":"","lastEvaluation":stamp(-500),"evaluationTime":0.01,"labels":{k:v for k,v in LABELS.items() if k!="alertname"},"annotations":{},"alerts":[]}]}]}},
            "firing":[{"fingerprint":"0123456789abcdef","labels":LABELS,"startsAt":stamp(-600),"endsAt":stamp(600),"updatedAt":stamp(-500),"annotations":{},"receivers":[{"name":"platform-sns"}],"status":{"state":"active","inhibitedBy":[],"silencedBy":[]}}],
            "resolved":[],
            "deliveryReceipt":{"firing":receipt("firing",-500),"resolved":receipt("resolved",-90)}}}
class Contract(unittest.TestCase):
    def run_record(self, obj):
        with tempfile.TemporaryDirectory() as folder:
            path=pathlib.Path(folder)/"evidence.json";path.write_text(json.dumps(obj))
            return subprocess.run(["bash",str(ROOT/"scripts/amp-slo-drill.sh"),"validate","--input",str(path)],capture_output=True,text=True)
    def test_complete_fixture_stays_local(self):
        result=self.run_record(fixture())
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads(result.stdout)["evidenceGrade"],"LOCAL_VERIFIED")
    def test_negative_mutations(self):
        cases=[]
        def case(fn):
            obj=fixture();fn(obj);cases.append(obj)
        case(lambda x:x.update(evidenceGrade="CLOUD_RUNTIME"))
        case(lambda x:x["binding"].update(topicArn=TOPIC.replace(REGION,"us-east-1")))
        case(lambda x:x["binding"].update(clusterArn=CLUSTER.replace(ACCOUNT,"999999999999")))
        case(lambda x:x["observations"]["query"]["data"].update(result=[]))
        case(lambda x:x["observations"]["query"]["data"]["result"][0].update(value=[NOW.timestamp()-500,"0.01"]))
        case(lambda x:x["observations"]["longQuery"]["data"]["result"][0].update(value=[NOW.timestamp()-500,"0.01"]))
        case(lambda x:x["observations"]["query"].update(status="error"))
        case(lambda x:x["observations"]["rules"]["data"].update(groups=[]))
        case(lambda x:x["observations"]["rules"]["data"]["groups"][0]["rules"][0].update(lastEvaluation=stamp(-90000)))
        case(lambda x:x["observations"]["rules"]["data"]["groups"][0]["rules"][0].update(state="inactive"))
        case(lambda x:x["observations"]["deliveryReceipt"].pop("resolved"))
        case(lambda x:x["observations"]["deliveryReceipt"]["resolved"]["envelope"].update(TopicArn=TOPIC+"wrong"))
        case(lambda x:x["observations"]["deliveryReceipt"]["resolved"]["envelope"].update(Message=x["observations"]["deliveryReceipt"]["resolved"]["envelope"]["Message"].replace("0123456789abcdef","ffffffffffffffff")))
        case(lambda x:x["observations"].update(resolved=x["observations"]["firing"]))
        case(lambda x:x.update(capturedAt=stamp(-90000)))
        case(lambda x:x["fault"].update(stoppedAt=stamp(-800)))
        case(lambda x:x["observations"].update(deliveryReceipt={"snsDelivered":True}))
        for index,obj in enumerate(cases):
            with self.subTest(index=index):self.assertNotEqual(self.run_record(obj).returncode,0)
if __name__=="__main__":unittest.main()
