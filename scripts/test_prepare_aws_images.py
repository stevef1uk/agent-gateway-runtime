#!/usr/bin/env python3
"""Offline image deployment parameter/template contract regressions."""
import importlib.util
import json
from pathlib import Path
import sys
import unittest
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('image_parameters', ROOT/'scripts/prepare-aws-image-deployment.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
class ImageParameters(unittest.TestCase):
    def config(self):
        return dict(account='123456789012',region='eu-west-3',workload_boundary_arn='arn:aws:iam::123456789012:policy/workload-boundary',activation=dict(bucket='example-activation-bucket',key_object='activation/customer.key',key_version='key-v1'),domain_prefix='example-weather',admin_emails='operator@example.test',upstream_url='https://api.open-meteo.com',weather_demo=True,services={service:dict(image_uri=f'123456789012.dkr.ecr.eu-west-3.amazonaws.com/example/{service}@sha256:'+'a'*64,licence_object=f'activation/{service}.token',licence_version='licence-v1') for service in ['authz','tokensvc','gateway','web']})
    def test_four_service_release_matches_image_template(self):
        template=json.loads((ROOT/'deploy/aws/serverless-images.template.json').read_text())
        params={p['ParameterKey']:p['ParameterValue'] for p in module.prepare(self.config())}
        self.assertEqual(set(params),set(template['Parameters']))
        self.assertEqual(params['EnableWeatherDemo'],'true')
        self.assertEqual(params['EmotionImageUri'], '')
        self.assertEqual(params['DemoDeploymentRoleArn'], '')
        self.assertFalse(any('EmotionLicence' in name for name in params))
    def test_mutable_images_or_unversioned_activation_are_rejected(self):
        for mutation in ['image','version','boundary']:
            config=self.config()
            if mutation=='image':config['services']['web']['image_uri']='example/web:latest'
            elif mutation=='version':config['activation']['key_version']='null'
            else:config['workload_boundary_arn']='arn:aws:iam::999999999999:policy/other-account'
            with self.assertRaises(ValueError):module.prepare(config)
    def test_inference_permission_is_limited_to_web_and_boundary(self):
        for filename in ['serverless-images.template.json']:
            template=json.loads((ROOT/'deploy/aws'/filename).read_text())
            for name,resource in template['Resources'].items():
                if resource['Type']!='AWS::IAM::Role':continue
                actions=[a for policy in resource['Properties'].get('Policies',[]) for statement in policy['PolicyDocument']['Statement'] for a in statement.get('Action',[])]
                self.assertEqual('bedrock:InvokeModel' in actions,name=='WebRole')
            env=template['Resources']['WebFunction']['Properties']['Environment']['Variables']
            self.assertEqual(env['BEDROCK_MODEL_ID'],'eu.amazon.nova-micro-v1:0')
            self.assertEqual(env['WEATHER_DEMO_ENABLED'],{'Ref':'EnableWeatherDemo'})
if __name__=='__main__':unittest.main()
