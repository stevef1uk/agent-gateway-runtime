#!/usr/bin/env python3
"""Explicit lifecycle for the optional SSM-only proxy VM. No default action creates resources."""
import argparse,json,os,pathlib,subprocess,sys
ROOT=pathlib.Path(__file__).resolve().parents[1]
def call(profile,region,*args):
 p=subprocess.run(['aws','--profile',profile,'--region',region,'--no-cli-pager',*args,'--output','json'],text=True,capture_output=True)
 if p.returncode:raise RuntimeError(p.stderr.strip())
 return json.loads(p.stdout or '{}')
def parameters(config,instance_type):
 values=dict(ApplicationStack=config['stack'],GatewayImageUri=config['gateway_image'],AuthzURL=config['authz_url'],ConsoleURL=config['console_url'],DomainTable=config['table'],SecurityTable=config['security_table'],JWTSecretArn=config['jwt_secret_arn'],ActivationBucket=config['bucket'],CustomerKeyObject=config['key_object'],CustomerKeyVersion=config['key_version'],GatewayLicenceObject=config['gateway_licence_object'],GatewayLicenceVersion=config['gateway_licence_version'],InstanceType=instance_type,AuthzAPIId=config['authz_url'].split('://',1)[1].split('.',1)[0])
 return [{'ParameterKey':k,'ParameterValue':v} for k,v in values.items()]
def run(argv=None):
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('action',choices=['create','status','connect','delete','plan']);p.add_argument('--profile',default=os.getenv('AWS_PROFILE','agent-gateway-dev'));p.add_argument('--vm-profile',default=os.getenv('AWS_VM_PROFILE',''));p.add_argument('--region',default=os.getenv('AWS_REGION','eu-west-3'));p.add_argument('--stack',default=os.getenv('AWS_STACK','agent-gateway-dev'));p.add_argument('--instance-type',default='t4g.small',choices=['t4g.small','t4g.medium']);p.add_argument('--local-port',type=int,default=8088);p.add_argument('--config',type=pathlib.Path)
 a=p.parse_args(argv);vm_stack=a.stack+'-proxy'
 if a.action=='plan':
  if not a.config:p.error('plan requires --config with a public deployment-identifier JSON file')
  print(json.dumps(parameters(json.loads(a.config.read_text()),a.instance_type),indent=2));return
 if not a.vm_profile:p.error('set AWS_VM_PROFILE or --vm-profile to an explicitly reviewed EC2/CloudFormation/SSM deployment profile')
 identity=call(a.vm_profile,a.region,'sts','get-caller-identity')
 if identity['Arn'].endswith(':root') and a.action in ['create','delete']:raise RuntimeError('Use an approved non-root VM deployment role/profile for resource changes.')
 def describe():
  return call(a.vm_profile,a.region,'cloudformation','describe-stacks','--stack-name',vm_stack)['Stacks'][0]
 if a.action=='create':
  parent=call(a.profile,a.region,'cloudformation','describe-stacks','--stack-name',a.stack)['Stacks'][0]
  configs=[o['OutputValue'] for o in parent.get('Outputs',[]) if o['OutputKey']=='DemoConfiguration']
  if len(configs)!=1:raise RuntimeError('Deploy the wizard-enabled parent stack first; its DemoConfiguration output supplies the exact shared services/images.')
  config=json.loads(configs[0])
  if config['account']!=identity['Account']:raise RuntimeError('VM profile and parent stack must be in the same account.')
  folder=ROOT/'dist/aws-lambda/proxy';folder.mkdir(parents=True,exist_ok=True)
  params=folder/'parameters.json';params.write_text(json.dumps(parameters(config,a.instance_type),indent=2)+'\n')
  # aws cloudformation deploy handles create/update/no-change and waits. This is the only billable create path.
  command=['aws','--profile',a.vm_profile,'--region',a.region,'cloudformation','deploy','--stack-name',vm_stack,'--template-file',str(ROOT/'deploy/aws/proxy-vm.template.json'),'--parameter-overrides',*[v['ParameterKey']+'='+v['ParameterValue'] for v in parameters(config,a.instance_type)],'--capabilities','CAPABILITY_IAM','--no-fail-on-empty-changeset']
  subprocess.run(command,check=True)
  print(json.dumps({'stack':vm_stack,'outputs':describe().get('Outputs',[])},indent=2));return
 if a.action=='delete':
  try:describe()
  except RuntimeError as e:
   if 'does not exist' in str(e):print('Proxy stack is already absent.');return
   raise
  call(a.vm_profile,a.region,'cloudformation','delete-stack','--stack-name',vm_stack)
  subprocess.run(['aws','--profile',a.vm_profile,'--region',a.region,'cloudformation','wait','stack-delete-complete','--stack-name',vm_stack],check=True)
  print('Deleted proxy stack, instance, encrypted root volume and stack-owned network resources. Shared application/data/images are retained.');return
 stack=describe();outputs={o['OutputKey']:o['OutputValue'] for o in stack.get('Outputs',[])}
 if a.action=='status':print(json.dumps({'stack':vm_stack,'status':stack['StackStatus'],'outputs':outputs},indent=2));return
 instance=outputs['InstanceId']
 subprocess.run(['aws','--profile',a.vm_profile,'--region',a.region,'ssm','start-session','--target',instance,'--document-name','AWS-StartPortForwardingSession','--parameters',json.dumps({'portNumber':['8088'],'localPortNumber':[str(a.local_port)]})],check=True)
if __name__=='__main__':
 try:run()
 except (RuntimeError,subprocess.CalledProcessError) as e:print('proxy-vm:',e,file=sys.stderr);sys.exit(1)
