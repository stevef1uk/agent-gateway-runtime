package authz

# Agent Gateway — OPA/Rego v1 policy authorizer (OPA 1.0+).
#
# Input document (supplied by internal/policy/opa_authorizer.go, JSON):
#   "now":         RFC3339 timestamp of the decision wall-clock
#   "delegation":  { id, user_id, agent_id, resources[], actions[],
#                    expires_at, limits{}, approval_rules{}, ... }
#   "action":      { agent_id, user_id, resource, action, tenant, context{} }
#   "limits" / "approval_rules" are also provided top-level for convenience.
#
# Output (queried as data.authz.decision): one object
#   { "allow": bool, "require_approval": bool, "reason": string, "policy_id": "opa" }
#
# Semantics mirror internal/policy/policy.go (BasicAuthorizer), extended
# freely by the operator as Rego:
#   - violations deny outright
#   - spend-cap breaches DOWNGRADE to require-approval
#   - approval rules carried by the delegation upgrade matching actions
# The limits map is keyed by limit NAME (e.g. "spend_per_order"); each
# entry carries an auxiliary "type" for human description.

import rego.v1

default allow := false
default require_approval := false

# ---------------------------------------------------------------------------
# Pattern matching — mirrors delegation.Match(): exact, a bare "*" (all),
# trailing "*" prefix match, leading "*" suffix match.
# ---------------------------------------------------------------------------
match(pattern, s) if {
	pattern == "*"
}

match(pattern, s) if {
	pattern == s
}

match(pattern, s) if {
	pattern != "*"
	endswith(pattern, "*")
	startswith(s, trim_suffix(pattern, "*"))
}

match(pattern, s) if {
	startswith(pattern, "*")
	pattern != "*"
	endswith(s, trim_prefix(pattern, "*"))
}

pattern_ok(p, s) if {
	p == ""
}

pattern_ok(p, s) if {
	match(p, s)
}

# ---------------------------------------------------------------------------
# Derived predicates
# ---------------------------------------------------------------------------
resource_allowed if {
	some r in input.delegation.resources
	match(r, input.action.resource)
}

action_allowed if {
	some a in input.delegation.actions
	match(a, input.action.action)
}

agent_bound if {
	input.action.agent_id == ""
}

agent_bound if {
	input.action.agent_id == input.delegation.agent_id
}

user_bound if {
	input.action.user_id == ""
}

user_bound if {
	input.action.user_id == input.delegation.user_id
}

# ---------------------------------------------------------------------------
# Denial rules (hard deny). Each violation yields its own reason.
# ---------------------------------------------------------------------------
deny_reasons contains msg if {
	not resource_allowed
	msg := sprintf("resource not allowed: %s", [input.action.resource])
}

deny_reasons contains msg if {
	not action_allowed
	msg := sprintf("action not allowed: %s", [input.action.action])
}

deny_reasons contains msg if {
	not agent_bound
	msg := sprintf("agent %q does not match delegation agent %q", [input.action.agent_id, input.delegation.agent_id])
}

deny_reasons contains msg if {
	not user_bound
	msg := "user does not match delegation user"
}

deny_reasons contains msg if {
	some key
	l := input.limits[key]
	key == "max_count"
	"count" in object.keys(input.action.context)
	count := input.action.context.count
	not valid_count(count)
	msg := "count must be a non-negative integer"
}

deny_reasons contains msg if {
	some key
	l := input.limits[key]
	key == "max_count"
	"count" in object.keys(input.action.context)
	count := input.action.context.count
	valid_count(count)
	count > l.max
	msg := sprintf("count %v exceeds limit %v", [count, l.max])
}

# ---------------------------------------------------------------------------
# Approval rules carried by the delegation: matching actions require a
# two-phase (202 → human approval) completion at the gateway.
# ---------------------------------------------------------------------------
rule_requires_approval(rule) if {
	rule.require == true
	pattern_ok(rule.when_resource_pattern, input.action.resource)
	pattern_ok(rule.when_action_pattern, input.action.action)
	extras_match(rule.when_extra, input.action.context)
}

# every configured context extra must be present and equal; a missing key is
# a mismatch (the negated comparison also covers the "undefined" case).
extras_match(want, got) if {
	not extras_mismatch(want, got)
}

extras_mismatch(want, got) if {
	some k, _ in want
	not k in object.keys(got)
}

extras_mismatch(want, got) if {
	some k, v in want
	not extra_value_matches(v, got[k])
}

extra_value_matches(want, got) if {
	want == got
}

extra_value_matches(want, got) if {
	is_string(want)
	is_number(got)
	to_number(want) == got
}

extra_value_matches(want, got) if {
	is_string(want)
	is_string(got)
	to_number(want) == to_number(got)
}

extra_value_matches(want, got) if {
	is_number(want)
	is_string(got)
	to_number(got) == want
}

require_approval if {
	some rule in input.delegation.approval_rules
	rule_requires_approval(rule)
}

assessment_reason := rule.rationale if {
	some rule in input.delegation.approval_rules
	rule_requires_approval(rule)
	rule.rationale != ""
}

# ---------------------------------------------------------------------------
# Spend-cap downgrade: above `spend_per_order` the action is not denied —
# it requires human approval.
# ---------------------------------------------------------------------------
spend_breached if {
	some key
	l := input.limits[key]
	key == "spend_per_order"
	"amount" in object.keys(input.action.context)
	amount := input.action.context.amount
	not valid_amount(amount)
}

spend_breached if {
	some key
	l := input.limits[key]
	key == "spend_per_order"
	"amount" in object.keys(input.action.context)
	amount := input.action.context.amount
	valid_amount(amount)
	amount > l.max
}

require_approval if {
	spend_breached
}

assessment_reason := msg if {
	spend_breached
	some key
	l := input.limits[key]
	key == "spend_per_order"
	"amount" in object.keys(input.action.context)
	amount := input.action.context.amount
	not valid_amount(amount)
	msg := "amount is invalid; approval required"
}

assessment_reason := msg if {
	spend_breached
	some key
	l := input.limits[key]
	key == "spend_per_order"
	"amount" in object.keys(input.action.context)
	amount := input.action.context.amount
	valid_amount(amount)
	msg := sprintf("amount %v exceeds auto-approve limit %v %s; approval required",
		[amount, l.max, l.unit])
}

valid_count(x) if {
	is_number(x)
	x >= 0
	floor(x) == x
}

valid_amount(x) if {
	is_number(x)
	x >= 0
	floor(x) == x
}

# ---------------------------------------------------------------------------
# Decision object
# ---------------------------------------------------------------------------
allow if {
	count(deny_reasons) == 0
}

reasons contains msg if {
	allow
	msg := assessment_reason
}

reason := min(reasons) if {
	allow
	count(reasons) > 0
}

reason := "allowed by OPA policy" if {
	allow
	count(reasons) == 0
}

default decision := {
	"allow": false,
	"require_approval": false,
	"reason": "no matching rule",
	"policy_id": "opa",
}

decision := deny_decision if {
	count(deny_reasons) > 0
	deny_decision := {
		"allow": false,
		"require_approval": false,
		"reason": concat("; ", [r | some r in deny_reasons]),
		"policy_id": "opa",
	}
}

decision := {
	"allow": true,
	"require_approval": require_approval,
	"reason": reason,
	"policy_id": "opa",
} if {
	allow
}
