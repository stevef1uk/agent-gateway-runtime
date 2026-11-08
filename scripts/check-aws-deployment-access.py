#!/usr/bin/env python3
"""Read-only access checks before any deployment writes."""
import argparse, json, subprocess
from pathlib import Path

def main():
    p=argparse.ArgumentParser(description=__doc__)
    for key in ['profile','region','stack','boundary']:
        p.add_argument('--'+key,required=True)
    a=p.parse_args()
    def check(service,operation,*args,missing_ok=False):
        r=subprocess.run(['aws','--profile',a.profile,'--region',a.region,service,operation,*args,'--output','json'],capture_output=True,text=True)
        if r.returncode:
            error=r.stderr.strip()
            if missing_ok and any(term in error for term in ['ResourceNotFoundException','does not exist']):
                return {}
            template=Path(__file__).resolve().parents[1]/'deploy/aws/deployment-access.template.json'
            raise SystemExit(f"Deployment access check failed: {service}:{operation}\n{error}\n\nAdministrator: create/update the access stack with {template}, target the deployment ROLE, execute its change set, and wait for completion. Then rerun make aws-deploy. No deployment writes have started.")
        return json.loads(r.stdout or '{}')
    policy=check('iam','get-policy','--policy-arn',a.boundary)
    check('iam','get-policy-version','--policy-arn',a.boundary,'--version-id',policy['Policy']['DefaultVersionId'])
    account=a.boundary.split(':')[4]
    check('logs','describe-index-policies','--log-group-identifiers',f'arn:aws:logs:{a.region}:{account}:log-group:/aws/lambda/{a.stack}-web',missing_ok=True)
    check('cloudformation','describe-events','--stack-name',a.stack,'--filters','FailedEvents=true',missing_ok=True)
    print('Deployment access checks passed (read-only).')

if __name__=='__main__':
    main()
