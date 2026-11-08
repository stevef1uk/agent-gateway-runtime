#!/usr/bin/env python3
"""Validate a published AWS release manifest without application source or AWS access."""
import argparse,json,pathlib,re
SERVICES=('authz','tokensvc','gateway','web')
def load_release(path):
    manifest=json.loads(pathlib.Path(path).read_text())
    if manifest.get('release_schema')!=2:raise ValueError('Obtain a current schema-2 AWS release manifest; historical four-image manifests do not support the full Wizard.')
    if manifest.get('platform')!='linux/arm64':raise ValueError('Release must target linux/arm64.')
    if not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}',manifest.get('version','')) or manifest['version'] in ['latest','local']:raise ValueError('Release needs an explicit version tag.')
    if not re.fullmatch(r'[0-9a-f]{40}',manifest.get('source_commit','')):raise ValueError('Missing vendor source provenance.')
    build=manifest.get('console_build','')
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+',build) or tuple(map(int,build.split('.')))<(1,0,94):raise ValueError('Release predates the full AWS Wizard.')
    images=manifest.get('images',{})
    if set(images)!=set(SERVICES):raise ValueError('Release needs all four encrypted product images.')
    for name in [*SERVICES,'emotion']:
        item=manifest.get('emotion') if name=='emotion' else images[name]
        if not isinstance(item,dict):raise ValueError('Release needs the prebuilt Emotion Lambda wrapper image.')
        repo='stevef1uk/agent-gateway-emotion-lambda' if name=='emotion' else f'stevef1uk/agent-gateway-{name}_l'
        digest=item.get('digest','')
        if not re.fullmatch(r'sha256:[0-9a-f]{64}',digest) or item.get('immutable_image')!=repo+'@'+digest:raise ValueError(f'Invalid immutable vendor image for {name}.')
    return manifest
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('manifest');a=p.parse_args()
    try:
        m=load_release(a.manifest);print('Valid AWS release:',m['version'],'(four encrypted product images + Emotion wrapper)')
    except (ValueError,KeyError,TypeError,OSError) as error:p.error(str(error))
