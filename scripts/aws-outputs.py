#!/usr/bin/env python3
"""Show the deployed endpoints without the internal deployment configuration."""
import argparse
import json
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('profile', 'region', 'stack'):
        parser.add_argument('--' + name, required=True)
    args = parser.parse_args()
    result = subprocess.run([
        'aws', 'cloudformation', 'describe-stacks', '--profile', args.profile,
        '--region', args.region, '--stack-name', args.stack,
        '--output', 'json', '--no-cli-pager',
    ], capture_output=True, text=True)
    if result.returncode:
        print(result.stderr.strip(), file=sys.stderr)
        if 'does not exist' in result.stderr:
            print("Run 'make aws-deploy' to create this stack.", file=sys.stderr)
        return result.returncode
    stack = json.loads(result.stdout)['Stacks'][0]
    outputs = {item['OutputKey']: item['OutputValue'] for item in stack.get('Outputs', [])}
    print(f"Stack:           {stack['StackName']} ({stack['StackStatus']})")
    for key, label in [('ConsoleURL', 'Console'), ('GatewayURL', 'Baseline gateway')]:
        if outputs.get(key):
            print(f"{label + ':':16} {outputs[key]}")
    if not outputs.get('ConsoleURL'):
        print('No console URL yet; deployment must complete first.')
        return 1
    print(f"{'Sign in:':16} {outputs['ConsoleURL'].rstrip('/')}/oidc/login?prompt=login")
    print('\nOpen Sign in and use your invitation temporary password for first setup.')
    print("For a wizard-created demo URL: make -s aws-demo-url DEMO=users")
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
