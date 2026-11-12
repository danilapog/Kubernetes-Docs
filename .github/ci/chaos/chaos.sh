#!/usr/bin/env bash
# Resilience (chaos) scenarios against a release already deployed by deploy-test.sh.
#
# Every scenario: start an availability probe -> inject a fault -> remove it -> wait until all
# pods in "deps" and the Docs namespace are Ready and /healthcheck is "true" -> quick smoke subset.
# A scenario fails if Docs does not recover ON ITS OWN within RECOVERY_TIMEOUT (no restarts by CI),
# or a smoke check fails after recovery (or during the fault, for "degraded but working" scenarios).
#
# env: PLATFORM            kind | openshift   (node restart and Chaos Mesh scenarios are kind only)
#      DOCS_NAMESPACE      (default docs)
#      KIND_CLUSTER        kind cluster name (node restart scenario)
#      CHAOS_ONLY          regex, run only scenarios whose name matches
#      CHAOS_SKIP          regex, skip scenarios whose name matches
#      CHAOS_MESH          1 = install Chaos Mesh and run network/stress scenarios (kind only)
#      CHAOS_MESH_VERSION  Chaos Mesh chart version
#      FAULT_DURATION      seconds a network fault is held (default 60)
#      RECOVERY_TIMEOUT    seconds to recover after the fault is removed (default 300)
#      MAX_DOWNTIME        seconds; if set, fail when the longest outage is longer (default: report only)
set -euo pipefail

CI_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NS="${DOCS_NAMESPACE:-docs}"
DEPS_NS=deps
PLATFORM="${PLATFORM:-kind}"
FAULT_DURATION="${FAULT_DURATION:-60}"
RECOVERY_TIMEOUT="${RECOVERY_TIMEOUT:-300}"
MAX_DOWNTIME="${MAX_DOWNTIME:-}"
CHAOS_MESH_VERSION="${CHAOS_MESH_VERSION:-2.8.4}"
# shellcheck source=../scripts/diagnose.sh
source "$CI_DIR/scripts/diagnose.sh"

export FILES_URL="http://smoke-files.deps.svc.cluster.local:8080"
# Covers DB/cache (CommandService), queue + converter (async conversion), Document Builder
SMOKE_QUICK='^(healthcheck|command_version|command_unknown_document|convert_async_with_polling|docbuilder)$'

# ---------------------------------------------------------------- access to Docs

set_ds_url() {
  if [[ "$PLATFORM" == "openshift" ]]; then
    DS_URL="http://${ROUTE_HOST:?}"
  else
    # node IP is re-read: it can change after a node restart
    DS_URL="http://$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'):30888"
  fi
  export DS_URL
}

healthy() { [[ "$(curl -s -m 3 "$DS_URL/healthcheck" 2>/dev/null)" == "true" ]]; }

smoke() {  # smoke <regex>; no step summary per call, the chaos table is written at the end
  GITHUB_STEP_SUMMARY='' SMOKE_ONLY="$1" python3 "$CI_DIR/smoke/smoke.py"
}

# ---------------------------------------------------------------- probe

# Background loop: one /healthcheck per second, "<epoch> <1|0>" per line
probe_start() {
  PROBE_LOG=$(mktemp)
  ( while :; do
      if healthy; then echo "$(date +%s) 1"; else echo "$(date +%s) 0"; fi
      sleep 1
    done ) > "$PROBE_LOG" 2>/dev/null &
  PROBE_PID=$!
}

# Prints "<failed>/<total> <longest outage in seconds>"
probe_stop() {
  kill "$PROBE_PID" 2>/dev/null || true
  wait "$PROBE_PID" 2>/dev/null || true
  awk '{ n++ }
       $2 == 0 { f++; if (!start) start = $1; cur = $1 - start + 1; if (cur > max) max = cur }
       $2 == 1 { start = 0 }
       END { printf "%d/%d %d\n", f, n, max }' "$PROBE_LOG"
}

# ---------------------------------------------------------------- recovery

