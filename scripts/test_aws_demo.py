#!/usr/bin/env python3
import contextlib, importlib.util, io, json, os, pathlib, unittest
from unittest.mock import patch
ROOT=pathlib.Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('demo',ROOT/'demo/aws-demo.py');demo=importlib.util.module_from_spec(spec);spec.loader.exec_module(demo)
class Probes(unittest.TestCase):
 def invoke(self,name,phase,status,body='{}',gateway='https://abc123.execute-api.eu-west-3.amazonaws.com'):
  with patch.dict(os.environ,{'AGENT_TOKEN':'test-token','GATEWAY_URL':gateway},clear=True),patch('sys.argv',['demo',name,phase]),patch.object(demo,'request',return_value=(status,body)) as request,contextlib.redirect_stdout(io.StringIO()):
   demo.run();return request.call_args
 def test_rest_paths_and_success_status(self):
  for name in ['weather','users','geocoding','refunds']:
   args=self.invoke(name,'access',201 if name=='refunds' else 200).args
   self.assertIn('/api-'+name+'/',args[0])
 def test_emotion_tool_and_nested_approval(self):
  args=self.invoke('emotion','held',202,json.dumps({'result':{'approval_id':'apr-test'}})).args
  self.assertEqual(args[3]['params']['name'],'emotion_detection_detailed')
  self.assertIsNone(args[4])
 def test_missing_approval_is_failure(self):
  with self.assertRaises(RuntimeError):self.invoke('emotion','held',202)
 def test_revocation_is_required(self):
  self.invoke('users','revoked',403)
  with self.assertRaises(RuntimeError):self.invoke('users','revoked',200)
 def test_provider_failure_is_failure(self):
  with self.assertRaises(RuntimeError):self.invoke('users','access',502)
 def test_proxy_uses_tunnel(self):
  args=self.invoke('proxy','access',200).args
  self.assertEqual(args[4],'http://127.0.0.1:8088')
  self.assertEqual(args[0],'http://example.com/')
 def test_untrusted_gateway_rejected_before_token_sent(self):
  with contextlib.redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):self.invoke('users','access',200,gateway='https://example.com')
if __name__=='__main__':unittest.main()
