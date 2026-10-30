#!/usr/bin/env bash
# Installs ONLYOFFICE Docs dependencies the way docs/DEPENDENCIES.md and README describe:
#   cert-manager (required by RabbitMQ Cluster Operator >= 2.20), RabbitMQ Cluster Operator,
#   CloudNativePG, Valkey operator, then Cluster/RabbitmqCluster/ValkeyCluster CRs (scaled down).
# Dependencies go to namespace "deps", their secrets are copied to the Docs namespace.
#
# usage: install-deps.sh <kind|openshift>
# env:   DEPS_STORAGE_CLASS  storage class for dependency PVCs
#        DOCS_NAMESPACE      namespace where Docs will be installed (default docs)
set -euo pipefail

PLATFORM="$1"
CI_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEPS_NS=deps
DOCS_NS="${DOCS_NAMESPACE:-docs}"
export STORAGE_CLASS="${DEPS_STORAGE_CLASS:?DEPS_STORAGE_CLASS is required}"

# Versions as pinned in README / docs/DEPENDENCIES.md
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.21.2}"
RABBITMQ_OPERATOR_VERSION="${RABBITMQ_OPERATOR_VERSION:-v2.23.0}"
CNPG_CHART_VERSION="${CNPG_CHART_VERSION:-0.29.1}"
VALKEY_CHART_VERSION="${VALKEY_CHART_VERSION:-0.6.0}"

log() { echo "::group::$*"; }
end() { echo "::endgroup::"; }

# Waits until at least <min> pods exist in <ns> and all of them are Ready
wait_pods() {
  local ns="$1" min="$2" timeout="${3:-600}" waited=0 count
  while (( waited < timeout )); do
    count=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -vc Completed || true)
    if (( count >= min )) && kubectl wait pod --all -n "$ns" --for=condition=Ready \
         --field-selector=status.phase!=Succeeded --timeout=10s > /dev/null 2>&1; then
      kubectl get pods -n "$ns"; return 0
    fi
    sleep 10; waited=$((waited + 10))
  done
  echo "::error::Pods in namespace ${ns} are not ready after ${timeout}s"
  kubectl get pods -n "$ns" -o wide
  return 1
}

if [[ "$PLATFORM" == "openshift" ]]; then
  log "OpenShift: allow anyuid for dependency namespaces (not for Docs)"
  for ns in cert-manager cnpg-system rabbitmq-system valkey-operator-system "$DEPS_NS"; do
    bash "$CI_DIR/scripts/scc-grant.sh" anyuid group "system:serviceaccounts:${ns}"
  done
  end
fi

kubectl create namespace "$DEPS_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "$DOCS_NS" --dry-run=client -o yaml | kubectl apply -f -

log "Helm repositories"
helm repo add jetstack https://charts.jetstack.io
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo add valkey https://valkey.io/valkey-helm/
helm repo update
end

log "cert-manager ${CERT_MANAGER_VERSION}"
helm upgrade --install cert-manager --version "$CERT_MANAGER_VERSION" jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true --set crds.keep=false --wait --timeout 10m
end

log "RabbitMQ Cluster Operator ${RABBITMQ_OPERATOR_VERSION}"
kubectl apply -f "https://github.com/rabbitmq/cluster-operator/releases/download/${RABBITMQ_OPERATOR_VERSION}/cluster-operator.yml"
kubectl rollout status deployment/rabbitmq-cluster-operator -n rabbitmq-system --timeout=10m
end

log "CloudNativePG ${CNPG_CHART_VERSION}"
helm upgrade --install cnpg --version "$CNPG_CHART_VERSION" cnpg/cloudnative-pg \
  --namespace cnpg-system --create-namespace --wait --timeout 10m
end

log "Valkey operator ${VALKEY_CHART_VERSION}"
helm upgrade --install valkey --version "$VALKEY_CHART_VERSION" valkey/valkey-operator \
  --namespace valkey-operator-system --create-namespace --wait --timeout 10m
end

log "Dependency clusters (storage class: ${STORAGE_CLASS})"
for f in postgresql rabbitmq valkey; do
  envsubst '${STORAGE_CLASS}' < "$CI_DIR/deps/${f}.yaml" | kubectl apply -n "$DEPS_NS" -f -
done
kubectl apply -f "$CI_DIR/smoke/fixtures.yaml"
end

log "Wait for dependencies"
kubectl wait cluster.postgresql.cnpg.io/postgres -n "$DEPS_NS" --for=condition=Ready --timeout=10m
kubectl wait rabbitmqcluster/rabbitmq -n "$DEPS_NS" --for=condition=AllReplicasReady --timeout=10m
# postgres-1, pooler, rabbitmq-server-0, valkey, smoke-files
wait_pods "$DEPS_NS" 5
end

log "Copy dependency secrets to ${DOCS_NS}"
for s in postgres-app rabbitmq-default-user docs-valkey-cluster; do
  kubectl get secret "$s" -n "$DEPS_NS" -o json \
    | jq --arg ns "$DOCS_NS" '{apiVersion, kind, type, data, metadata: {name: .metadata.name, namespace: $ns}}' \
    | kubectl apply -f -
done
end
