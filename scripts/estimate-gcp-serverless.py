#!/usr/bin/env python3
"""Reproduce the Paris (europe-west9) GCP Cloud Run + Firestore model offline; never calls GCP."""
import argparse
import json
from decimal import Decimal
from pathlib import Path


def billable(amount: Decimal, allowance: Decimal, apply_free: bool) -> Decimal:
    if not apply_free:
        return amount
    return max(Decimal("0"), amount - allowance)


def estimate(rates, usage, apply_free=False):
    d = lambda key: Decimal(str(usage[key]))
    r = lambda key: Decimal(rates[key]["usd"])
    f = lambda key: Decimal(rates[key]["free_tier_monthly"]) if rates[key].get("free_tier_monthly", "0") != "Inf" else Decimal("Infinity")

    calls = d("external_actions") * d("hops_per_action")
    concurrency = d("effective_concurrency")
    instance_seconds = calls * d("average_billed_seconds") / concurrency
    vcpu_seconds = instance_seconds * d("vcpu")
    gib_seconds = instance_seconds * d("memory_gib")
    reads = d("external_actions") * d("read_ops_per_action")
    writes = d("external_actions") * d("write_ops_per_action")

    return {
        "Cloud Run CPU + Memory": (
            billable(vcpu_seconds, f("cloud_run_vcpu_second"), apply_free) * r("cloud_run_vcpu_second")
            + billable(gib_seconds, f("cloud_run_gib_second"), apply_free) * r("cloud_run_gib_second")
        ),
        "Cloud Run requests (incl. internal hops)": billable(calls, f("cloud_run_request"), apply_free) * r("cloud_run_request"),
        "API Gateway (built-in Cloud Run HTTPS/IAM)": Decimal("0"),
        "Firestore reads & writes": (
            billable(reads, f("firestore_read"), apply_free) * r("firestore_read")
            + billable(writes, f("firestore_write"), apply_free) * r("firestore_write")
        ),
        "Firestore storage": billable(d("firestore_gib_month"), f("firestore_gib_month"), apply_free) * r("firestore_gib_month"),
        "Firestore PITR": billable(d("pitr_gib_month"), f("firestore_pitr_gib_month"), apply_free) * r("firestore_pitr_gib_month"),
        "Cloud Logging": billable(d("logs_ingest_gib"), f("logs_ingest_gib"), apply_free) * r("logs_ingest_gib"),
        "Secret Manager": (
            billable(d("secrets"), f("secret_version_month"), apply_free) * r("secret_version_month")
            + billable(d("secret_requests"), f("secret_access"), apply_free) * r("secret_access")
        ),
        "Cloud Storage (artifacts)": (
            d("gcs_gib_month") * r("gcs_gib_month")
            + d("gcs_puts") * r("gcs_class_a")
            + d("gcs_gets") * r("gcs_class_b")
        ),
        "Google OIDC provider (charges not modelled)": d("identity_mau") * r("identity_platform_mau"),
        "Internet data transfer (Standard Tier)": d("internet_egress_gib") * r("internet_egress_gib"),
    }


def image_costs(rates, usage, ar_gb, cold_fraction, activation_seconds, apply_free=False):
    d = lambda key: Decimal(str(usage[key]))
    r = lambda key: Decimal(rates[key]["usd"])
    f = lambda key: Decimal(rates[key]["free_tier_monthly"])
    calls = d("external_actions") * d("hops_per_action")
    cold_starts = calls * cold_fraction
    add_vcpu_s = cold_starts * activation_seconds * d("vcpu")
    add_gib_s = cold_starts * activation_seconds * d("memory_gib")
    return {
        "Artifact Registry storage": billable(ar_gb, f("artifact_registry_gib_month"), apply_free) * r("artifact_registry_gib_month"),
        "Activation GCS GETs": cold_starts * r("gcs_class_b"),
        "Additional activation duration": add_vcpu_s * r("cloud_run_vcpu_second") + add_gib_s * r("cloud_run_gib_second"),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inputs", type=Path, default=Path(__file__).resolve().parents[1] / "docs/gcp/serverless-pricing-inputs.json")
    parser.add_argument("--average-seconds", type=Decimal, help="Override average billed duration per service invocation")
    parser.add_argument("--hops", type=Decimal, help="Override billed Cloud Run hops per external action (default 1.5 for consolidated 2-service; 4 for unmerged)")
    parser.add_argument("--concurrency", type=Decimal, help="Override effective concurrent requests per active instance (e.g. 1.0 for zero overlap)")
    parser.add_argument("--vcpu", type=Decimal, help="Override vCPU allocation per Cloud Run instance (default 1.0)")
    parser.add_argument("--images", action="store_true", help="Include Artifact Registry and signed-licence cold activation costs")
    parser.add_argument("--ar-gb", type=Decimal, default=Decimal("1"), help="Retained Artifact Registry storage, default 1 GB-month for 2 consolidated images")
    parser.add_argument("--cold-fraction", type=Decimal, default=Decimal("0.05"), help="Assumed fraction of invocations needing cold activation (5%% with concurrency=80)")
    parser.add_argument("--activation-seconds", type=Decimal, default=Decimal("2"), help="Conservative additional GCS/licence-verification time per cold start; no image decryption")
    parser.add_argument("--apply-free-tier", action="store_true", help="Deduct standard GCP monthly project free-tier allowances")
    args = parser.parse_args()

    data = json.loads(args.inputs.read_text())
    mode = "with GCP monthly free tier applied" if args.apply_free_tier else "gross rates (no free allowances/credits applied)"
    print(f"{data['region']} | {data['currency']} per month | {data['date']} | {mode}")
    if args.images:
        print(f"Image additions: {args.ar_gb} GB-month Artifact Registry, cold fraction {args.cold_fraction}, {args.activation_seconds}s additional activation")
    for scenario in data["scenarios"]:
        if args.average_seconds is not None:
            scenario["average_billed_seconds"] = args.average_seconds
        if args.hops is not None:
            scenario["hops_per_action"] = args.hops
        if args.concurrency is not None:
            scenario["effective_concurrency"] = args.concurrency
        if args.vcpu is not None:
            scenario["vcpu"] = args.vcpu
        costs = estimate(data["rates"], scenario, apply_free=args.apply_free_tier)
        if args.images:
            costs.update(image_costs(data["rates"], scenario, args.ar_gb, args.cold_fraction, args.activation_seconds, apply_free=args.apply_free_tier))
        print(
            f"\n{scenario['name']}: {scenario['external_actions']:,} external actions; "
            f"{scenario['hops_per_action']} hops/action; {scenario['average_billed_seconds']}s mean; "
            f"{scenario['vcpu']} vCPU (eff. concurrency {scenario['effective_concurrency']}x)"
        )
        for name, amount in costs.items():
            print(f"  {name}: ${amount:.4f}")
        print(f"  TOTAL: ${sum(costs.values(), Decimal(0)):.2f}")


if __name__ == "__main__":
    main()
