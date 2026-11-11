.PHONY: help check gcp-pricing

help:
	@echo 'GCP deployment and Console walkthrough: see docs/GCP-Deployment-Guide.md.'
	@echo 'make check: run local GCP script and pricing checks; creates no cloud resources'
	@echo 'make gcp-pricing: show the GCP serverless pricing estimate'

check:
	bash -n scripts/deploy-gcp.sh demo/public-weather-tutorial-gcp.sh
	python3 -B scripts/estimate-gcp-serverless.py >/dev/null

gcp-pricing:
	python3 -B scripts/estimate-gcp-serverless.py
