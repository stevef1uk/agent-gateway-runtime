# Customer AWS deployment: prebuilt images only; no application source or Go needed.
-include aws-config.mk
AWS_PROFILE ?= agent-gateway-dev
AWS_REGION ?= eu-west-3
AWS_ACCOUNT ?=
AWS_STACK ?= agent-gateway-dev
AWS_ARTIFACT_STACK ?= agent-gateway-artifacts-dev
AWS_ACCESS_STACK ?= agent-gateway-access-dev
AWS_DEPLOYMENT_ROLE_NAME ?= AgentGatewayDev
AWS_ADMIN_PROFILE ?=
AWS_VM_PROFILE ?=
RELEASE_MANIFEST ?= releases/current.json
CUSTOMER_KEY_FILE ?= keys/local-activation/customer_private.pem
LICENCE_DIR ?= keys/local-activation/licences
DOMAIN_PREFIX ?=
ADMIN_EMAILS ?=
WORKLOAD_BOUNDARY_ARN ?=
DEMO_DEPLOYMENT_ROLE_ARN ?= arn:aws:iam::$(AWS_ACCOUNT):role/$(AWS_STACK)-demo-deployer
DEMO ?= users
DEMO_KIND ?= $(if $(filter emotion,$(DEMO)),mcp,api)
PHASE ?= access
CONFIRM_ACCOUNT ?=
PROXY_INSTANCE_TYPE ?= t4g.small
PROXY_LOCAL_PORT ?= 8088
PROXY_CONFIG ?= deploy/aws/demo-config.example.json
CFN_LINT_BIN ?= cfn-lint
.PHONY: help check demo aws-identity aws-release-check aws-preflight aws-access-deploy aws-access-outputs aws-deploy aws-outputs aws-demo aws-demo-url aws-demo-list aws-demo-delete aws-demo-delete-all aws-emotion-token-upload aws-emotion-activate aws-proxy-plan aws-proxy-create aws-proxy-connect aws-proxy-status aws-proxy-delete aws-cleanup aws-ecr-cleanup aws-access-delete aws-validate
help:
	@echo 'Start with docs/Deployment-Guide.md (customer deployment and testing).'
	@echo 'make check: offline checks; creates no AWS resources'
	@echo 'make aws-preflight: validate your local config, release and activation files'
	@echo 'make aws-access-deploy: administrator setup; explicit AWS_ADMIN_PROFILE required'
	@echo 'make aws-deploy: deploy prebuilt Docker Hub images into your account'
	@echo 'make aws-outputs: print your actual console and baseline gateway URLs'
	@echo 'make aws-demo-url DEMO=users: print the selected child gateway URL'
	@echo 'make aws-demo DEMO=users: run a client using GATEWAY_URL; prompt for agent token'
	@echo 'make aws-cleanup CONFIRM_ACCOUNT=...: owned demos then parent; retains data'
check:
	bash -n demo/public-weather-tutorial.sh demo/run-aws-weather-demo.sh scripts/deploy-aws.sh scripts/aws-licence-upload.sh scripts/cleanup-aws-demo-images.sh
	node --check scripts/playwright_weather_demo.js
	python3 -B scripts/test_weather_client.py
	python3 -B scripts/test_aws_demo.py
	python3 -B scripts/test_prepare_aws_images.py
	python3 -B scripts/test_teardown_aws.py
	python3 -B scripts/test_aws_customer.py
	python3 -B scripts/test_emotion_activation.py
	python3 -B scripts/test_aws_proxy_vm.py

demo:
	bash demo/public-weather-tutorial.sh access
aws-identity:
	aws sts get-caller-identity --profile "$(AWS_PROFILE)" --region "$(AWS_REGION)"
aws-release-check:
	python3 -B scripts/aws-release.py "$(RELEASE_MANIFEST)"
aws-preflight: aws-release-check
	@test -n "$(AWS_ACCOUNT)" -a -n "$(DOMAIN_PREFIX)" -a -n "$(ADMIN_EMAILS)" || { echo 'Fill AWS_ACCOUNT, DOMAIN_PREFIX and ADMIN_EMAILS in aws-config.mk; see docs/Deployment-Guide.md.' >&2; exit 2; }
	@test -s "$(CUSTOMER_KEY_FILE)" || { echo 'Missing customer activation key; check CUSTOMER_KEY_FILE.' >&2; exit 2; }
	@for service in authz tokensvc gateway web; do test -s "$(LICENCE_DIR)/$$service.token" || { echo "Missing $$service.token in LICENCE_DIR." >&2; exit 2; }; done
	python3 -B scripts/check-aws-activation.py --key "$(CUSTOMER_KEY_FILE)" --licences "$(LICENCE_DIR)"
	@echo 'Local release/config/file checks passed. No AWS resources created; licence validity is checked by the containers at startup.'
