# shellcheck shell=bash
# Helpers for the end-to-end tests. hack/e2e/ocp.sh and
# hack/e2e/build-on-cluster.sh source this file.

# shellcheck source=hack/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

KUBECTL=${KUBECTL:-oc}
NS=${NS:-$OPERATOR_NAMESPACE}
CSV_NAME=$PACKAGE_NAME.v$OPERATOR_VERSION
TEST_NS=${TEST_NS:-eg-test}
# shellcheck disable=SC2034 # used by hack/e2e/ocp.sh
GATEWAY_NAME=eg-test-gateway
TIMEOUT=${TIMEOUT:-600}

k() { "$KUBECTL" "$@"; }

e2e_errors=0
pass() { printf 'ok    %s\n' "$*"; }
fail_check() { printf 'FAIL  %s\n' "$*"; e2e_errors=$((e2e_errors + 1)); }

# expect <description> <command...>: a check that does not stop the test.
expect() {
  local description=$1
  shift
  if "$@" >/dev/null 2>&1; then pass "$description"; else fail_check "$description"; fi
}

# wait_for <description> <command...>: retries the command every 5 seconds
# until it succeeds or TIMEOUT seconds pass.
wait_for() {
  local description=$1 start
  shift
  start=$(date +%s)
  log "waiting: $description"
  until "$@" >/dev/null 2>&1; do
    if (($(date +%s) - start > TIMEOUT)); then
      fail_check "timeout after ${TIMEOUT}s: $description"
      return 1
    fi
    sleep 5
  done
  pass "$description"
}

finish() {
  echo
  if [[ $e2e_errors -gt 0 ]]; then
    fail "$e2e_errors end-to-end check(s) failed"
  fi
  echo "All end-to-end checks passed."
}

# --- State of the Gateway API CRDs ------------------------------------------
# A snapshot of the Gateway API CRDs: name, uid, generation, bundle version.
# The operator must never change them, so the snapshot after the test must
# be the same as before.
gateway_api_snapshot() {
  k get crd -o json | "$YQ" -p json -o tsv \
    '.items[] | select(.spec.group == "gateway.networking.k8s.io")
     | [.metadata.name, .metadata.uid, .metadata.generation,
        (.metadata.annotations."gateway.networking.k8s.io/bundle-version" // "none")]' | sort
}
# CRDs that a Helm release created. There must be none: CRDs come with the
# bundle, and the operator has no permission on CRDs.
helm_created_crds() {
  k get crd -l helm.sdk.operatorframework.io/chart -o name
}

# --- Installation through OLM -------------------------------------------------
csv_phase() { k get csv "$CSV_NAME" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null; }
csv_succeeded() { [[ $(csv_phase) == Succeeded ]]; }
catalog_ready() {
  [[ $(k get catalogsource "$1" -n "$2" -o jsonpath='{.status.connectionState.lastObservedState}') == READY ]]
}
deployment_available() {
  [[ $(k get deployment "$1" -n "${2:-$NS}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null) == True ]]
}

# install_operator installs the operator in NS with the OwnNamespace install
# mode. With CATALOG_IMAGE it first creates a CatalogSource for that image in
# NS; otherwise it uses CATALOG_NAME in CATALOG_NAMESPACE.
install_operator() {
  local catalog=${CATALOG_NAME:-community-operators} catalog_ns=${CATALOG_NAMESPACE:-openshift-marketplace}
  log "creating namespace $NS and the OperatorGroup"
  k create namespace "$NS" --dry-run=client -o yaml | k apply -f - >/dev/null
  k apply -f - >/dev/null <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: $PACKAGE_NAME
  namespace: $NS
spec:
  targetNamespaces:
    - $NS
EOF
  if [[ -n ${CATALOG_IMAGE:-} ]]; then
    catalog=$PACKAGE_NAME-test
    catalog_ns=$NS
    log "creating the CatalogSource $catalog for $CATALOG_IMAGE"
    k apply -f - >/dev/null <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: $catalog
  namespace: $catalog_ns
spec:
  sourceType: grpc
  image: $CATALOG_IMAGE
  displayName: $PACKAGE_NAME test catalog
  grpcPodConfig:
    securityContextConfig: restricted
EOF
    wait_for "CatalogSource $catalog is READY" catalog_ready "$catalog" "$catalog_ns" || return 1
  fi
  log "creating the Subscription"
  k apply -f - >/dev/null <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: $PACKAGE_NAME
  namespace: $NS
spec:
  name: $PACKAGE_NAME
  channel: $CHANNEL
  source: $catalog
  sourceNamespace: $catalog_ns
  installPlanApproval: Automatic
EOF
  wait_for "ClusterServiceVersion $CSV_NAME is Succeeded" csv_succeeded || {
    k get csv,installplan,subscription -n "$NS" -o wide || true
    k get pods -n "$NS" || true
    return 1
  }
}

# --- The custom resource --------------------------------------------------------
cr_condition() {
  k get "$CR_KIND.$CR_GROUP" "$CR_NAME" -n "$NS" -o jsonpath="{.status.conditions[?(@.type==\"$1\")].status}" 2>/dev/null
}
cr_deployed() { [[ $(cr_condition Deployed) == True ]]; }
# The number of the latest revision of the Helm release.
release_revision() {
  k get secret -n "$NS" -l "owner=helm,name=$CR_NAME" -o jsonpath='{range .items[*]}{.metadata.labels.version}{"\n"}{end}' \
    | sort -n | tail -1
}

# create_cr applies CR_FILE (default: the sample of config/samples) in NS and
# waits until the release is deployed.
create_cr() {
  local file=${CR_FILE:-$(find "$ROOT_DIR/config/samples" -name '*_v1alpha1_*.yaml' | head -1)}
  log "applying ${file#"$ROOT_DIR"/} in $NS"
  k apply -n "$NS" -f "$file" >/dev/null
  wait_for "$CR_KIND $CR_NAME is Deployed" cr_deployed || {
    k get "$CR_KIND.$CR_GROUP" "$CR_NAME" -n "$NS" -o yaml | "$YQ" '.status' || true
    return 1
  }
}

# revision_stable waits STABILITY_SECONDS (default: three reconcile periods
# and a margin) and checks that the release did not get a new revision. A new
# revision without a change would mean that the chart renders differently at
# each dry run.
revision_stable() {
  local before after seconds=${STABILITY_SECONDS:-200}
  before=$(release_revision)
  log "waiting ${seconds}s to check that release revision $before stays the same"
  sleep "$seconds"
  after=$(release_revision)
  [[ -n $before && $before == "$after" ]]
}

pods_use_restricted_scc() {
  local scc found=0
  for scc in $(k get pods -n "$NS" -l "app.kubernetes.io/instance=$CR_NAME" -o jsonpath='{.items[*].metadata.annotations.openshift\.io/scc}'); do
    found=1
    [[ $scc == restricted-v2 ]] || return 1
  done
  [[ $found == 1 ]]
}
