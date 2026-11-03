#!/usr/bin/env bash
# End-to-end test on an OpenShift 4.22 cluster.
#
#   KUBECONFIG=<file> hack/e2e/ocp.sh <command>
#
# Commands:
#   install    install the operator through OLM (OwnNamespace) and wait until it is ready
#   cr         create the EnvoyGateway resource and wait until the release is deployed
#   verify     check the release, the pods, the OpenShift Gateway API and the revision stability
#   test       send a request through a Gateway, with the examples in samples/ocp/test
#   uninstall  delete the examples and the EnvoyGateway resource, then uninstall the operator
#   all        install, cr, verify and test
#
# Variables:
#   CATALOG_IMAGE  a test catalog (hack/e2e/build-on-cluster.sh). Without it, the
#                  operator comes from CATALOG_NAME (default community-operators)
#                  in CATALOG_NAMESPACE (default openshift-marketplace).
#   CR_FILE        the EnvoyGateway resource (default samples/ocp/envoygateway.yaml)
#   STABILITY_SECONDS  how long verify watches the release revision (default 200)
#
# The script never logs in. Log in first, with a kubeconfig file that is not
# in this repository.

# shellcheck source=hack/e2e/lib.sh
source "$(dirname "$0")/lib.sh"
require_tools YQ

export CR_FILE=${CR_FILE:-$ROOT_DIR/samples/ocp/envoygateway.yaml}
SNAPSHOT_FILE=${SNAPSHOT_FILE:-$ROOT_DIR/build/gateway-api-snapshot.tsv}

cmd_install() {
  mkdir -p "$(dirname "$SNAPSHOT_FILE")"
  if [[ ! -s $SNAPSHOT_FILE ]]; then
    gateway_api_snapshot >"$SNAPSHOT_FILE"
    log "saved a snapshot of the Gateway API CRDs in ${SNAPSHOT_FILE#"$ROOT_DIR"/}"
  fi
  install_operator
}

cmd_cr() { create_cr; }

ingress_healthy() {
  [[ $(k get clusteroperator ingress -o jsonpath='{.status.conditions[?(@.type=="Available")].status}{.status.conditions[?(@.type=="Degraded")].status}') == TrueFalse ]]
}
secret_exists() { k get secret "$1" -n "$NS"; }

cmd_verify() {
  log "checking the release"
  expect "$CR_KIND $CR_NAME is Deployed" cr_deployed
  expect "deployment envoy-gateway is available" deployment_available envoy-gateway
  expect "certgen created the Envoy Gateway secrets" secret_exists envoy-gateway
  expect "certgen created the Envoy proxy secret" secret_exists envoy
  expect "the Envoy Gateway pods run with the restricted-v2 SCC" pods_use_restricted_scc
  echo "Pods in $NS:"
  k get pods -n "$NS" -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerStatuses[*].restartCount,SCC:.metadata.annotations.openshift\.io/scc' || true

  log "checking the OpenShift Gateway API"
  if [[ -s $SNAPSHOT_FILE ]]; then
    expect "the Gateway API CRDs did not change (name, uid, generation, bundle version)" \
      diff "$SNAPSHOT_FILE" <(gateway_api_snapshot)
  else
    fail_check "no snapshot of the Gateway API CRDs; run the install command first"
  fi
  expect "the Ingress Operator admission policy still exists" \
    k get validatingadmissionpolicy openshift-ingress-operator-gatewayapi-crd-admission
  expect "ClusterOperator ingress is available and not degraded" ingress_healthy
  expect "no CRD was created by a Helm release" test -z "$(helm_created_crds)"

  expect "the release keeps its revision when nothing changes" revision_stable
}

# --- Functional test --------------------------------------------------------------
gateway_programmed() {
  [[ $(k get gateway "$GATEWAY_NAME" -n "$TEST_NS" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}') == True ]]
}

# http_request runs curl in a short-lived pod and prints the HTTP status.
http_request() {
  local pod=curl-$RANDOM image=${CURL_IMAGE:-registry.access.redhat.com/ubi9/ubi-minimal:latest}
  k run "$pod" -n "$TEST_NS" --restart=Never --quiet --image="$image" \
    --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"c","image":"'"$image"'","command":["curl","-sS","-o","/dev/null","-m","20","-w","HTTP %{http_code}\\n","http://'"$GATEWAY_NAME"'.'"$TEST_NS"'.svc.cluster.local/"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' \
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
http_ok() { http_request | grep -q '^HTTP 200'; }

cmd_test() {
  log "running the functional test in namespace $TEST_NS"
  local f
  for f in "$ROOT_DIR"/samples/ocp/test/*.yaml; do
    k apply -f "$f" >/dev/null
  done
  wait_for "deployment backend is available" deployment_available backend "$TEST_NS" || true
  wait_for "Gateway $GATEWAY_NAME is programmed" gateway_programmed || true
  wait_for "proxy deployment $GATEWAY_NAME is available" deployment_available "$GATEWAY_NAME" "$TEST_NS" || true
  wait_for "a request through the Gateway returns HTTP 200" http_ok || true
  if [[ -s $SNAPSHOT_FILE ]]; then
    expect "the Gateway API CRDs did not change after the test" diff "$SNAPSHOT_FILE" <(gateway_api_snapshot)
  fi
}

cmd_uninstall() {
  log "deleting the examples"
  local f
  for f in $(find "$ROOT_DIR/samples/ocp/test" -name '*.yaml' | sort -r); do
    k delete -f "$f" --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1 || true
  done
  log "deleting $CR_KIND $CR_NAME: the operator uninstalls the release"
  k delete "$CR_KIND.$CR_GROUP" "$CR_NAME" -n "$NS" --ignore-not-found --timeout=300s >/dev/null
  release_gone() { [[ -z $(release_revision) ]]; }
  wait_for "the Helm release is uninstalled" release_gone || true
  log "uninstalling the operator"
  k delete subscription "$PACKAGE_NAME" -n "$NS" --ignore-not-found >/dev/null
  k delete csv "$CSV_NAME" -n "$NS" --ignore-not-found >/dev/null
  k delete catalogsource "$PACKAGE_NAME-test" -n "$NS" --ignore-not-found >/dev/null
  if [[ -s $SNAPSHOT_FILE ]]; then
    expect "the Gateway API CRDs did not change after uninstall" diff "$SNAPSHOT_FILE" <(gateway_api_snapshot)
  fi
  log "left on the cluster on purpose: the CRDs (OLM never deletes CRDs) and the namespace $NS"
}

case ${1:-} in
  install) cmd_install ;;
  cr) cmd_cr ;;
  verify) cmd_verify ;;
  test) cmd_test ;;
  uninstall) cmd_uninstall ;;
  all) cmd_install && cmd_cr && cmd_verify && cmd_test ;;
  *) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
finish
