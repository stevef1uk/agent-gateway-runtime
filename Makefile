.PHONY: help demo check
help:
	@echo 'Read docs/Public-API-Curl-Tutorial.md before running the AWS weather probes.'
	@echo 'make demo: access probes (requires GATEWAY_URL and a test agent token)'
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
