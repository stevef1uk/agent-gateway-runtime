#!/usr/bin/env python3
"""Estimate Azure Container Apps Consumption and optional PostgreSQL costs."""

from __future__ import annotations

import argparse
import json
from decimal import Decimal
from pathlib import Path
from typing import Any


INPUTS = (
    Path(__file__).resolve().parents[1]
    / "docs"
    / "azure"
    / "serverless-pricing-inputs.json"
)


def load_inputs() -> dict[str, Any]:
    with INPUTS.open(encoding="utf-8") as file:
        return json.load(file)


def money(value: Decimal) -> str:
    return f"${value.quantize(Decimal('0.01')):,.2f}"


def estimate(
    inputs: dict[str, Any],
    actions: int,
    seconds_per_hop: Decimal,
    database: str,
) -> tuple[Decimal, Decimal, Decimal]:
    rates = inputs["rates"]
    allowances = inputs["allowances"]
    workload = inputs["workload"]
    month_seconds = Decimal(inputs["month_hours"]) * 60 * 60
    cpu = Decimal(workload["replica_vcpu"])
    gib = Decimal(workload["replica_gib"])

    idle_baseline = Decimal(workload["web_min_replicas"]) * month_seconds * (
        cpu * Decimal(rates["container_apps_vcpu_idle_per_second"])
        + gib * Decimal(rates["container_apps_gib_idle_per_second"])
    )

    hops = Decimal(actions) * Decimal(workload["hops_per_action"])
    cpu_seconds = hops * seconds_per_hop * cpu
    gib_seconds = hops * seconds_per_hop * gib
    active_compute = (
        cpu_seconds * Decimal(rates["container_apps_vcpu_active_per_second"])
        + gib_seconds * Decimal(rates["container_apps_gib_active_per_second"])
    )
    request_units = max(
        Decimal(0),
        hops - Decimal(allowances["container_apps_requests"]),
    )
    request_cost = (
        request_units
        * Decimal(rates["container_apps_request_per_million"])
        / Decimal(1_000_000)
    )
    gross = idle_baseline + active_compute + request_cost

    granted_cpu_seconds = max(
        Decimal(0),
        cpu_seconds - Decimal(allowances["container_apps_vcpu_seconds"]),
    )
    granted_gib_seconds = max(
        Decimal(0),
        gib_seconds - Decimal(allowances["container_apps_gib_seconds"]),
    )
    net_active_compute = (
        granted_cpu_seconds
        * Decimal(rates["container_apps_vcpu_active_per_second"])
        + granted_gib_seconds
        * Decimal(rates["container_apps_gib_active_per_second"])
    )
    net = idle_baseline + net_active_compute + request_cost

    if database == "b1ms":
        db_compute = (
            Decimal(inputs["month_hours"])
            * Decimal(rates["postgres_b1ms_per_hour"])
        )
    elif database == "general-purpose":
        db_vcores = Decimal(inputs["postgres"]["general_purpose_vcores"])
        db_compute = (
            Decimal(inputs["month_hours"])
            * db_vcores
            * Decimal(rates["postgres_general_purpose_vcore_per_hour"])
        )
    else:
        db_compute = Decimal(0)

    db_storage = (
        Decimal(inputs["postgres"]["storage_gb"])
        * Decimal(rates["postgres_storage_per_gb_month"])
        if database != "none"
        else Decimal(0)
    )
    db_cost = db_compute + db_storage
    return gross, net, db_cost


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--seconds-per-hop",
        type=Decimal,
        default=Decimal("1"),
        help="Average billed seconds for each service hop (default: 1)",
    )
    parser.add_argument(
        "--database",
        choices=("none", "b1ms", "general-purpose"),
        default="none",
        help="Add an always-on PostgreSQL cost (default: none)",
    )
    args = parser.parse_args()
    if args.seconds_per_hop <= 0:
        parser.error("--seconds-per-hop must be greater than zero")

    inputs = load_inputs()
    print(
        f"Azure Container Apps Consumption — {inputs['region']}, "
        f"{inputs['currency']}/month, {inputs['month_hours']} hours"
    )
    print(
        "Scenario".ljust(17)
        + "Actions".rjust(12)
        + "Gross".rjust(13)
        + "After grants".rjust(16)
        + ("Gross + DB".rjust(17) if args.database != "none" else "")
    )
    names = ("Idle", "Light", "Regular", "Busy")
    for name, actions in zip(
        names, inputs["workload"]["actions_per_month"], strict=True
    ):
        gross, net, database_cost = estimate(
            inputs, actions, args.seconds_per_hop, args.database
        )
        row = (
            name.ljust(17)
            + f"{actions:,}".rjust(12)
            + money(gross).rjust(13)
            + money(net).rjust(16)
        )
        if args.database != "none":
            row += money(gross + database_cost).rjust(17)
        print(row)

    if args.database != "none":
        print(f"PostgreSQL add-on: {money(database_cost)} / month")
    print("Excludes logs, egress, network/edge services, HA, tax, and software.")


if __name__ == "__main__":
    main()
