#!/usr/bin/env python3
"""Deploy the administrator access stack, synchronizing optional proxy scope from the app stack."""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLACEHOLDER_BUCKET = "agent-gateway-proxy-not-configured"
PLACEHOLDER_API_ID = "notconfigured"
BUCKET_PATTERN = re.compile(r"^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$")
AUTHZ_URL_PATTERN = re.compile(r"^https://([a-z0-9]+)\.execute-api\.[a-z0-9-]+\.amazonaws\.com$")
LICENCE_OBJECT_PATTERN = re.compile(r"^activation/[A-Za-z0-9/._-]+$")
AMI_PARAMETER_NAME = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
AMI_ID_PATTERN = re.compile(r"^ami-[0-9a-f]{8,17}$")


def aws(profile, region, *args):
    result = subprocess.run(
        ["aws", "--profile", profile, "--region", region, "--no-cli-pager", *args, "--output", "json"],
        text=True,
        capture_output=True,
    )
    if result.returncode:
        raise RuntimeError(result.stderr.strip())
    return json.loads(result.stdout or "{}")


def proxy_parameters(config, expected_account, application_stack):
    if config.get("account") != expected_account:
        raise RuntimeError("Parent application stack account does not match AWS_ACCOUNT.")
    if config.get("stack") != application_stack:
        raise RuntimeError("Parent DemoConfiguration stack does not match AWS_STACK.")

    bucket = config.get("bucket", "")
    if not BUCKET_PATTERN.fullmatch(bucket):
        raise RuntimeError(f"Parent DemoConfiguration has an invalid S3 bucket name: {bucket!r}.")

    authz_url = config.get("authz_url", "")
    match = AUTHZ_URL_PATTERN.fullmatch(authz_url)
    if not match:
        raise RuntimeError("Parent DemoConfiguration authz_url is not a valid regional API Gateway URL.")

    licence_object = config.get("gateway_licence_object", "")
    if not LICENCE_OBJECT_PATTERN.fullmatch(licence_object):
        raise RuntimeError("Parent DemoConfiguration gateway_licence_object is invalid.")

    return bucket, match.group(1), licence_object


def parent_proxy_parameters(profile, region, application_stack, expected_account):
    try:
        parent = aws(profile, region, "cloudformation", "describe-stacks", "--stack-name", application_stack)["Stacks"][0]
    except RuntimeError as error:
        message = str(error)
        if "does not exist" in message.lower():
            return PLACEHOLDER_BUCKET, PLACEHOLDER_API_ID, "activation/gateway.token"
        raise

    configs = [
        output["OutputValue"]
        for output in parent.get("Outputs", [])
        if output.get("OutputKey") == "DemoConfiguration"
    ]
    if len(configs) != 1:
        raise RuntimeError("Parent stack must have exactly one DemoConfiguration output before proxy permissions can be synchronized.")
    try:
        config = json.loads(configs[0])
    except json.JSONDecodeError as error:
        raise RuntimeError("Parent stack DemoConfiguration output is not valid JSON.") from error
    return proxy_parameters(config, expected_account, application_stack)


def proxy_ami_id(profile, region):
    parameter = aws(profile, region, "ssm", "get-parameter", "--name", AMI_PARAMETER_NAME)
    ami_id = parameter.get("Parameter", {}).get("Value", "")
    if not AMI_ID_PATTERN.fullmatch(ami_id):
        raise RuntimeError("The public Amazon Linux AMI parameter returned an invalid image ID.")
    return ami_id


def deploy(admin_profile, app_profile, region, account, access_stack, application_stack, artifact_stack, deployment_role, s3_bucket):
    identity = aws(admin_profile, region, "sts", "get-caller-identity")
    if identity.get("Account") != account:
        raise RuntimeError("Administrator profile/account mismatch.")
    ami_id = proxy_ami_id(admin_profile, region)
    bucket, api_id, licence_object = parent_proxy_parameters(app_profile, region, application_stack, account)
    template_bucket = s3_bucket or ("" if bucket == PLACEHOLDER_BUCKET else bucket)
    if not template_bucket:
        raise RuntimeError(
            "The access template exceeds CloudFormation's direct-upload limit and no application bucket exists yet. "
            "Set AWS_ACCESS_S3_BUCKET to an existing S3 bucket in this account where the administrator can upload."
        )
    if not BUCKET_PATTERN.fullmatch(template_bucket):
        raise RuntimeError(f"Invalid CloudFormation template staging bucket name: {template_bucket!r}.")
    command = [
        "aws", "--profile", admin_profile, "--region", region, "--no-cli-pager",
        "cloudformation", "deploy",
        "--stack-name", access_stack,
        "--template-file", str(ROOT / "deploy/aws/deployment-access.template.json"),
        "--capabilities", "CAPABILITY_NAMED_IAM",
        "--s3-bucket", template_bucket,
        "--parameter-overrides",
        f"ApplicationStack={application_stack}",
        f"ArtifactStack={artifact_stack}",
        f"DeploymentRole={deployment_role}",
        f"ProxyActivationBucket={bucket}",
        f"ProxyAuthzApiId={api_id}",
        f"ProxyGatewayLicenceObject={licence_object}",
        f"ProxyAmiId={ami_id}",
        "--no-fail-on-empty-changeset",
    ]
    subprocess.run(command, check=True)
    print(f"CloudFormation will stage the access template in S3 bucket {template_bucket}.")
    if bucket == PLACEHOLDER_BUCKET:
        print("Parent application stack not found; proxy permissions use nonfunctional placeholders.")
        print("After deploying the application, run this command again before creating the proxy VM.")
    else:
        print(f"Proxy access scope synchronized from {application_stack} (bucket {bucket}, API {api_id}, AMI {ami_id}).")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--admin-profile", required=True)
    parser.add_argument("--app-profile", required=True)
    parser.add_argument("--region", required=True)
    parser.add_argument("--account", required=True)
    parser.add_argument("--access-stack", required=True)
    parser.add_argument("--application-stack", required=True)
    parser.add_argument("--artifact-stack", required=True)
    parser.add_argument("--deployment-role", required=True)
    parser.add_argument("--s3-bucket", default="")
    args = parser.parse_args(argv)
    deploy(
        args.admin_profile,
        args.app_profile,
        args.region,
        args.account,
        args.access_stack,
        args.application_stack,
        args.artifact_stack,
        args.deployment_role,
        args.s3_bucket,
    )


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print("aws-access-deploy:", error, file=sys.stderr)
        sys.exit(1)
