#!/usr/bin/env python3
import contextlib,importlib.util,io,json,pathlib,unittest
from unittest.mock import patch
ROOT=pathlib.Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('vm',ROOT/'scripts/aws-proxy-vm.py');vm=importlib.util.module_from_spec(spec);spec.loader.exec_module(vm)
class ProxyLifecycle(unittest.TestCase):
 def test_offline_plan_does_not_call_aws(self):
  with patch.object(vm,'call') as aws,contextlib.redirect_stdout(io.StringIO()) as output:
   vm.run(['plan','--config',str(ROOT/'deploy/aws/demo-config.example.json')])
   aws.assert_not_called();params=json.loads(output.getvalue())
   self.assertEqual(next(v['ParameterValue'] for v in params if v['ParameterKey']=='InstanceType'),'t4g.small')
 def test_profile_is_explicit(self):
  with patch.dict(vm.os.environ,{},clear=True),patch.object(vm,'call') as aws,contextlib.redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):
   vm.run(['create']);aws.assert_not_called()
 def test_root_cannot_mutate(self):
  with patch.object(vm,'call',return_value={'Arn':'arn:aws:iam::123456789012:root'}),self.assertRaisesRegex(RuntimeError,'non-root'):
   vm.run(['delete','--vm-profile','test'])
 def test_delete_waits_and_never_reads_parent(self):
  with patch.object(vm,'call',side_effect=[{'Arn':'arn:aws:sts::123456789012:assumed-role/VM/test'},{'Stacks':[{'StackStatus':'CREATE_COMPLETE'}]},{}]) as aws,patch.object(vm.subprocess,'run') as run,contextlib.redirect_stdout(io.StringIO()):
   vm.run(['delete','--vm-profile','test','--stack','agent-gateway-test'])
   self.assertEqual(aws.call_args_list[1].args[-1],'agent-gateway-test-proxy')
   self.assertIn('stack-delete-complete',run.call_args.args[0])
 def test_template_preserves_source_bootstrap_and_constraints(self):
  template=json.loads((ROOT/'deploy/aws/proxy-vm.template.json').read_text());resources=template['Resources']
  userdata=resources['ProxyLaunchTemplate']['Properties']['LaunchTemplateData']['UserData']['Fn::Base64']['Fn::Sub'][0]
  self.assertIn((ROOT/'scripts/proxy-vm-bootstrap.py').read_text().strip(),userdata)
  data=resources['ProxyLaunchTemplate']['Properties']['LaunchTemplateData']
  self.assertEqual(data['MetadataOptions']['HttpTokens'],'required')
  self.assertEqual(data['CreditSpecification']['CpuCredits'],'standard')
  self.assertTrue(data['BlockDeviceMappings'][0]['Ebs']['Encrypted'])
  self.assertTrue(data['BlockDeviceMappings'][0]['Ebs']['DeleteOnTermination'])
  self.assertFalse(any(v['Type']=='AWS::AutoScaling::AutoScalingGroup' for v in resources.values()))
if __name__=='__main__':unittest.main()