aws-access-deploy:
	@test -n "$(AWS_ADMIN_PROFILE)" -a -n "$(AWS_ACCOUNT)" || { echo 'Set AWS_ADMIN_PROFILE and AWS_ACCOUNT explicitly in aws-config.mk.' >&2; exit 2; }
	@test "$$(aws sts get-caller-identity --profile "$(AWS_ADMIN_PROFILE)" --query Account --output text)" = "$(AWS_ACCOUNT)" || { echo 'Administrator profile/account mismatch.' >&2; exit 2; }
	aws cloudformation deploy --profile "$(AWS_ADMIN_PROFILE)" --region "$(AWS_REGION)" --stack-name "$(AWS_ACCESS_STACK)" --template-file deploy/aws/deployment-access.template.json --capabilities CAPABILITY_NAMED_IAM --parameter-overrides ApplicationStack="$(AWS_STACK)" ArtifactStack="$(AWS_ARTIFACT_STACK)" DeploymentRole="$(AWS_DEPLOYMENT_ROLE_NAME)" --no-fail-on-empty-changeset
aws-access-outputs:
	@test -n "$(AWS_ADMIN_PROFILE)" || { echo 'Set AWS_ADMIN_PROFILE for access-stack inspection.' >&2; exit 2; }
	aws cloudformation describe-stacks --profile "$(AWS_ADMIN_PROFILE)" --region "$(AWS_REGION)" --stack-name "$(AWS_ACCESS_STACK)" --query 'Stacks[0].Outputs' --output table --no-cli-pager
aws-deploy: aws-preflight
	AWS_PROFILE="$(AWS_PROFILE)" AWS_REGION="$(AWS_REGION)" AGW_ACCOUNT="$(AWS_ACCOUNT)" AGW_ACCESS_STACK="$(AWS_ACCESS_STACK)" AGW_ACCESS_PROFILE="$(AWS_ADMIN_PROFILE)" AGW_ARTIFACT_STACK="$(AWS_ARTIFACT_STACK)" AGW_APP_STACK="$(AWS_STACK)" AGW_CUSTOMER_KEY_FILE="$(CUSTOMER_KEY_FILE)" AGW_LICENCE_DIR="$(LICENCE_DIR)" AGW_DEMO_DEPLOYMENT_ROLE_ARN="$(DEMO_DEPLOYMENT_ROLE_ARN)" AGW_WORKLOAD_BOUNDARY_ARN="$(WORKLOAD_BOUNDARY_ARN)" bash scripts/deploy-aws.sh --release-manifest "$(RELEASE_MANIFEST)" --domain-prefix "$(DOMAIN_PREFIX)" --admin-emails "$(ADMIN_EMAILS)"
aws-outputs:
	@python3 -B scripts/aws-outputs.py --profile "$(AWS_PROFILE)" --region "$(AWS_REGION)" --stack "$(AWS_STACK)"
aws-demo:
	python3 -B demo/aws-demo.py "$(DEMO)" "$(PHASE)"
aws-demo-url:
	@url="$$(aws cloudformation describe-stacks --profile "$(AWS_PROFILE)" --region "$(AWS_REGION)" --stack-name "$(AWS_STACK)-demo-$(DEMO_KIND)-$(DEMO)" --query 'Stacks[0].Outputs[?OutputKey==`GatewayURL`].OutputValue | [0]' --output text --no-cli-pager)" || exit; \
	case "$$url" in https://*.execute-api.*.amazonaws.com) printf '%s\n' "$$url" ;; *) echo 'No demo GatewayURL yet. Deploy the demo in the AI Wizard and wait for success; see docs/AWS-Demos.md.' >&2; exit 1 ;; esac
aws-demo-list:
	python3 -B scripts/aws-demo-stacks.py list --profile "$(AWS_PROFILE)" --region "$(AWS_REGION)" --stack "$(AWS_STACK)"
aws-demo-delete:
	python3 -B scripts/aws-demo-stacks.py delete --profile "$(AWS_PROFILE)" --region "$(AWS_REGION)" --stack "$(AWS_STACK)" --name "$(DEMO)" --kind "$(DEMO_KIND)" --confirm-account "$(CONFIRM_ACCOUNT)"
