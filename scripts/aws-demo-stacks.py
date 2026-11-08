#!/usr/bin/env python3
"""List/delete only catalogue-owned demo stacks; never scans unrelated stacks."""
import argparse,base64,hashlib,json,os,re,subprocess,sys

def call(profile,region,*args):
    result=subprocess.run(['aws','--profile',profile,'--region',region,'--no-cli-pager',*args,'--output','json'],capture_output=True,text=True)
    if result.returncode:raise RuntimeError(result.stderr.strip())
    return json.loads(result.stdout or '{}')

def catalogue(config,item):
    if not item:return []
    record=json.loads(base64.b64decode(item['data']['B']))
    entries=json.loads(base64.b64decode(record['Data']))
    result=[]
    for key,entry in entries.items():
        name,kind=entry['name'],entry['kind']
        if not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,24}',name) or kind not in ['api','mcp']:raise RuntimeError('Invalid catalogue entry; no stacks deleted.')
        expected=config['stack']+'-demo-'+kind+'-'+name
        if key!=kind+':'+name or entry['stack_name']!=expected:raise RuntimeError('Catalogue ownership mismatch; no stacks deleted.')
        result.append(dict(entry))
    return result

def run(argv=None):
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('action',choices=['list','delete','delete-all'])
    p.add_argument('--profile',default=os.getenv('AWS_PROFILE','agent-gateway-dev'));p.add_argument('--region',default=os.getenv('AWS_REGION','eu-west-3'))
    p.add_argument('--stack',default=os.getenv('AWS_STACK','agent-gateway-dev'));p.add_argument('--name');p.add_argument('--kind',choices=['api','mcp'],default='api');p.add_argument('--confirm-account')
    a=p.parse_args(argv)
    if not re.fullmatch(r'agent-gateway-[a-z0-9-]+',a.stack):p.error('Invalid application stack name')
    identity=call(a.profile,a.region,'sts','get-caller-identity')
    if a.action!='list':
        if a.confirm_account!=identity['Account']:p.error('Set CONFIRM_ACCOUNT to the selected 12-digit AWS account before deletion')
        if identity['Arn'].endswith(':root'):p.error('Use a non-root deployment profile for deletion')
    parent=call(a.profile,a.region,'cloudformation','describe-stacks','--stack-name',a.stack)['Stacks'][0]
    outputs={o['OutputKey']:o['OutputValue'] for o in parent.get('Outputs',[])}
    config=json.loads(outputs.get('DemoConfiguration','{}'))
    if config.get('stack')!=a.stack or config.get('region')!=a.region or config.get('account')!=identity['Account']:raise RuntimeError('Missing/mismatched parent DemoConfiguration; no stacks deleted.')
    expected_role='arn:aws:iam::'+identity['Account']+':role/'+a.stack+'-demo-deployer'
    if config.get('deployment_role')!=expected_role:raise RuntimeError('Unexpected demo deployment role; no stacks deleted.')
    pk=base64.urlsafe_b64encode(a.stack.encode()).decode().rstrip('=')+':session:aws-demo-catalogue'
    key={'pk':{'S':pk},'sk':{'S':hashlib.sha256(b'deployments').hexdigest()}}
    item=call(a.profile,a.region,'dynamodb','get-item','--table-name',config['table'],'--key',json.dumps(key),'--consistent-read').get('Item')
    entries=catalogue(config,item)
    if a.action=='delete':
        if not a.name:p.error('delete requires --name')
        entries=[entry for entry in entries if entry['name']==a.name and entry['kind']==a.kind]
        if not entries:raise RuntimeError('Demo is not in the owned catalogue; no stack deleted.')
    # Validate all ownership tags before starting any deletion.
    live=[]
    for entry in entries:
        try:stack=call(a.profile,a.region,'cloudformation','describe-stacks','--stack-name',entry['stack_name'])['Stacks'][0]
        except RuntimeError as error:
            if 'does not exist' in str(error):continue
            raise
        tags={v['Key']:v['Value'] for v in stack.get('Tags',[])}
        if tags.get('agent-gateway-parent')!=a.stack:raise RuntimeError('Stack ownership tag mismatch; no stacks deleted.')
        entry['status']=stack['StackStatus']
        entry['gateway_url']=next((o['OutputValue'] for o in stack.get('Outputs',[]) if o['OutputKey']=='GatewayURL'),'')
        live.append(entry)
    if a.action=='list':print(json.dumps(live,indent=2));return
    for entry in live:
        call(a.profile,a.region,'cloudformation','delete-stack','--stack-name',entry['stack_name'],'--role-arn',expected_role)
        call(a.profile,a.region,'cloudformation','wait','stack-delete-complete','--stack-name',entry['stack_name'])
        print('Deleted owned demo:',entry['stack_name'])
if __name__=='__main__':
    try:run()
    except (RuntimeError,KeyError,ValueError) as error:raise SystemExit(str(error))
