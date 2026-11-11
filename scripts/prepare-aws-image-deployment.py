#!/usr/bin/env python3
"""Validate image-release identifiers and write CloudFormation parameters. No AWS calls."""
import argparse
import json
import pathlib
import re
import urllib.parse


def prepare(config):
    account = config['account']
    if not re.fullmatch(r'[0-9]{12}', account) or config['region'] != 'eu-west-3':
        raise ValueError('Use your 12-digit AWS account and region eu-west-3')
    activation = config['activation']
    bucket = activation['bucket']
    if not re.fullmatch(r'[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]', bucket):
        raise ValueError('Invalid private activation bucket name')
    def key(value):
        if not re.fullmatch(r'[A-Za-z0-9/_-]+[.A-Za-z0-9_-]*', value):
            raise ValueError('Use an exact activation object key without wildcard characters')
        return value
    def version(value):
        if not isinstance(value, str) or not value.strip() or value == 'null':
            raise ValueError('Explicit versioned S3 object VersionIds are required')
        return value
    boundary = config['workload_boundary_arn']
    if not re.fullmatch('arn:aws:iam::' + account + r':policy/[A-Za-z0-9+=,.@_/-]+', boundary):
        raise ValueError('Use the administrator-created workload boundary ARN in your account')
    if not activation['key_object'].startswith('activation/'):
        raise ValueError('Activation objects must be under activation/ for the workload boundary')
    parameters = {'WorkloadBoundaryArn': boundary, 'ActivationBucket': bucket, 'CustomerKeyObject': key(activation['key_object']),
                  'CustomerKeyVersion': version(activation['key_version'])}
    for service in ['authz', 'tokensvc', 'gateway', 'web']:
        release = config['services'][service]
        image = release['image_uri']
        if not re.fullmatch(account + r'\.dkr\.ecr\.eu-west-3\.amazonaws\.com/[a-z0-9][a-z0-9/._-]*@sha256:[0-9a-f]{64}', image):
            raise ValueError('Each service needs an immutable image digest in your Paris ECR account')
        name = service.capitalize()
        parameters[name + 'ImageUri'] = image
        if not release['licence_object'].startswith('activation/'):
            raise ValueError('Service licences must be under activation/')
        parameters[name + 'LicenceObject'] = key(release['licence_object'])
        parameters[name + 'LicenceVersion'] = version(release['licence_version'])
    deployment_role = config.get('demo_deployment_role_arn', '')
    if deployment_role and deployment_role != f"arn:aws:iam::{account}:role/{config.get('app_stack', 'agent-gateway-dev')}-demo-deployer":
        raise ValueError('Use the reviewed application demo CloudFormation role ARN')
    emotion_image = config.get('emotion_image_uri', '')
    if emotion_image and not re.fullmatch(account + r'\.dkr\.ecr\.eu-west-3\.amazonaws\.com/[a-z0-9][a-z0-9/._-]*@sha256:[0-9a-f]{64}', emotion_image):
        raise ValueError('Emotion needs an immutable Lambda wrapper image in your Paris ECR account')
    parameters.update(DemoDeploymentRoleArn=deployment_role, EmotionImageUri=emotion_image)
    domain, emails, upstream = config['domain_prefix'], config['admin_emails'], config['upstream_url']
    if not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', domain):
        raise ValueError('Invalid Cognito domain prefix')
    if not emails or any('@' not in email or ' ' in email for email in emails.split(',')):
        raise ValueError('Use comma-separated operator emails without spaces')
    url = urllib.parse.urlsplit(upstream)
    if url.scheme != 'https' or not url.hostname or url.username or url.password or url.fragment:
        raise ValueError('Use an HTTPS upstream without credentials or fragment')
    weather = config.get('weather_demo', False)
    if not isinstance(weather, bool) or (weather and upstream != 'https://api.open-meteo.com'):
        raise ValueError('Weather demo requires boolean true and exact https://api.open-meteo.com upstream')
    enable_rego = config.get('enable_rego_policy', True)
    if not isinstance(enable_rego, bool):
        raise ValueError('enable_rego_policy must be a boolean')
    parameters.update(DomainPrefix=domain, AdminEmails=emails, UpstreamURL=upstream,
                      EnableWeatherDemo=str(weather).lower(),
                      EnableRegoPolicy=str(enable_rego).lower())
    return [{'ParameterKey': key, 'ParameterValue': value} for key, value in parameters.items()]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('release_config', type=pathlib.Path)
    parser.add_argument('parameters_output', type=pathlib.Path)
    args = parser.parse_args()
    try:
        parameters = prepare(json.loads(args.release_config.read_text()))
    except (ValueError, KeyError, TypeError) as error:
        parser.error(str(error))
    args.parameters_output.write_text(json.dumps(parameters, indent=2) + '\n')
    print('Wrote image deployment parameters. No AWS calls or resources created.')


if __name__ == '__main__':
    main()
