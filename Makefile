.PHONY: help demo check
help:
	@echo 'Read docs/Public-API-Curl-Tutorial.md before running the AWS weather probes.'
	@echo 'make demo: access probes (requires GATEWAY_URL and a test agent token)'
	@echo 'make check: syntax and offline fake-curl tests; no AWS calls'
demo:
	bash demo/public-weather-tutorial.sh access
check:
	bash -n demo/public-weather-tutorial.sh
	python3 -B scripts/test_weather_client.py
