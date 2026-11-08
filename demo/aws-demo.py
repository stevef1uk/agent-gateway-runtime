#!/usr/bin/env python3
"""Public AWS demo probes. Approval/revocation remain human console decisions."""
import argparse, getpass, json, os, re, subprocess, tempfile
PRESETS = {
    'weather': ('GET', '/api-weather/v1/forecast?latitude=51.5072&longitude=-0.1276&current=temperature_2m', None),
    'geocoding': ('GET', '/api-geocoding/v1/search?name=London&count=1', None),
    'users': ('GET', '/api-users/users/1', None),
    'refunds': ('POST', '/api-refunds/posts', {'title':'Disposable refund simulation','body':'No money moves','userId':1,'amount':25}),
    'emotion': ('POST', '/mcp-emotion', None),
}
def request(url, token, method, body=None, proxy=None):
    with tempfile.TemporaryDirectory() as folder:
        output=folder+'/response'
        args=['curl','-q','--silent','--show-error','--max-time','210','--output',output,'--write-out','%{http_code}','-X',method]
        header='Proxy-Authorization' if proxy else 'Authorization'
        if token: args += ['-H',header+': Bearer '+token]
        if proxy: args += ['--noproxy','','--proxy',proxy]
        if body is not None: args += ['-H','Content-Type: application/json','-H','Accept: application/json, text/event-stream','--data',json.dumps(body)]
        result=subprocess.run(args+[url],text=True,capture_output=True)
        if result.returncode: raise RuntimeError('curl failed: '+result.stderr.strip())
        data=open(output).read()
        return int(result.stdout),data

def run():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('demo',choices=[*PRESETS,'proxy'])
    p.add_argument('phase',choices=['access','held','approved','revoked'],default='access',nargs='?')
    a=p.parse_args()
    token=os.getenv('AGENT_TOKEN') or getpass.getpass('Agent token: ')
    if not token: p.error('an agent token is required')
    proxy=None
    if a.demo=='proxy':
        proxy=os.getenv('PROXY_URL','http://127.0.0.1:8088')
        if not re.fullmatch(r'http://127\.0\.0\.1:[0-9]+',proxy): p.error('PROXY_URL must be your local SSM tunnel, http://127.0.0.1:PORT')
        url='http://example.com/';method='GET';body=None
    else:
        gateway=os.getenv('GATEWAY_URL','').rstrip('/')
        if not re.fullmatch(r'https://[a-z0-9]+\.execute-api\.[a-z0-9-]+\.amazonaws\.com',gateway): p.error('set GATEWAY_URL to the owning child demo GatewayURL, without a path')
        method,path,body=PRESETS[a.demo];url=gateway+path
        if a.demo=='emotion':
            tool='emotion_detection_detailed' if a.phase in ['held','approved'] else 'emotion_detection'
            body={'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':tool,'arguments':{'text':'I feel happy today'}}}
    expected=403 if a.phase=='revoked' else 202 if a.phase=='held' else 201 if a.demo=='refunds' else 200
    status,data=request(url,token,method,body,proxy)
    if status!=expected: raise RuntimeError(f'Expected HTTP {expected}, received {status}. Check delegation scope, approval and upstream health.')
    if status==202:
        payload=json.loads(data)
        approval=payload.get('approval_id') or payload.get('result',{}).get('approval_id')
        if not approval: raise RuntimeError('Held response has no approval_id')
        print('Approve in the signed-in console, then rerun approved. Approval ID:',approval)
    print(f'PASS {a.demo} {a.phase}: HTTP {status}')
    if a.demo=='emotion' and status==200:
        print('Vendor MCP response (a native licence error is valid):')
        print(data)
    if a.phase=='approved': print('For a single-use approval, rerun held to verify the approval was consumed.')
if __name__=='__main__':
    try: run()
    except (RuntimeError,ValueError) as error: raise SystemExit(str(error))
