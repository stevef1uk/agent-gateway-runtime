"""Offline safety checks for customer-owned Emotion activation."""
import contextlib,importlib.util,io,json,pathlib,subprocess,sys,tempfile,unittest
from unittest.mock import patch
ROOT=pathlib.Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('activate',ROOT/'scripts/aws-emotion-activate.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
class Activation(unittest.TestCase):
 def test_updates_only_child_and_keeps_signing_values_out_of_template(self):
  with tempfile.TemporaryDirectory() as folder:
   folder=pathlib.Path(folder);key=folder/'customer.pem';token=folder/'emotion.token';key.write_text('private-fixture');token.write_text('token-fixture')
   template={'Resources':{'EmotionFunction':{'Properties':{'Environment':{'Variables':{'LICENCE_S3_BUCKET':'private-bucket','CUSTOMER_KEY_S3_OBJECT':'activation/customer.key','CUSTOMER_KEY_S3_VERSION':'old-key'}}}},'GatewayFunction':{'Properties':{'Environment':{'Variables':{'JWT_SECRET':{'Ref':'JWTSecretValue'}}}}}}}
   calls=[];captured={}
   def run(args,**kwargs):
    calls.append(args)
    if args[0]=='openssl':return subprocess.CompletedProcess(args,0,'','')
    if 'get-caller-identity' in args:data={'Account':'123456789012','Arn':'arn:aws:iam::123456789012:user/operator'}
    elif 'describe-stacks' in args:data={'Stacks':[{'StackId':'arn:aws:cloudformation:eu-west-3:123456789012:stack/agent-gateway-test-demo-mcp-emotion/id','Parameters':[{'ParameterKey':'JWTSecretValue','ParameterValue':'****'}]}]}
    elif 'get-template' in args:data={'TemplateBody':template}
    elif 'put-object' in args:data={'VersionId':'new-token' if args[args.index('--key')+1]=='activation/emotion.token' else 'new-emotion-key'}
    elif 'update-stack' in args:
     captured['template']=json.loads(pathlib.Path(args[args.index('--template-body')+1][7:]).read_text());captured['parameters']=json.loads(pathlib.Path(args[args.index('--parameters')+1][7:]).read_text());data={}
    elif 'describe-stack-resource' in args:data={'StackResourceDetail':{'PhysicalResourceId':'agent-gateway-test-demo-mcp-emotion-backend'}}
    elif 'invoke' in args:
     pathlib.Path(args[args.index('--output')-1]).write_text(json.dumps({'statusCode':204}));data={}
    else:data={}
    return subprocess.CompletedProcess(args,0,json.dumps(data),'')
   argv=['activate','--profile','operator','--region','eu-west-3','--stack','agent-gateway-test','--token',str(token),'--key',str(key)]
   with patch.object(sys,'argv',argv),patch.object(module.subprocess,'run',side_effect=run),contextlib.redirect_stdout(io.StringIO()):module.main()
   updates=[a for a in calls if 'update-stack' in a];self.assertEqual(len(updates),1);self.assertEqual(updates[0][updates[0].index('--stack-name')+1],'agent-gateway-test-demo-mcp-emotion')
   self.assertEqual(captured['parameters'],[{'ParameterKey':'JWTSecretValue','UsePreviousValue':True}])
   env=captured['template']['Resources']['EmotionFunction']['Properties']['Environment']['Variables'];self.assertEqual(env['CUSTOMER_KEY_S3_VERSION'],'new-emotion-key');self.assertEqual(env['EMOTION_LICENCE_VERSION'],'new-token')
   self.assertNotIn('private-fixture',json.dumps(captured));self.assertNotIn('token-fixture',json.dumps(captured))
 def test_missing_files_stop_before_cloud_calls(self):
  with patch.object(sys,'argv',['activate','--profile','p','--region','eu-west-3','--stack','s','--token','/missing/token','--key','/missing/key']),patch.object(module.subprocess,'run') as run,contextlib.redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):module.main()
  run.assert_not_called()
if __name__=='__main__':unittest.main()
