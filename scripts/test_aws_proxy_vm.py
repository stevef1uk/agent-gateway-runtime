#!/usr/bin/env python3
import contextlib,importlib.util,io,json,pathlib,tempfile,unittest
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
 def test_create_writes_cli_json_parameter_overrides(self):
  config={'account':'123456789012','stack':'agent-gateway-test','gateway_image':'example/gateway:latest','authz_url':'https://abc.execute-api.eu-west-3.amazonaws.com','console_url':'https://console.example.com','table':'agent-gateway-test-domain','security_table':'agent-gateway-test-security','bucket':'agent-gateway-artifacts-test','key_object':'activation/customer.key','key_version':'key-version','gateway_licence_object':'activation/gateway.token','gateway_licence_version':'licence-version'}
  captured={}
  def deploy(command,check):
   parameter_file=pathlib.Path(command[command.index('--parameter-overrides')+1][7:])
   captured['command']=command
   captured['overrides']=json.loads(parameter_file.read_text())
   captured['mode']=parameter_file.stat().st_mode & 0o777
   self.assertTrue(check)
  with tempfile.TemporaryDirectory() as folder,patch.object(vm,'ROOT',pathlib.Path(folder)),patch.object(vm,'deploy_secrets',return_value={'jwt':'test-secret-value'}),patch.object(vm,'call',side_effect=[{'Account':'123456789012','Arn':'arn:aws:sts::123456789012:assumed-role/VM/test'},{'Stacks':[{'Outputs':[{'OutputKey':'DemoConfiguration','OutputValue':json.dumps(config)}]}]},{'Stacks':[{'Outputs':[]}]}]),patch.object(vm.subprocess,'run',side_effect=deploy),contextlib.redirect_stdout(io.StringIO()):
   vm.run(['create','--profile','app','--vm-profile','vm','--stack','agent-gateway-test'])
   self.assertIn('JwtSecretValue=test-secret-value',captured['overrides'])
   self.assertIn('InstanceType=t4g.small',captured['overrides'])
   self.assertEqual(captured['mode'],0o600)
   self.assertNotIn('test-secret-value',' '.join(captured['command']))
   self.assertFalse((pathlib.Path(folder)/'dist/aws-lambda/proxy/overrides.txt').exists())
 def test_template_preserves_source_bootstrap_and_constraints(self):
  template=json.loads((ROOT/'deploy/aws/proxy-vm.template.json').read_text());resources=template['Resources']
  role=resources['ProxyRole']['Properties']
  self.assertEqual(role['PermissionsBoundary'],{'Fn::Sub':'arn:${AWS::Partition}:iam::${AWS::AccountId}:policy/${ApplicationStack}-ProxyRoleBoundary'})
  self.assertEqual(role['Tags'][1],{'Key':'agent-gateway-parent','Value':{'Ref':'ApplicationStack'}})
  self.assertEqual(resources['ProxyProfile']['Properties']['Roles'],[{'Ref':'ProxyRole'}])
  self.assertNotIn('Tags',resources['ProxyProfile']['Properties'])
  userdata=resources['ProxyLaunchTemplate']['Properties']['LaunchTemplateData']['UserData']['Fn::Base64']['Fn::Sub'][0]
  self.assertIn((ROOT/'scripts/proxy-vm-bootstrap.py').read_text().strip(),userdata)
  data=resources['ProxyLaunchTemplate']['Properties']['LaunchTemplateData']
  self.assertEqual(data['MetadataOptions']['HttpTokens'],'required')
  self.assertEqual(data['CreditSpecification']['CpuCredits'],'standard')
  self.assertTrue(data['BlockDeviceMappings'][0]['Ebs']['Encrypted'])
  self.assertTrue(data['BlockDeviceMappings'][0]['Ebs']['DeleteOnTermination'])
  self.assertFalse(any(v['Type']=='AWS::AutoScaling::AutoScalingGroup' for v in resources.values()))
 def test_proxy_role_permissions_are_bounded_and_scoped(self):
  template=json.loads((ROOT/'deploy/aws/deployment-access.template.json').read_text())
  resources=template['Resources']
  params=template['Parameters']
  self.assertEqual(params['ProxyActivationBucket']['Default'],'agent-gateway-proxy-not-configured')
  self.assertEqual(params['ProxyAuthzApiId']['Default'],'notconfigured')
  boundary=resources['ProxyRoleBoundary']['Properties']['PolicyDocument']
  access=resources['ProxyRoleAccess']['Properties']['PolicyDocument']
  self.assertLessEqual(len(json.dumps(boundary,separators=(',',':'))),6144)
  self.assertLessEqual(len(json.dumps(access,separators=(',',':'))),6144)
  activation=next(s for s in boundary['Statement'] if s['Sid']=='GatewayActivation')
  self.assertEqual(activation['Resource'],{'Fn::Sub':'arn:${AWS::Partition}:s3:::${ProxyActivationBucket}/${ProxyGatewayLicenceObject}'})
  state=next(s for s in boundary['Statement'] if s['Sid']=='SharedDomainAndSecurityState')
  self.assertEqual(state['Resource'],[
   {'Fn::Sub':'arn:${AWS::Partition}:dynamodb:${AWS::Region}:${AWS::AccountId}:table/${ApplicationStack}-domain'},
   {'Fn::Sub':'arn:${AWS::Partition}:dynamodb:${AWS::Region}:${AWS::AccountId}:table/${ApplicationStack}-security'}
  ])
  authz=next(s for s in boundary['Statement'] if s['Sid']=='CallOnlyAuthorizationAPI')
  self.assertEqual(authz['Resource'],{'Fn::Sub':'arn:${AWS::Partition}:execute-api:${AWS::Region}:${AWS::AccountId}:${ProxyAuthzApiId}/$default/*/*'})
  ecr=next(s for s in boundary['Statement'] if s['Sid']=='PullOnlyGatewayImage')
  self.assertEqual(ecr['Resource'],{'Fn::Sub':'arn:${AWS::Partition}:ecr:${AWS::Region}:${AWS::AccountId}:repository/${ApplicationStack}/gateway'})
  create=next(s for s in access['Statement'] if s['Sid']=='CreateOnlyBoundedProxyRole')
  role_arn={'Fn::Sub':'arn:${AWS::Partition}:iam::${AWS::AccountId}:role/${ApplicationStack}-proxy-ProxyRole-*'}
  boundary_arn={'Fn::Sub':'arn:${AWS::Partition}:iam::${AWS::AccountId}:policy/${ApplicationStack}-ProxyRoleBoundary'}
  self.assertEqual(create['Resource'],role_arn)
  self.assertEqual(create['Condition']['StringEquals']['iam:PermissionsBoundary'],boundary_arn)
  attach=next(s for s in access['Statement'] if s['Sid']=='AttachOnlyProxySsmPolicy')
  self.assertEqual(attach['Resource'],role_arn)
  self.assertEqual(attach['Condition']['StringEquals']['iam:PolicyARN'],{'Fn::Sub':'arn:${AWS::Partition}:iam::aws:policy/AmazonSSMManagedInstanceCore'})
  passed=next(s for s in access['Statement'] if s['Sid']=='PassOnlyProxyRoleToEc2')
  self.assertEqual(passed['Resource'],role_arn)
  self.assertEqual(passed['Condition']['StringEquals']['iam:PassedToService'],'ec2.amazonaws.com')
  profile=next(s for s in access['Statement'] if s['Sid']=='CreateAndManageProxyInstanceProfile')
  self.assertEqual(profile['Resource'],{'Fn::Sub':'arn:${AWS::Partition}:iam::${AWS::AccountId}:instance-profile/${ApplicationStack}-proxy-ProxyProfile-*'})
  self.assertNotIn('iam:TagInstanceProfile',profile['Action'])
  self.assertNotIn('iam:UntagInstanceProfile',profile['Action'])
  self.assertNotIn('iam:UpdateAssumeRolePolicy',json.dumps(access))
 def test_deployment_access_scopes_cloudformation_lifecycle_to_proxy_stack(self):
  template=json.loads((ROOT/'deploy/aws/deployment-access.template.json').read_text())
  deployment_access=template['Resources']['DeploymentAccess']['Properties']['PolicyDocument']
  statements=deployment_access['Statement']
  ami=next(statement for statement in statements if statement['Sid']=='ResolveProxyAmiParameter')
  self.assertEqual(ami['Action'],'ssm:GetParameters')
  self.assertEqual(ami['Resource'],{'Fn::Sub':'arn:${AWS::Partition}:ssm:${AWS::Region}::parameter/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64'})
  describe_ami=next(statement for statement in statements if statement['Sid']=='DescribeProxyAmi')
  self.assertEqual(describe_ami['Action'],'ec2:DescribeImages')
  self.assertEqual(describe_ami['Resource'],'*')
  self.assertEqual(describe_ami['Condition']['StringEquals']['aws:RequestedRegion'],{'Ref':'AWS::Region'})
  proxy_network=template['Resources']['ProxyNetworkAccess']['Properties']['PolicyDocument']
  self.assertLessEqual(len(json.dumps(deployment_access,separators=(',',':'))),6144)
  self.assertLessEqual(len(json.dumps(proxy_network,separators=(',',':'))),6144)
  proxy_statements=proxy_network['Statement']
  vpc_arn={'Fn::Sub':'arn:${AWS::Partition}:ec2:${AWS::Region}:${AWS::AccountId}:vpc/*'}
  describe_vpcs=next(statement for statement in proxy_statements if statement['Sid']=='DescribeProxyVpcs')
  self.assertEqual(describe_vpcs['Action'],'ec2:DescribeVpcs')
  self.assertEqual(describe_vpcs['Resource'],'*')
  self.assertEqual(describe_vpcs['Condition']['StringEquals']['aws:RequestedRegion'],{'Ref':'AWS::Region'})
  modify_vpc=next(statement for statement in proxy_statements if statement['Sid']=='ModifyProxyVpcAttributes')
  self.assertEqual(modify_vpc['Action'],'ec2:ModifyVpcAttribute')
  self.assertEqual(modify_vpc['Resource'],vpc_arn)
  self.assertEqual(modify_vpc['Condition']['StringEquals']['ec2:ResourceTag/Name'],{'Fn::Sub':'${ApplicationStack}-proxy-vpc'})
  self.assertEqual(modify_vpc['Condition']['StringEquals']['ec2:ResourceTag/agent-gateway-parent'],{'Ref':'ApplicationStack'})
  self.assertEqual(modify_vpc['Condition']['StringEquals']['aws:RequestedRegion'],{'Ref':'AWS::Region'})
  delete_vpc=next(statement for statement in proxy_statements if statement['Sid']=='DeleteProxyVpc')
  self.assertEqual(delete_vpc['Action'],'ec2:DeleteVpc')
  self.assertEqual(delete_vpc['Resource'],vpc_arn)
  self.assertEqual(delete_vpc['Condition']['StringEquals']['ec2:ResourceTag/Name'],{'Fn::Sub':'${ApplicationStack}-proxy-vpc'})
  self.assertEqual(delete_vpc['Condition']['StringEquals']['ec2:ResourceTag/agent-gateway-parent'],{'Ref':'ApplicationStack'})
  gateway_arn={'Fn::Sub':'arn:${AWS::Partition}:ec2:${AWS::Region}:${AWS::AccountId}:internet-gateway/*'}
  create_gateway=next(statement for statement in proxy_statements if statement['Sid']=='CreateProxyInternetGateway')
  self.assertEqual(create_gateway['Action'],'ec2:CreateInternetGateway')
  self.assertEqual(create_gateway['Resource'],gateway_arn)
  self.assertEqual(create_gateway['Condition']['ForAllValues:StringEquals']['aws:TagKeys'],['Name','agent-gateway-parent'])
  self.assertEqual(create_gateway['Condition']['StringEquals']['aws:RequestTag/Name'],{'Fn::Sub':'${ApplicationStack}-proxy-internet'})
  self.assertEqual(create_gateway['Condition']['StringEquals']['aws:RequestTag/agent-gateway-parent'],{'Ref':'ApplicationStack'})
  tag_gateway=next(statement for statement in proxy_statements if statement['Sid']=='TagProxyInternetGatewayOnCreate')
  self.assertEqual(tag_gateway['Action'],'ec2:CreateTags')
  self.assertEqual(tag_gateway['Resource'],gateway_arn)
  self.assertEqual(tag_gateway['Condition']['StringEquals']['ec2:CreateAction'],'CreateInternetGateway')
  describe_gateway=next(statement for statement in proxy_statements if statement['Sid']=='DescribeProxyInternetGateways')
  self.assertEqual(describe_gateway['Action'],'ec2:DescribeInternetGateways')
  self.assertEqual(describe_gateway['Resource'],'*')
  self.assertEqual(describe_gateway['Condition']['StringEquals']['aws:RequestedRegion'],{'Ref':'AWS::Region'})
  detach_gateway=next(statement for statement in proxy_statements if statement['Sid']=='DetachProxyInternetGateway')
  self.assertEqual(detach_gateway['Action'],'ec2:DetachInternetGateway')
  self.assertEqual(detach_gateway['Resource'],[gateway_arn,{'Fn::Sub':'arn:${AWS::Partition}:ec2:${AWS::Region}:${AWS::AccountId}:vpc/*'}])
  delete_gateway=next(statement for statement in proxy_statements if statement['Sid']=='DeleteProxyInternetGateway')
  self.assertEqual(delete_gateway['Action'],'ec2:DeleteInternetGateway')
  self.assertEqual(delete_gateway['Resource'],gateway_arn)
  create_vpc=next(statement for statement in proxy_statements if statement['Sid']=='CreateProxyVpc')
  self.assertEqual(create_vpc['Action'],'ec2:CreateVpc')
  self.assertEqual(create_vpc['Resource'],vpc_arn)
  self.assertEqual(create_vpc['Condition']['ForAllValues:StringEquals']['aws:TagKeys'],['Name','agent-gateway-parent'])
  self.assertEqual(create_vpc['Condition']['StringEquals']['aws:RequestTag/Name'],{'Fn::Sub':'${ApplicationStack}-proxy-vpc'})
  self.assertEqual(create_vpc['Condition']['StringEquals']['aws:RequestTag/agent-gateway-parent'],{'Ref':'ApplicationStack'})
  tag_vpc=next(statement for statement in proxy_statements if statement['Sid']=='TagProxyVpcOnCreate')
  self.assertEqual(tag_vpc['Action'],'ec2:CreateTags')
  self.assertEqual(tag_vpc['Resource'],vpc_arn)
  self.assertEqual(tag_vpc['Condition']['StringEquals']['ec2:CreateAction'],'CreateVpc')
  lifecycle=next(statement for statement in statements if statement['Sid']=='CloudFormationLifecycle')
  resources=lifecycle['Resource']
  self.assertIn('cloudformation:ListChangeSets',lifecycle['Action'])
  self.assertIn({'Fn::Sub':'arn:${AWS::Partition}:cloudformation:${AWS::Region}:${AWS::AccountId}:stack/${ApplicationStack}-proxy/*'},resources)
  self.assertNotIn('*',resources)
if __name__=='__main__':unittest.main()
