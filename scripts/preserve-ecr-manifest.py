#!/usr/bin/env python3
"""Restore the verified vendor manifest if a Docker push recompressed a base layer."""
import argparse,hashlib,json,pathlib,subprocess,tempfile,urllib.request,urllib.parse

def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ['source','repository','digest','profile','region']:p.add_argument('--'+name,required=True)
    a=p.parse_args()
    if not a.source.startswith('stevef1uk/agent-gateway-') or not a.source.endswith('@'+a.digest):p.error('Expected a pinned vendor image')
    def aws(*args):
        r=subprocess.run(['aws','--profile',a.profile,'--region',a.region,*args,'--output','json'],capture_output=True,text=True)
        if r.returncode:raise RuntimeError(r.stderr.strip())
        return json.loads(r.stdout or '{}')
    raw=subprocess.check_output(['docker','buildx','imagetools','inspect','--raw',a.source])
    if 'sha256:'+hashlib.sha256(raw).hexdigest()!=a.digest:
        raw=raw.rstrip(b'\n')
        if 'sha256:'+hashlib.sha256(raw).hexdigest()!=a.digest:raise RuntimeError('Vendor manifest checksum mismatch')
    manifest=json.loads(raw)
    if 'layers' not in manifest:p.error('Expected the ARM64 image manifest, not an image index')
    status=aws('ecr','batch-check-layer-availability','--repository-name',a.repository,'--layer-digests',*[x['digest'] for x in manifest['layers']])
    available={x['layerDigest'] for x in status.get('layers',[]) if x['layerAvailability']=='AVAILABLE'}
    missing=[x for x in manifest['layers'] if x['digest'] not in available]
    token=None;repository=a.source.split('@',1)[0]
    with tempfile.TemporaryDirectory(prefix='agw-ecr-manifest-') as folder:
        folder=pathlib.Path(folder)
        for layer in missing:
            if token is None:
                url='https://auth.docker.io/token?'+urllib.parse.urlencode({'service':'registry.docker.io','scope':'repository:'+repository+':pull'})
                with urllib.request.urlopen(url,timeout=60) as response:token=json.load(response)['token']
            request=urllib.request.Request('https://registry-1.docker.io/v2/'+repository+'/blobs/'+layer['digest'],headers={'Authorization':'Bearer '+token})
            blob=folder/'layer';checksum=hashlib.sha256()
            with urllib.request.urlopen(request,timeout=60) as response,blob.open('wb') as output:
                while True:
                    chunk=response.read(1024*1024)
                    if not chunk:break
                    output.write(chunk);checksum.update(chunk)
            if 'sha256:'+checksum.hexdigest()!=layer['digest']:raise RuntimeError('Layer checksum mismatch')
            upload=aws('ecr','initiate-layer-upload','--repository-name',a.repository)['uploadId'];offset=0
            with blob.open('rb') as data:
                while True:
                    chunk=data.read(10*1024*1024)
                    if not chunk:break
                    part=folder/'part';part.write_bytes(chunk)
                    aws('ecr','upload-layer-part','--repository-name',a.repository,'--upload-id',upload,'--part-first-byte',str(offset),'--part-last-byte',str(offset+len(chunk)-1),'--layer-part-blob','fileb://'+str(part));offset+=len(chunk)
            aws('ecr','complete-layer-upload','--repository-name',a.repository,'--upload-id',upload,'--layer-digests',layer['digest'])
            print('Preserved original vendor layer:',layer['digest'],flush=True)
        path=folder/'manifest.json';path.write_bytes(raw)
        aws('ecr','put-image','--repository-name',a.repository,'--image-manifest','file://'+str(path),'--image-manifest-media-type',manifest['mediaType'],'--image-tag','verified-'+a.digest.split(':')[1][:20])
    print('Verified vendor manifest preserved in ECR:',a.digest)
if __name__=='__main__':
    try:main()
    except (RuntimeError,ValueError,KeyError) as error:raise SystemExit(str(error))
