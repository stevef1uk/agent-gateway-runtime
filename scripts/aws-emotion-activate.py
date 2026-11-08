#!/usr/bin/env python3
"""Activate only the owned Emotion demo with customer-supplied private files."""
import argparse,json,pathlib,subprocess,tempfile

def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ['profile','region','stack','token','key']:p.add_argument('--'+name,required=True)
    a=p.parse_args()
    for file in [a.token,a.key]:
        if not pathlib.Path(file).is_file():p.error('Missing activation file: '+file)
    check=subprocess.run(['openssl','pkey','-in',a.key,'-noout','-passin','pass:'],capture_output=True)
    if check.returncode:p.error('Customer private key is not readable; provide a valid unencrypted PEM key.')
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
    bucket=env['LICENCE_S3_BUCKET'];key_object=env['CUSTOMER_KEY_S3_OBJECT']
    if not key_object.startswith('activation/'):p.error('Unexpected activation object path')
    def upload(file,object_key):
        return aws('s3api','put-object','--bucket',bucket,'--key',object_key,'--body',file,'--server-side-encryption','AES256','--checksum-algorithm','SHA256')['VersionId']
    env['EMOTION_LICENCE_BUCKET']=bucket;env['EMOTION_LICENCE_OBJECT']='activation/emotion.token'
    env['EMOTION_LICENCE_VERSION']=upload(a.token,'activation/emotion.token')
    env['CUSTOMER_KEY_S3_VERSION']=upload(a.key,key_object)
    # Only the child backend receives these new versions. Parent/gateway versions stay pinned.
    parameters=[{'ParameterKey':v['ParameterKey'],'UsePreviousValue':True} for v in stack.get('Parameters',[])]
    with tempfile.TemporaryDirectory(prefix='agw-emotion-activation-') as folder:
        folder=pathlib.Path(folder);tf=folder/'template.json';tf.write_text(json.dumps(template));pf=folder/'parameters.json';pf.write_text(json.dumps(parameters))
        aws('cloudformation','update-stack','--stack-name',name,'--template-body','file://'+str(tf),'--parameters','file://'+str(pf))
        print('Activation update started; waiting for completion...',flush=True)
        aws('cloudformation','wait','stack-update-complete','--stack-name',name)
        function=aws('cloudformation','describe-stack-resource','--stack-name',name,'--logical-resource-id','EmotionFunction')['StackResourceDetail']['PhysicalResourceId']
        event={'version':'2.0','rawPath':'/warmup','headers':{},'body':'','requestContext':{'domainName':'activation.local','http':{'method':'GET','path':'/warmup','protocol':'HTTP/1.1'}}}
        ef=folder/'event.json';ef.write_text(json.dumps(event));rf=folder/'response.json'
        print('Warming the licensed model; first decryption can take around two minutes...',flush=True)
        aws('lambda','invoke','--function-name',function,'--cli-read-timeout','180','--cli-binary-format','raw-in-base64-out','--payload','file://'+str(ef),str(rf))
        response=json.loads(rf.read_text())
        if response.get('statusCode')!=204:raise RuntimeError('Model warmup did not succeed. Inspect the backend CloudWatch logs; licence validity and key compatibility are enforced by the vendor runtime.')
    print('Emotion activation and model warmup complete. Test through your authorized gateway delegation.')
if __name__=='__main__':
    try:main()
    except (RuntimeError,KeyError,ValueError) as error:raise SystemExit(str(error))
