#!/usr/bin/env python3
"""Activate only the owned Emotion demo with a vendor-issued licence token."""
import argparse,json,pathlib,re,subprocess,tempfile

def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ['profile','region','stack','token']:p.add_argument('--'+name,required=True)
    p.add_argument('--image-uri',help='optional immutable Emotion image URI to deploy')
    a=p.parse_args()
    token_file=pathlib.Path(a.token)
    if not token_file.is_file() or not token_file.stat().st_size or token_file.stat().st_size>64*1024:
        p.error('Licence token must exist and be between 1 byte and 64 KiB.')
    def aws(*args):
        r=subprocess.run(['aws','--profile',a.profile,'--region',a.region,*args,'--output','json'],capture_output=True,text=True)
        if r.returncode:raise RuntimeError(r.stderr.strip())
        return json.loads(r.stdout or '{}')
    identity=aws('sts','get-caller-identity')
    if identity['Arn'].endswith(':root'):p.error('Use the non-root deployment profile.')
    name=a.stack+'-demo-mcp-emotion'
    stack=aws('cloudformation','describe-stacks','--stack-name',name)['Stacks'][0]
    if stack['StackId'].split(':')[4]!=identity['Account']:p.error('Stack/account mismatch')
    template=aws('cloudformation','get-template','--stack-name',name)['TemplateBody']
    if isinstance(template,str):template=json.loads(template)
    backend=template['Resources']['EmotionFunction']['Properties']
    env=backend['Environment']['Variables']
    bucket=env['EMOTION_LICENCE_BUCKET'];token_object=env.get('EMOTION_LICENCE_OBJECT','activation/emotion.token')
    if token_object!='activation/emotion.token':p.error('Unexpected licence token object path')
    prefix=f"{identity['Account']}.dkr.ecr.{a.region}.amazonaws.com/{a.stack}/emotion@sha256:"
    if a.image_uri and (not a.image_uri.startswith(prefix) or not re.fullmatch(re.escape(prefix)+r'[0-9a-f]{64}',a.image_uri)):
        p.error('Image URI must be an immutable digest in this account, region and Emotion repository.')
    version=aws('s3api','put-object','--bucket',bucket,'--key',token_object,'--body',str(token_file),'--server-side-encryption','AES256','--checksum-algorithm','SHA256').get('VersionId')
    if not version or version=='null':
        raise RuntimeError('Activation bucket versioning is required; refusing to deploy an unpinned licence token.')
    env['EMOTION_LICENCE_BUCKET']=bucket
    env['EMOTION_LICENCE_OBJECT']=token_object
    env['EMOTION_LICENCE_VERSION']=version
    for obsolete in ('LICENCE_S3_BUCKET','CUSTOMER_KEY_S3_OBJECT','CUSTOMER_KEY_S3_VERSION'):
        env.pop(obsolete,None)
    if a.image_uri:
        backend['Code']['ImageUri']=a.image_uri
    parameters=[{'ParameterKey':v['ParameterKey'],'UsePreviousValue':True} for v in stack.get('Parameters',[])]
    with tempfile.TemporaryDirectory(prefix='agw-emotion-activation-') as folder:
        folder=pathlib.Path(folder);tf=folder/'template.json';tf.write_text(json.dumps(template));pf=folder/'parameters.json';pf.write_text(json.dumps(parameters))
        aws('cloudformation','update-stack','--stack-name',name,'--template-body','file://'+str(tf),'--parameters','file://'+str(pf))
        print('Activation update started; waiting for completion...',flush=True)
        aws('cloudformation','wait','stack-update-complete','--stack-name',name)
        function=aws('cloudformation','describe-stack-resource','--stack-name',name,'--logical-resource-id','EmotionFunction')['StackResourceDetail']['PhysicalResourceId']
        event={'version':'2.0','rawPath':'/warmup','headers':{},'body':'','requestContext':{'domainName':'activation.local','http':{'method':'GET','path':'/warmup','protocol':'HTTP/1.1'}}}
        ef=folder/'event.json';ef.write_text(json.dumps(event));rf=folder/'response.json'
        print('Warming the licensed model; initial model startup can take around two minutes...',flush=True)
        aws('lambda','invoke','--function-name',function,'--cli-read-timeout','180','--cli-binary-format','raw-in-base64-out','--payload','file://'+str(ef),str(rf))
        response=json.loads(rf.read_text())
        if response.get('statusCode')!=204:raise RuntimeError('Model warmup did not succeed. Inspect the backend CloudWatch logs; licence validity and key compatibility are enforced by the vendor runtime.')
    print('Emotion activation and model warmup complete. Test through your authorized gateway delegation.')
if __name__=='__main__':
    try:main()
    except (RuntimeError,KeyError,ValueError) as error:raise SystemExit(str(error))
