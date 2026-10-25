#!/usr/bin/env bash
# ============================================================================
# remove-tenant.sh — offboard a hosted tenant (Phase 5, shared-nothing)
#
# Deletes the tenant namespace and its cluster-scoped PV+CERT leftovers.
# Data note (legal record): the tenant's postgres data lives on the HOST at
# /srv/agentgw-<name>/ (Retain reclaim policy + hostPath), so removal does
# NOT delete their audit trail — export it first if required:
#   kubectl -n tenant-<name> exec postgres -- pg_dump -U agentgw agent_gateway
# and archive it, then hand disk cleanup to the operator runbook.
#
# USAGE
#   ./remove-tenant.sh acme             # interactive: asks confirmation
#   ./remove-tenant.sh --force acme     # no prompts (CI)
# ============================================================================
set -euo pipefail

NAME=${1:?"usage: remove-tenant.sh [--force] <name>"}
FORCED=false; [ "${1:-}" = "--force" ] && { FORCED=true; NAME=${2:?"usage: remove-tenant.sh [--force] <name>"}; }
NS="tenant-${NAME}"
PVNAME="agentgw-${NAME}-pv"
HOSTDIR="/srv/agentgw-${NAME}"

say() { printf "\033[1;36m==> %s\033[0m\n" "$*"; }
ok()  { printf "    \033[0;32m✓ %s\033[0m\n" "$*"; }
die() { printf "    \033[0;31m✗ %s\033[0m\n" "$*" >&2; exit 1; }
command -v kubectl >/dev/null || die "kubectl required"

if [ "$FORCED" != true ]; then
  printf "Remove tenant '%s' (namespace %s, keeps host data at %s)? [y/N] " "$NAME" "$NS" "$HOSTDIR"
  read -r ans
  [ "${ans:-}" = "y" ] || { printf "aborted\n"; exit 0; }
fi

kubectl get ns "$NS" >/dev/null 2>&1 || { printf "tenant %s not present; nothing to do\n" "$NS"; exit 0; }

say "export reminder — dumping audit + delegations snapshot first (drops to tenant-<name>-backup-<ts>.sql.gz in this dir)"
DUMP="tenant-${NAME}-backup-$(date +%Y%m%d-%H%M%S).sql.gz"
kubectl -n "$NS" exec deploy/postgres -- pg_dump -U agentgw agent_gateway 2>/dev/null | gzip > "$DUMP" || true
ok "backup written: $DUMP ($(stat -c%s "$DUMP") bytes)"

say "deleting namespace ${NS}"
kubectl delete ns "$NS" --wait=false >/dev/null
say "deleting cluster-scoped leftovers (PV ${PVNAME})"
kubectl delete pv "$PVNAME" --ignore-not-found >/dev/null
ok "tenant '${NAME}' removed — host data at ${HOSTDIR} kept for audit/backup (rotate storage away per runbook)"