# All non-completed, non-terminating pods of the namespace are Ready (and there is at least one)
all_ready() {
  kubectl get pods -n "$1" -o json 2>/dev/null | jq -e '
    [.items[] | select(.status.phase != "Succeeded" and .metadata.deletionTimestamp == null)]
    | length > 0 and all(.status.conditions // [] | any(.type == "Ready" and .status == "True"))' > /dev/null
}

wait_recovered() {
  local deadline=$((SECONDS + RECOVERY_TIMEOUT))
  while (( SECONDS < deadline )); do
    set_ds_url
    if all_ready "$DEPS_NS" && all_ready "$NS" && healthy; then
      echo "recovered after $((SECONDS - (deadline - RECOVERY_TIMEOUT)))s"
      return 0
    fi
    sleep 3
  done
  return 1
}

# Container restarts of Docs pods: a dependency failure should not need a Docs restart
docs_restarts() {
  kubectl get pods -n "$NS" -o json | jq '[.items[].status.containerStatuses[]?.restartCount] | add // 0'
}

# ---------------------------------------------------------------- scenario runner

results=()
failed=0

run() {  # run <name> <function> [args...]
  local name="$1"; shift
  [[ -n "${CHAOS_ONLY:-}" && ! "$name" =~ ${CHAOS_ONLY} ]] && return 0
  [[ -n "${CHAOS_SKIP:-}" && "$name" =~ ${CHAOS_SKIP} ]] && return 0

  echo "::group::chaos: ${name}"
  local status=PASS note="" t0=$SECONDS r0 probe outage
  r0=$(docs_restarts)
  set_ds_url
  probe_start

  if ! "$@"; then
    status=FAIL; note="scenario step failed"
  elif ! wait_recovered; then
    status=FAIL; note="not recovered in ${RECOVERY_TIMEOUT}s"
    diagnose "$NS"; diagnose "$DEPS_NS"
  fi
  probe=$(probe_stop)
  outage="${probe#* }"

  if [[ "$status" == PASS ]] && ! smoke "$SMOKE_QUICK"; then
    status=FAIL; note="smoke failed after recovery"
  fi
  if [[ "$status" == PASS && -n "$MAX_DOWNTIME" ]] && (( outage > MAX_DOWNTIME )); then
    status=FAIL; note="outage ${outage}s > MAX_DOWNTIME ${MAX_DOWNTIME}s"
  fi

  results+=("${name}|${status}|${probe% *}|${outage}s|$(( $(docs_restarts) - r0 ))|$((SECONDS - t0))s|${note}")
  echo "::endgroup::"
  if [[ "$status" != PASS ]]; then
    echo "::error::chaos ${name}: ${note}"
    failed=$((failed + 1))
  fi
}

# ---------------------------------------------------------------- fault helpers

# Hard kill (no graceful shutdown) of pods whose name matches a regex: simulates a crash
kill_pods() {  # kill_pods <namespace> <name regex>
  local ns="$1" re="$2" pods
  mapfile -t pods < <(kubectl get pods -n "$ns" -o name | grep -E "$re" || true)
  (( ${#pods[@]} )) || { echo "::error::no pods match ${re} in ${ns}"; return 1; }
  echo "killing: ${pods[*]}"
  kubectl delete -n "$ns" "${pods[@]}" --grace-period=0 --force --wait=false || return 1
  sleep 5   # let the probe see the outage before the recovery wait starts
}

# Applies a Chaos Mesh manifest, holds it, removes it. With a smoke regex, runs it while the
# fault is active ("degraded but working"), otherwise just waits FAULT_DURATION.
# shellcheck disable=SC2016  # ${DOCS_NS} is an envsubst variable list, not a shell expansion
mesh() {  # mesh <manifest name> [smoke regex during the fault]
  local file="$CI_DIR/chaos/mesh/$1.yaml" rc=0
  DOCS_NS="$NS" envsubst '${DOCS_NS}' < "$file" | kubectl apply -f - || return 1
  sleep 5   # injection is asynchronous
  if [[ -n "${2:-}" ]]; then
    smoke "$2" || rc=1
  else
    sleep "$FAULT_DURATION"
  fi
  DOCS_NS="$NS" envsubst '${DOCS_NS}' < "$file" | kubectl delete -f - --wait=true --timeout=120s || rc=1
  return "$rc"
}

install_chaos_mesh() {
  echo "::group::Chaos Mesh ${CHAOS_MESH_VERSION}"
  helm repo add chaos-mesh https://charts.chaos-mesh.org > /dev/null
  helm repo update chaos-mesh > /dev/null
  # kind nodes run containerd; no dashboard, no DNS server (DNSChaos is not used)
  helm upgrade --install chaos-mesh chaos-mesh/chaos-mesh --version "$CHAOS_MESH_VERSION" \
    -n chaos-mesh --create-namespace \
    --set chaosDaemon.runtime=containerd \
    --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
    --set controllerManager.replicaCount=1 \
    --set dashboard.create=false \
    --set dnsServer.create=false \
    --wait --timeout 10m || { diagnose chaos-mesh; return 1; }
  echo "::endgroup::"
}

# ---------------------------------------------------------------- scenarios

# Requested while no converter runs: the task must wait in the queue and finish when it is back
convert_while_converter_down() {
  local replicas pid rc=0
  replicas=$(kubectl get deploy converter -n "$NS" -o jsonpath='{.spec.replicas}')
  kubectl scale deploy/converter -n "$NS" --replicas=0 || return 1
  kubectl wait pod -n "$NS" -l app=converter --for=delete --timeout=120s || true
  CONVERT_TIMEOUT=300 smoke '^convert_async_with_polling$' > /tmp/convert-pending.log 2>&1 &
  pid=$!
  sleep 30
  kubectl scale deploy/converter -n "$NS" --replicas="$replicas"
  wait "$pid" || rc=1
  cat /tmp/convert-pending.log
  return "$rc"
}

node_restart() {
  local node="${KIND_CLUSTER:?}-control-plane"
  echo "docker restart ${node}"
  docker restart "$node"
  for _ in $(seq 60); do kubectl get --raw /readyz > /dev/null 2>&1 && return 0; sleep 5; done
  echo "::error::API server did not come back"; return 1
}

kubectl apply -n "$NS" -f "$CI_DIR/chaos/nodeport.yaml"
set_ds_url
for _ in $(seq 60); do healthy && break; sleep 2; done
healthy || { echo "::error::Docs is not healthy at ${DS_URL} before chaos"; exit 1; }

# Docs components
run docservice-kill           kill_pods "$NS" '^pod/docservice-'
run converter-kill            kill_pods "$NS" '^pod/converter-'
run convert-converter-down    convert_while_converter_down

# Dependencies (Docs must reconnect by itself)
run postgres-kill             kill_pods "$DEPS_NS" '^pod/postgres-[0-9]+$'
run pgbouncer-kill            kill_pods "$DEPS_NS" '^pod/postgres-pooler-rw-'
run rabbitmq-kill             kill_pods "$DEPS_NS" '^pod/rabbitmq-server-'
run valkey-kill               kill_pods "$DEPS_NS" '^pod/valkey-'
run nfs-server-kill           kill_pods default    '^pod/nfs-server-nfs-server-provisioner-'

# Network and resource faults
if [[ "${CHAOS_MESH:-0}" == 1 && "$PLATFORM" == kind ]]; then
  install_chaos_mesh
  run net-partition-postgres  mesh partition-docs-postgres
  run net-partition-rabbitmq  mesh partition-docs-rabbitmq
  run net-delay-deps          mesh delay-docs-deps     "$SMOKE_QUICK"
  run cpu-stress-converter    mesh stress-converter-cpu '^convert_async_with_polling$'
fi

# Whole node power cycle: the heaviest one, last
[[ "$PLATFORM" == kind ]] && run node-restart node_restart

# ---------------------------------------------------------------- report

{
  echo "### Chaos (${PLATFORM})"
  echo "| scenario | result | failed probes | longest outage | Docs restarts | took | note |"
  echo "|---|---|---|---|---|---|---|"
  for r in "${results[@]}"; do
    IFS='|' read -r n s p o rs t note <<< "$r"
    echo "| \`${n}\` | $([[ $s == PASS ]] && echo ✅ || echo ❌) ${s} | ${p} | ${o} | ${rs} | ${t} | ${note} |"
  done
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"

(( failed == 0 ))
