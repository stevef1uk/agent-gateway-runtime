#!/usr/bin/env python3
"""Boot-time configuration for the optional proxy VM; never logs secret contents."""
import json,os,pathlib,subprocess
config=json.loads(pathlib.Path('/etc/agent-gateway-proxy/config.json').read_text())
def aws(*args):
 return subprocess.check_output(['aws','--region',config['region'],*args],text=True).strip()
secret=config['jwt_secret']
if '\n' in secret or '\r' in secret:raise SystemExit('JWT secret is not a valid environment value')
env={
 'JWT_SECRET':secret,'JWT_ISSUER':'agent-gateway','PERSISTENCE':'dynamodb',
 'DYNAMODB_TABLE':config['table'],'DYNAMODB_NAMESPACE':config['application_stack'],
 'DYNAMODB_SECURITY_TABLE':config['security_table'],'DYNAMODB_SECURITY_NAMESPACE':config['application_stack'],
 'AUTHZ_URL':config['authz_url'],'AUTHZ_IAM_REGION':config['region'],'AWS_REGION':config['region'],
 'GATEWAY_ADDR':'127.0.0.1:8080','GATEWAY_PROXY_ADDR':'127.0.0.1:8088',
 'GATEWAY_URL':'http://127.0.0.1:8080','GATEWAY_ADMIN_TOKEN':'','DEMO_UI':'0',
 'APPROVAL_CONSOLE_URL':config['console_url'],'LICENCE_S3_BUCKET':config['activation_bucket'],
 'CUSTOMER_KEY_S3_OBJECT':config['key_object'],'CUSTOMER_KEY_S3_VERSION':config['key_version'],
 'LICENCE_S3_OBJECT':config['gateway_licence_object'],'LICENCE_S3_VERSION':config['gateway_licence_version'],
}
path=pathlib.Path('/etc/agent-gateway-proxy/runtime.env');fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
with os.fdopen(fd,'w') as f:
 for key,value in env.items():
  if '\n' in value or '\r' in value:raise SystemExit('Invalid environment configuration')
  f.write(key+'='+value+'\n')
registry=config['gateway_image'].split('/')[0]
password=aws('ecr','get-login-password')
subprocess.run(['docker','login','--username','AWS','--password-stdin',registry],input=password,text=True,check=True,stdout=subprocess.DEVNULL)
subprocess.run(['docker','pull',config['gateway_image']],check=True,stdout=subprocess.DEVNULL)
subprocess.run(['docker','rm','--force','agent-gateway-proxy'],check=False,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
os.execvp('docker',['docker','run','--rm','--name','agent-gateway-proxy','--network','host','--read-only','--cap-drop','ALL','--security-opt','no-new-privileges','--memory','768m','--cpus','1','--tmpfs','/tmp:rw,exec,nosuid,size=512m','--env-file',str(path),config['gateway_image']])
