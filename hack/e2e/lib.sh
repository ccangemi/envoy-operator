# shellcheck shell=bash
# Helpers for the end-to-end tests. hack/e2e/ocp.sh and hack/e2e/kind.sh
# source this file.

# shellcheck source=hack/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

KUBECTL=${KUBECTL:-oc}
NS=$OPERATOR_NAMESPACE
CSV_NAME=$PACKAGE_NAME.v$OPERATOR_VERSION
TEST_NS=${TEST_NS:-ar-test}
CATALOG_NAME=${CATALOG_NAME:-envoy-operator-test}
GATEWAY_NAME=agent-router-basic
WEBHOOK_NAME=envoy-ai-gateway-gateway-pod-mutator.$NS
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

# --- Catalog and installation --------------------------------------------------
csv_phase() { k get csv "$CSV_NAME" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null; }
csv_succeeded() { [[ $(csv_phase) == Succeeded ]]; }

deployment_available() {
  [[ $(k get deployment "$1" -n "${2:-$NS}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null) == True ]]
}

install_operator() {
  log "creating namespace $NS, the OperatorGroup and the Subscription"
  k create namespace "$NS" --dry-run=client -o yaml | k apply -f - >/dev/null
  k apply -f - >/dev/null <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: $PACKAGE_NAME
  namespace: $NS
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: $PACKAGE_NAME
  namespace: $NS
spec:
  name: $PACKAGE_NAME
  channel: $CHANNEL
  source: $CATALOG_NAME
  sourceNamespace: ${CATALOG_SOURCE_NAMESPACE:-$NS}
  installPlanApproval: Automatic
  ${STARTING_CSV:+startingCSV: $STARTING_CSV}
EOF
  wait_for "ClusterServiceVersion $CSV_NAME is Succeeded" csv_succeeded || {
    k get csv,installplan,subscription -n "$NS" -o wide || true
    k get pods -n "$NS" || true
    return 1
  }
}

# --- Checks on the installed operator ------------------------------------------
webhook_has_ca() { [[ -n $(k get mutatingwebhookconfiguration "$WEBHOOK_NAME" -o jsonpath='{.webhooks[0].clientConfig.caBundle}') ]]; }
webhook_has_owner() {
  k get mutatingwebhookconfiguration "$WEBHOOK_NAME" -o jsonpath='{.metadata.ownerReferences[*].kind}' | grep -q ClusterRole
}
secret_exists() { k get secret "$1" -n "$NS"; }

verify_operator() {
  log "checking the installed operator"
  expect "deployment envoy-gateway is available" deployment_available envoy-gateway
  expect "deployment ai-gateway-controller is available" deployment_available ai-gateway-controller
  expect "webhook configuration $WEBHOOK_NAME exists" k get mutatingwebhookconfiguration "$WEBHOOK_NAME"
  expect "webhook configuration has a CA bundle" webhook_has_ca
  expect "certgen created the Envoy Gateway secrets" secret_exists envoy-gateway
  expect "certgen created the Envoy proxy secret" secret_exists envoy
  expect "the bootstrap created the MCP seed secret" secret_exists ai-gateway-controller-mcp-session-encryption
  echo "Pods in $NS:"
  k get pods -n "$NS" -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerStatuses[*].restartCount,SCC:.metadata.annotations.openshift\.io/scc' || true
}

# --- Functional test --------------------------------------------------------------
gateway_programmed() {
  [[ $(k get gateway "$GATEWAY_NAME" -n "$TEST_NS" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}') == True ]]
}
route_accepted() {
  k get aigatewayroute "$GATEWAY_NAME" -n "$TEST_NS" -o jsonpath='{.status.conditions[*].type}' | grep -q Accepted
}
proxy_pod_has_extproc() {
  k get pods -n "$TEST_NS" -l "gateway.envoyproxy.io/owning-gateway-name=$GATEWAY_NAME" \
    -o jsonpath='{.items[*].spec.initContainers[*].name}{" "}{.items[*].spec.containers[*].name}' | grep -q extproc
}

# chat_request runs curl in a short-lived pod and prints the HTTP status and
# the body. The body asks for "test-model", which the AIGatewayRoute sends to
# the test backend.
chat_request() {
  local pod=curl-$RANDOM
  k run "$pod" -n "$TEST_NS" --restart=Never --quiet \
    --image="${CURL_IMAGE:-registry.access.redhat.com/ubi9/ubi-minimal:latest}" \
    --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"c","image":"'"${CURL_IMAGE:-registry.access.redhat.com/ubi9/ubi-minimal:latest}"'","command":["curl","-sS","-m","20","-w","\\nHTTP %{http_code}\\n","-H","Content-Type: application/json","-d","{\"model\":\"test-model\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}]}","http://'"$GATEWAY_NAME"'.'"$TEST_NS"'.svc.cluster.local/v1/chat/completions"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' \
    >/dev/null
  local start
  start=$(date +%s)
  until [[ $(k get pod "$pod" -n "$TEST_NS" -o jsonpath='{.status.phase}') =~ ^(Succeeded|Failed)$ ]]; do
    (($(date +%s) - start > 120)) && break
    sleep 2
  done
  k logs "$pod" -n "$TEST_NS" 2>&1 || true
  k delete pod "$pod" -n "$TEST_NS" --wait=false >/dev/null 2>&1 || true
}
chat_ok() {
  local out
  out=$(chat_request)
  echo "$out" >"${CHAT_OUTPUT:-/dev/null}"
  grep -q '^HTTP 200' <<<"$out" && grep -q '"choices"' <<<"$out"
}

functional_test() {
  log "running the functional test in namespace $TEST_NS"
  local f
  for f in "$ROOT_DIR"/samples/ocp/*.yaml; do
    if [[ $(basename "$f") == 10-scc-rolebinding.yaml && ${SKIP_SCC:-false} == true ]]; then
      continue
    fi
    k apply -f "$f" >/dev/null
  done
  wait_for "deployment testupstream is available" deployment_available testupstream "$TEST_NS" || true
  wait_for "Gateway $GATEWAY_NAME is programmed" gateway_programmed || true
  wait_for "AIGatewayRoute $GATEWAY_NAME is accepted" route_accepted || true
  wait_for "proxy deployment $GATEWAY_NAME is available" deployment_available "$GATEWAY_NAME" "$TEST_NS" || true
  expect "the proxy pod has the agent router external processor" proxy_pod_has_extproc
  CHAT_OUTPUT=$(mktemp)
  export CHAT_OUTPUT
  if wait_for "a chat completion through the Gateway returns HTTP 200" chat_ok; then
    sed 's/^/    /' "$CHAT_OUTPUT" | head -5
  else
    echo "Last response:"
    sed 's/^/    /' "$CHAT_OUTPUT"
  fi
  rm -f "$CHAT_OUTPUT"
}

delete_samples() {
  log "deleting the example resources"
  local f
  for f in $(find "$ROOT_DIR/samples/ocp" -name '*.yaml' | sort -r); do
    k delete -f "$f" --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1 || true
  done
}
