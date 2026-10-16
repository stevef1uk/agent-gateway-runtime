package authz_test

import rego.v1

# Rego tests for the default authorizer shipped in this repository.
# Run with OPA 1.x:
#   opa test demo/policies/
# Input shape mirrors the decision contract in docs/Policy-and-OPA.md.

live_delegation := {
	"id": "del-1", "user_id": "alice", "agent_id": "purchasing-agent-42",
	"resources": ["/orders", "/suppliers/*"], "actions": ["read", "create"],
	"expires_at": "2030-01-01T00:00:00Z",
	"limits": {"spend_per_order": {"type": "currency", "max": 200, "unit": "EUR"},
	           "max_count": {"type": "count", "max": 5}},
	"approval_rules": {},
}

approve_rule := {
	"when_resource_pattern": "/orders", "when_action_pattern": "create",
	"when_extra": {"supplier": "untrusted"}, "require": true,
	"rationale": "untrusted supplier needs human",
}

act(resource, action, ctx) := {
	"agent_id": "purchasing-agent-42", "user_id": "alice",
	"resource": resource, "action": action, "tenant": "", "context": ctx,
}

base := {
	"now": "2026-10-16T12:00:00Z",
	"delegation": live_delegation,
	"action": act("/orders", "create", {"amount": 150}),
	"limits": live_delegation.limits,
	"approval_rules": live_delegation.approval_rules,
}

test_allow_under_cap if {
	d := data.authz.decision with input as base
	d.allow == true
	d.require_approval == false
}

test_spend_cap_downgrades_to_approval if {
	d := data.authz.decision with input as object.union(base, {"action": act("/orders", "create", {"amount": 250})})
	d.allow == true
	d.require_approval == true
	startswith(d.reason, "amount 250 exceeds")
}

test_deny_other_resource if {
	d := data.authz.decision with input as object.union(base, {"action": act("/payments", "create", {})})
	d.allow == false
	contains(d.reason, "resource not allowed")
}

test_deny_wrong_agent if {
	d := data.authz.decision with input as object.union(base, {"action": object.union(act("/orders", "create", {"amount": 150}), {"agent_id": "rogue-agent"})})
	d.allow == false
	contains(d.reason, "does not match delegation agent")
}

test_max_count_denies if {
	d := data.authz.decision with input as object.union(base, {"action": act("/orders", "create", {"amount": 10, "count": 12})})
	d.allow == false
	contains(d.reason, "exceeds limit")
}

test_approval_rule_requires if {
	d := data.authz.decision with input as object.union(base, {
		"delegation": object.union(live_delegation, {"approval_rules": {"rule_0": approve_rule}}),
		"action": act("/orders", "create", {"amount": 100, "supplier": "untrusted"}),
	})
	d.allow == true
	d.require_approval == true
	d.reason == "untrusted supplier needs human"
}

test_approval_rule_no_match_when_extra_differs if {
	d := data.authz.decision with input as object.union(base, {
		"delegation": object.union(live_delegation, {"approval_rules": {"rule_0": approve_rule}}),
		"action": act("/orders", "create", {"amount": 100, "supplier": "acme"}),
	})
	d.allow == true
	d.require_approval == false
}

test_hot_reload_example_time_window if {
	# Example: an operator adds a live hand-edited approval rule for
	# out-of-hours actions (policy snippet shown in docs/Policy-and-OPA.md).
	d := data.authz.decision with input as object.union(base, {
		"action": act("/orders", "create", {"amount": 150, "time": "2026-10-16T05:00:00Z"}),
		"delegation": object.union(live_delegation, {
			"approval_rules": {"rule_9": {
				"when_resource_pattern": "/*", "when_action_pattern": "create",
				"when_extra": {"night": "true"}, "require": true,
				"rationale": "created out of working hours"}},
			}),
	})
	d.allow == true
	# no rule matched for the 'night' extra because context lacks it
	d.require_approval == false
}
