.PHONY: help demo check
help:
	@echo 'Read docs/Public-API-Curl-Tutorial.md before running the AWS weather probes.'
	@echo 'make demo: access probes (requires GATEWAY_URL and a test agent token)'
	@echo 'make aws-demo-url DEMO=users: read the deployed child GatewayURL from CloudFormation'
	@echo 'make check: syntax and offline fake-curl tests; no AWS calls'
demo:
	bash demo/public-weather-tutorial.sh access
check:
	bash -n demo/public-weather-tutorial.sh demo/run-aws-weather-demo.sh
	node --check scripts/playwright_weather_demo.js
	python3 -B scripts/test_weather_client.py
	python3 -B scripts/test_aws_demo.py

# Child demo GatewayURL and token are supplied by the operator; no AWS changes.
DEMO ?= weather
PHASE ?= access
AGW_SOURCE_DIR ?= ../agent-gateway
.PHONY: aws-demo aws-proxy-plan aws-proxy-create aws-proxy-connect aws-proxy-status aws-proxy-delete
aws-demo:
	python3 -B demo/aws-demo.py "$(DEMO)" "$(PHASE)"
aws-proxy-plan aws-proxy-create aws-proxy-connect aws-proxy-status aws-proxy-delete:
	$(MAKE) -C "$(AGW_SOURCE_DIR)" $@

AWS_PROFILE ?= agent-gateway-dev
AWS_REGION ?= eu-west-3
AWS_STACK ?= agent-gateway-dev
DEMO_KIND ?= $(if $(filter emotion,$(DEMO)),mcp,api)
.PHONY: aws-demo-url
aws-demo-url:
	@url="$$(aws cloudformation describe-stacks --profile "$(AWS_PROFILE)" --region "$(AWS_REGION)" --stack-name "$(AWS_STACK)-demo-$(DEMO_KIND)-$(DEMO)" --query 'Stacks[0].Outputs[?OutputKey==`GatewayURL`].OutputValue | [0]' --output text --no-cli-pager)" || exit; \
	case "$$url" in https://*.execute-api.*.amazonaws.com) printf '%s\n' "$$url" ;; *) echo 'No demo GatewayURL yet. Deploy this demo and wait for CREATE_COMPLETE or UPDATE_COMPLETE; see docs/AWS-Demos.md.' >&2; exit 1 ;; esac
