#!/usr/bin/env python3
"""Customer deployment contracts. Uses temporary files/fake CLI boundaries only."""
import base64,contextlib,importlib.util,io,json,os,pathlib,subprocess,tempfile,unittest
from unittest.mock import patch
ROOT=pathlib.Path(__file__).resolve().parents[1]
def load(name,file):
    spec=importlib.util.spec_from_file_location(name,ROOT/'scripts'/file);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
release=load('release','aws-release.py');demos=load('demos','aws-demo-stacks.py')
def manifest():
    images={s:{'digest':'sha256:'+'a'*64,'immutable_image':f'stevef1uk/agent-gateway-{s}_l@sha256:'+'a'*64} for s in release.SERVICES}
    return dict(release_schema=2,version='1.0.94-test',source_commit='a'*40,console_build='1.0.94',platform='linux/arm64',images=images,emotion={'digest':'sha256:'+'b'*64,'immutable_image':'stevef1uk/agent-gateway-emotion-lambda@sha256:'+'b'*64})
class Customer(unittest.TestCase):
    def validate(self,value):
        with tempfile.TemporaryDirectory() as folder:
            path=pathlib.Path(folder)/'release.json';path.write_text(json.dumps(value));return release.load_release(path)
    def test_source_free_release(self):self.assertEqual(self.validate(manifest())['version'],'1.0.94-test')
    def test_old_release_rejected(self):
        m=manifest();m.pop('release_schema')
        with self.assertRaises(ValueError):self.validate(m)
    def test_old_console_rejected(self):
        m=manifest();m['console_build']='1.0.93'
        with self.assertRaises(ValueError):self.validate(m)
    def test_unencrypted_or_foreign_repository_rejected(self):
        m=manifest();m['images']['web']['immutable_image']='other/image@sha256:'+'a'*64
        with self.assertRaises(ValueError):self.validate(m)
    def test_emotion_required(self):
        m=manifest();m.pop('emotion')
        with self.assertRaises(ValueError):self.validate(m)
    def item(self,entries):
        record={'Data':base64.b64encode(json.dumps(entries).encode()).decode()}
        return {'data':{'B':base64.b64encode(json.dumps(record).encode()).decode()}}
    def test_catalogue_decoding(self):
        entry=dict(name='users',kind='api',stack_name='agent-gateway-test-demo-api-users')
        self.assertEqual(demos.catalogue({'stack':'agent-gateway-test'},self.item({'api:users':entry})),[entry])
    def test_catalogue_cannot_select_unrelated_stack(self):
        entry=dict(name='users',kind='api',stack_name='unrelated')
        with self.assertRaises(RuntimeError):demos.catalogue({'stack':'agent-gateway-test'},self.item({'api:users':entry}))
    def test_delete_requires_confirmed_account_before_reading_stacks(self):
        with patch.object(demos,'call',return_value={'Account':'123456789012','Arn':'arn:aws:sts::123456789012:assumed-role/Test/session'}) as aws,contextlib.redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):
            demos.run(['delete-all','--confirm-account','000000000000'])
        self.assertEqual(aws.call_count,1)
    def test_ownership_tags_checked_before_any_delete(self):
        config=dict(stack='agent-gateway-test',region='eu-west-3',account='123456789012',deployment_role='arn:aws:iam::123456789012:role/agent-gateway-test-demo-deployer',table='test-table')
        entries={'api:users':dict(name='users',kind='api',stack_name='agent-gateway-test-demo-api-users')}
        outputs=[{'OutputKey':'DemoConfiguration','OutputValue':json.dumps(config)}]
        responses=[{'Account':config['account'],'Arn':'arn:aws:sts::123456789012:assumed-role/Test/session'},{'Stacks':[{'Outputs':outputs}]},{'Item':self.item(entries)},{'Stacks':[{'StackStatus':'CREATE_COMPLETE','Tags':[]}]}]
        with patch.object(demos,'call',side_effect=responses) as aws,self.assertRaisesRegex(RuntimeError,'ownership tag'):
            demos.run(['delete-all','--stack',config['stack'],'--confirm-account',config['account']])
        self.assertFalse(any('delete-stack' in args.args for args in aws.call_args_list))
    def test_customer_preflight_uses_no_source_or_cloud_tools(self):
        with tempfile.TemporaryDirectory() as folder:
            folder=pathlib.Path(folder);(folder/'release.json').write_text(json.dumps(manifest()));(folder/'customer.key').write_text('fixture, not a real key')
            for name in release.SERVICES:(folder/(name+'.token')).write_text('fixture, not a real licence')
            fake=folder/'aws';fake.write_text('#!/bin/sh\nexit 99\n');fake.chmod(0o700)
            args=['make','-s','aws-preflight','RELEASE_MANIFEST='+str(folder/'release.json'),'CUSTOMER_KEY_FILE='+str(folder/'customer.key'),'LICENCE_DIR='+str(folder),'AWS_ACCOUNT=123456789012','DOMAIN_PREFIX=test-prefix','ADMIN_EMAILS=test@example.test']
            env=dict(os.environ,PATH=str(folder)+os.pathsep+os.environ['PATH'])
            result=subprocess.run(args,cwd=ROOT,env=env,text=True,capture_output=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertIn('No AWS resources created',result.stdout)
    def test_owned_delete_waits_for_exact_stack(self):
        config=dict(stack='agent-gateway-test',region='eu-west-3',account='123456789012',deployment_role='arn:aws:iam::123456789012:role/agent-gateway-test-demo-deployer',table='test-table')
        entries={'api:users':dict(name='users',kind='api',stack_name='agent-gateway-test-demo-api-users')}
        responses=[{'Account':config['account'],'Arn':'arn:aws:sts::123456789012:assumed-role/Test/session'},{'Stacks':[{'Outputs':[{'OutputKey':'DemoConfiguration','OutputValue':json.dumps(config)}]}]},{'Item':self.item(entries)},{'Stacks':[{'StackStatus':'CREATE_COMPLETE','Tags':[{'Key':'agent-gateway-parent','Value':config['stack']}]}]},{},{}]
        with patch.object(demos,'call',side_effect=responses) as aws,contextlib.redirect_stdout(io.StringIO()):
            demos.run(['delete-all','--stack',config['stack'],'--confirm-account',config['account']])
        self.assertIn('delete-stack',aws.call_args_list[-2].args)
        self.assertIn(config['deployment_role'],aws.call_args_list[-2].args)
        self.assertIn('stack-delete-complete',aws.call_args_list[-1].args)
    def test_templates_are_public_deployment_assets_only(self):
        for file in (ROOT/'deploy/aws').glob('*.template.json'):
            template=json.loads(file.read_text());self.assertIn('Resources',template)
        self.assertFalse((ROOT/'cmd').exists());self.assertFalse((ROOT/'go.mod').exists())
if __name__=='__main__':unittest.main()
