import datetime,importlib.util,pathlib,unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
class Drill(unittest.TestCase):
 def test_observation_sequence(self):
  spec=importlib.util.spec_from_file_location("drill",ROOT/"scripts/lib/mng-autoscaler-drill.py")
  m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
  x={"startedAt":datetime.datetime.now(datetime.timezone.utc).isoformat(),"initialNodes":["a"],"pendingObserved":True,"scaleOutNodes":["a","b"],"workloadReady":True,"scaleInNodes":["a"],"pdbViolations":0,"cleanupSucceeded":True,"remainingWorkloads":0}
  m.validate(x)
  for key,value in [("pendingObserved",False),("scaleOutNodes",["a"]),("workloadReady",False),("scaleInNodes",["a","b"]),("pdbViolations",1),("cleanupSucceeded",False),("remainingWorkloads",1),("startedAt","2020-01-01T00:00:00+00:00")]:
   y=dict(x);y[key]=value
   with self.subTest(key=key),self.assertRaises(ValueError):m.validate(y)
if __name__=="__main__":unittest.main()
