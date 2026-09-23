#!/bin/sh
# stack-gate waits for a resource to report ready, optionally waits for a scheduler
# resource to be advertised, and then publishes a contract ConfigMap.
#
# It exists because Argo CD reads custom health checks from exactly two places,
# neither of which can travel inside a Stack: the instance-wide argocd-cm, and
# health checks built into Argo CD itself. Argo CD's built-in Job health is
# Progressing while the Job runs and Healthy only when it completes, so a Stack
# task that deploys this Job is a real readiness gate with no Argo CD
# configuration and no cluster-wide side effects.
#
# Everything is driven by environment variables so the same image serves any gate.
set -eu

log() { echo "$(date -u '+%H:%M:%S') [stack-gate] $*"; }
fail() { log "ERROR: $*"; exit 1; }

WAIT_RESOURCE="${WAIT_RESOURCE:-}"
WAIT_NAMESPACE="${WAIT_NAMESPACE:-}"
WAIT_CONDITION="${WAIT_CONDITION:-}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-40m}"
EXISTS_TIMEOUT_SECONDS="${EXISTS_TIMEOUT_SECONDS:-1800}"
CAPACITY_RESOURCE="${CAPACITY_RESOURCE:-}"
CAPACITY_MIN="${CAPACITY_MIN:-0}"
CAPACITY_NODE_SELECTOR="${CAPACITY_NODE_SELECTOR:-}"
CAPACITY_TIMEOUT_SECONDS="${CAPACITY_TIMEOUT_SECONDS:-900}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"
CONTRACT_NAME="${CONTRACT_NAME:-}"
CONTRACT_NAMESPACE="${CONTRACT_NAMESPACE:-default}"
CONTRACT_DATA="${CONTRACT_DATA:-}"

# kubectl, with -n only when the watched resource is namespaced.
kc() {
  if [ -n "$WAIT_NAMESPACE" ]; then
    kubectl -n "$WAIT_NAMESPACE" "$@"
  else
    kubectl "$@"
  fi
}

observed=0
escaped=""

# Total allocatable CAPACITY_RESOURCE across the selected nodes.
count_capacity() {
  {
    if [ -n "$CAPACITY_NODE_SELECTOR" ]; then
      kubectl get nodes -l "$CAPACITY_NODE_SELECTOR" \
        -o "jsonpath={.items[*].status.allocatable['${escaped}']}"
    else
      kubectl get nodes \
        -o "jsonpath={.items[*].status.allocatable['${escaped}']}"
    fi
  } | tr ' ' '\n' | awk '{ sum += $1 } END { print sum + 0 }'
}

if [ -z "$WAIT_RESOURCE" ] && [ "$CAPACITY_MIN" -le 0 ] && [ -z "$CONTRACT_NAME" ]; then
  fail "nothing to do: no WAIT_RESOURCE, no CAPACITY_MIN, and no CONTRACT_NAME"
fi

if [ -n "$WAIT_RESOURCE" ]; then
  # 1. Wait for the resource to exist. Polling rather than `kubectl wait --for=create`
  #    because this also covers the window where the CRD itself is not served yet.
  log "waiting for $WAIT_RESOURCE to exist"
  exists_deadline=$(( $(date +%s) + EXISTS_TIMEOUT_SECONDS ))
  until kc get "$WAIT_RESOURCE" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "$exists_deadline" ]; then
      fail "$WAIT_RESOURCE did not appear within ${EXISTS_TIMEOUT_SECONDS}s"
    fi
    sleep "$POLL_INTERVAL"
  done
  log "$WAIT_RESOURCE exists"

  # 2. Wait for it to report ready.
  if [ -n "$WAIT_CONDITION" ]; then
    log "waiting for $WAIT_RESOURCE --for=$WAIT_CONDITION (timeout $WAIT_TIMEOUT)"
    kc wait "$WAIT_RESOURCE" --for="$WAIT_CONDITION" --timeout="$WAIT_TIMEOUT"
    log "$WAIT_RESOURCE reports $WAIT_CONDITION"
  fi
else
  # Set when Argo CD already gates on this kind through a custom Lua health check,
  # which makes the wait redundant. The capacity check below is not redundant:
  # a ready ClusterPolicy does not mean the device plugin registered anything.
  log "no wait resource configured, skipping the readiness wait"
fi

# 3. Count what the scheduler advertises, and block on it when a minimum is set.
if [ -n "$CAPACITY_RESOURCE" ]; then
  escaped=$(printf '%s' "$CAPACITY_RESOURCE" | sed 's/\./\\./g')
  if [ "$CAPACITY_MIN" -gt 0 ]; then
    capacity_deadline=$(( $(date +%s) + CAPACITY_TIMEOUT_SECONDS ))
    log "waiting for ${CAPACITY_MIN}x $CAPACITY_RESOURCE to be allocatable"
    while :; do
      observed=$(count_capacity)
      if [ "$observed" -ge "$CAPACITY_MIN" ]; then
        log "$observed allocatable $CAPACITY_RESOURCE"
        break
      fi
      if [ "$(date +%s)" -ge "$capacity_deadline" ]; then
        fail "only $observed allocatable $CAPACITY_RESOURCE after ${CAPACITY_TIMEOUT_SECONDS}s, wanted $CAPACITY_MIN"
      fi
      log "allocatable $CAPACITY_RESOURCE: ${observed}/${CAPACITY_MIN}, waiting"
      sleep "$POLL_INTERVAL"
    done
  else
    # Not gating on capacity, but still record it so the contract stays meaningful.
    observed=$(count_capacity)
    log "counted $observed allocatable $CAPACITY_RESOURCE, not gating on it"
  fi
fi

# 4. Publish the contract. Written last, so its existence means the gate passed.
if [ -n "$CONTRACT_NAME" ]; then
  log "publishing contract $CONTRACT_NAMESPACE/$CONTRACT_NAME"
  env_file=$(mktemp)
  {
    echo "ready=true"
    echo "observedCount=$observed"
    echo "verifiedAt=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    if [ -n "$CAPACITY_RESOURCE" ]; then
      echo "resourceName=$CAPACITY_RESOURCE"
    fi
    if [ -n "$CONTRACT_DATA" ]; then
      printf '%s\n' "$CONTRACT_DATA" | grep -v '^[[:space:]]*$' || true
    fi
  } > "$env_file"

  # create|apply rather than create alone: the Job is retried on failure and the
  # ConfigMap may already exist from an earlier attempt.
  kubectl create configmap "$CONTRACT_NAME" -n "$CONTRACT_NAMESPACE" \
    --from-env-file="$env_file" --dry-run=client -o yaml | kubectl apply -f -
  rm -f "$env_file"
fi

log "gate passed"
