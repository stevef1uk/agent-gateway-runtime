#!/usr/bin/env python3
"""Run the public demo client against a fake curl executable; no network calls."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FAKE_CURL = r'''#!/usr/bin/env python3
import json,os,pathlib,sys
args=sys.argv[1:]
output=pathlib.Path(args[args.index('--output')+1])
method=args[args.index('-X')+1]
headers=[args[i+1] for i,value in enumerate(args) if value=='-H']
url=args[-1]
auth=any(h.startswith('Authorization: Bearer ') for h in headers)
phase=os.environ['FAKE_PHASE']
body={};status=403
if not auth:status=401
elif phase=='revoked':status=403
elif '/v1/forecast?' in url and method=='GET':status=200;body={'current':{'temperature_2m':12,'wind_speed_10m':4}}
elif '/v1/elevation?' in url:
 state=pathlib.Path(os.environ['FAKE_STATE'])
 count=int(state.read_text()) if state.exists() else 0
 state.write_text(str(count+1))
 if phase=='approved' and count==0:status=200;body={'elevation':[18]}
 else:status=202;body={'approval_id':'test-approval'}
if os.environ.get('FAKE_BAD_BODY') and status==200:body={}
if os.environ.get('FAKE_EXPIRED'):status=401
output.write_text(json.dumps(body))
pathlib.Path(os.environ['FAKE_LOG']).open('a').write(json.dumps(args)+'\n')
print(status,end='')
'''


class WeatherClient(unittest.TestCase):
    def run_client(self, phase, **extra):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            curl = base / 'curl'
            curl.write_text(FAKE_CURL)
            curl.chmod(0o755)
            env = dict(os.environ, PATH=str(base)+os.pathsep+os.environ['PATH'],
                       GATEWAY_URL='https://test123.execute-api.eu-west-3.amazonaws.com',
                       AGENT_TOKEN='unit-test-private-token', FAKE_PHASE=phase,
                       FAKE_STATE=str(base/'state'), FAKE_LOG=str(base/'log'))
            env.update(extra)
            result = subprocess.run(['bash', str(ROOT/'demo/public-weather-tutorial.sh'), phase], env=env, capture_output=True, text=True)
            calls = [json.loads(line) for line in (base/'log').read_text().splitlines()] if (base/'log').exists() else []
            self.assertNotIn('unit-test-private-token', result.stdout+result.stderr)
            return result, calls

    def test_access_probes_include_negative_scope_and_mapping(self):
        result,calls=self.run_client('access')
        self.assertEqual(0,result.returncode,result.stderr)
        self.assertEqual(6,len(calls))
        self.assertTrue(any('X-Agent-Action: read' in call for call in calls))
        self.assertTrue(all('-L' not in call and '--location' not in call for call in calls))
        self.assertIn('test-approval',result.stdout)

    def test_approved_phase_requires_one_use_then_new_hold(self):
        result,calls=self.run_client('approved')
        self.assertEqual(0,result.returncode,result.stderr)
        self.assertEqual(2,len(calls))

    def test_revoked_phase(self):
        result,calls=self.run_client('revoked')
        self.assertEqual(0,result.returncode,result.stderr)
        self.assertEqual(1,len(calls))

    def test_expiry_is_not_a_passing_revocation_proof(self):
        result,_=self.run_client('revoked',FAKE_EXPIRED='1')
        self.assertNotEqual(0,result.returncode)

    def test_success_status_without_weather_fields_fails(self):
        result,_=self.run_client('access',FAKE_BAD_BODY='1')
        self.assertNotEqual(0,result.returncode)

    def test_refuses_third_party_or_plain_http_token_destination(self):
        for url in ['https://api.open-meteo.com','http://localhost:8087','https://test123.execute-api.eu-west-3.amazonaws.com/other']:
            result,calls=self.run_client('access',GATEWAY_URL=url)
            self.assertNotEqual(0,result.returncode)
            self.assertFalse(calls)


if __name__=='__main__':unittest.main()