aws-demo-delete-all:
	python3 -B scripts/aws-demo-stacks.py delete-all --profile "$(AWS_PROFILE)" --region "$(AWS_REGION)" --stack "$(AWS_STACK)" --confirm-account "$(CONFIRM_ACCOUNT)"
aws-emotion-activate:
	@test -n "$(EMOTION_TOKEN_FILE)" -a -n "$(EMOTION_KEY_FILE)" || { echo 'Set EMOTION_TOKEN_FILE and EMOTION_KEY_FILE to your vendor-issued files.' >&2; exit 2; }
	python3 -B scripts/aws-emotion-activate.py --profile "$(AWS_PROFILE)" --region "$(AWS_REGION)" --stack "$(AWS_STACK)" --token "$(EMOTION_TOKEN_FILE)" --key "$(EMOTION_KEY_FILE)"
aws-emotion-token-upload:
	AWS_PROFILE="$(AWS_PROFILE)" AWS_REGION="$(AWS_REGION)" AWS_STACK="$(AWS_STACK)" TOKEN_FILE="$(TOKEN_FILE)" bash scripts/aws-licence-upload.sh
aws-proxy-plan:
	python3 -B scripts/aws-proxy-vm.py plan --config "$(PROXY_CONFIG)" --instance-type "$(PROXY_INSTANCE_TYPE)"
aws-proxy-create:
	python3 -B scripts/aws-proxy-vm.py create --profile "$(AWS_PROFILE)" --vm-profile "$(AWS_VM_PROFILE)" --region "$(AWS_REGION)" --stack "$(AWS_STACK)" --instance-type "$(PROXY_INSTANCE_TYPE)"
aws-proxy-status:
	python3 -B scripts/aws-proxy-vm.py status --vm-profile "$(AWS_VM_PROFILE)" --region "$(AWS_REGION)" --stack "$(AWS_STACK)"
aws-proxy-connect:
	python3 -B scripts/aws-proxy-vm.py connect --vm-profile "$(AWS_VM_PROFILE)" --region "$(AWS_REGION)" --stack "$(AWS_STACK)" --local-port "$(PROXY_LOCAL_PORT)"
aws-proxy-delete:
	python3 -B scripts/aws-proxy-vm.py delete --vm-profile "$(AWS_VM_PROFILE)" --region "$(AWS_REGION)" --stack "$(AWS_STACK)"
aws-cleanup:
	@test -n "$(CONFIRM_ACCOUNT)" || { echo 'Set CONFIRM_ACCOUNT to the intended AWS account.' >&2; exit 2; }
	$(MAKE) aws-demo-delete-all
	python3 -B scripts/teardown-aws-deployment.py --profile "$(AWS_PROFILE)" --region "$(AWS_REGION)" --app-stack "$(AWS_STACK)" --artifact-stack "$(AWS_ARTIFACT_STACK)" --account "$(CONFIRM_ACCOUNT)" --execute --confirm-account "$(CONFIRM_ACCOUNT)" $(if $(filter 1,$(PURGE_DATA)),--purge-data,)
aws-ecr-cleanup:
	AWS_PROFILE="$(AWS_PROFILE)" AWS_REGION="$(AWS_REGION)" AWS_STACK="$(AWS_STACK)" CONFIRM_ACCOUNT="$(CONFIRM_ACCOUNT)" bash scripts/cleanup-aws-demo-images.sh
aws-access-delete:
	@test -n "$(AWS_ADMIN_PROFILE)" -a -n "$(CONFIRM_ACCOUNT)" || { echo 'Set AWS_ADMIN_PROFILE and CONFIRM_ACCOUNT explicitly.' >&2; exit 2; }
	@test "$$(aws sts get-caller-identity --profile "$(AWS_ADMIN_PROFILE)" --query Account --output text)" = "$(CONFIRM_ACCOUNT)"
	aws cloudformation delete-stack --profile "$(AWS_ADMIN_PROFILE)" --region "$(AWS_REGION)" --stack-name "$(AWS_ACCESS_STACK)"
	aws cloudformation wait stack-delete-complete --profile "$(AWS_ADMIN_PROFILE)" --region "$(AWS_REGION)" --stack-name "$(AWS_ACCESS_STACK)"
aws-validate:
	$(CFN_LINT_BIN) --regions "$(AWS_REGION)" --template deploy/aws/*.template.json
