#!/usr/bin/env bash
# End-to-end test on an OpenShift 4.22 cluster.
#
#   KUBECONFIG=<file> hack/e2e/ocp.sh <command>
#
# Commands:
#   catalog    check that the OpenShift community catalog has the operator
#   install    install the operator through OLM and wait until it is ready
#   verify     check the operator and the OpenShift Gateway API
#   test       run the functional test with the examples in samples/ocp
#   uninstall  delete the examples and uninstall the operator
#   all        catalog, install, verify and test
#
# The operator comes from the OpenShift community catalog (CatalogSource
# community-operators in openshift-marketplace). Before the operator is
# published there, test the runtime with hack/e2e/direct-install.sh, then run
# the verify and test commands.
#
# The script never logs in. Log in first, with a kubeconfig file that is not
# in this repository.

# Set before lib.sh, which defaults to the local test catalog of kind.sh.
export CATALOG_NAME=${CATALOG_NAME:-community-operators}
export CATALOG_SOURCE_NAMESPACE=${CATALOG_SOURCE_NAMESPACE:-openshift-marketplace}

# shellcheck source=hack/e2e/lib.sh
source "$(dirname "$0")/lib.sh"
require_tools YQ

SNAPSHOT_FILE=${SNAPSHOT_FILE:-$ROOT_DIR/build/gateway-api-snapshot.tsv}

catalog_ready() {
  [[ $(k get catalogsource "$CATALOG_NAME" -n "$CATALOG_SOURCE_NAMESPACE" \
    -o jsonpath='{.status.connectionState.lastObservedState}') == READY ]]
}
package_in_catalog() {
  [[ $(k get packagemanifest "$PACKAGE_NAME" -n "$CATALOG_SOURCE_NAMESPACE" \
    -o jsonpath='{.status.catalogSource}') == "$CATALOG_NAME" ]]
}

cmd_catalog() {
  wait_for "CatalogSource $CATALOG_NAME is READY" catalog_ready
  expect "the catalog $CATALOG_NAME has the package $PACKAGE_NAME" package_in_catalog
  if [[ $e2e_errors -eq 0 ]]; then
    log "channels: $(k get packagemanifest "$PACKAGE_NAME" -n "$CATALOG_SOURCE_NAMESPACE" \
      -o jsonpath='{range .status.channels[*]}{.name}={.currentCSV} {end}')"
  fi
}

cmd_install() {
  mkdir -p "$(dirname "$SNAPSHOT_FILE")"
  if [[ ! -s $SNAPSHOT_FILE ]]; then
    gateway_api_snapshot >"$SNAPSHOT_FILE"
    log "saved a snapshot of the Gateway API CRDs in ${SNAPSHOT_FILE#"$ROOT_DIR"/}"
  fi
  install_operator
}

ingress_healthy() {
  [[ $(k get clusteroperator ingress -o jsonpath='{.status.conditions[?(@.type=="Available")].status}{.status.conditions[?(@.type=="Degraded")].status}') == TrueFalse ]]
}
pods_use_restricted_scc() {
  local scc
  for scc in $(k get pods -n "$NS" -l app.kubernetes.io/part-of="$PACKAGE_NAME" -o jsonpath='{.items[*].metadata.annotations.openshift\.io/scc}'); do
    [[ $scc == restricted-v2 ]] || return 1
  done
}

cmd_verify() {
  verify_operator
  log "checking the OpenShift Gateway API"
  if [[ -s $SNAPSHOT_FILE ]]; then
    expect "the Gateway API CRDs did not change (name, uid, generation, bundle version)" \
      diff "$SNAPSHOT_FILE" <(gateway_api_snapshot)
  else
    fail_check "no snapshot of the Gateway API CRDs; run the install command first"
  fi
  expect "the Gateway API CRDs are still bundle version v1.4.1" \
    test "$(gateway_api_snapshot | cut -f4 | sort -u)" = v1.4.1
  expect "the Ingress Operator admission policy still exists" \
    k get validatingadmissionpolicy openshift-ingress-operator-gatewayapi-crd-admission
  expect "ClusterOperator ingress is available and not degraded" ingress_healthy
  expect "the operator pods run with the restricted-v2 SCC" pods_use_restricted_scc
  expect "the webhook configuration is owned by the operator cluster roles" webhook_has_owner
}

cmd_test() {
  functional_test
  expect "the Gateway API CRDs did not change after the test" diff "$SNAPSHOT_FILE" <(gateway_api_snapshot)
}

cmd_uninstall() {
  delete_samples
  log "uninstalling the operator"
  k delete subscription "$PACKAGE_NAME" -n "$NS" --ignore-not-found >/dev/null
  k delete csv -n "$NS" -l "operators.coreos.com/$PACKAGE_NAME.$NS" --ignore-not-found >/dev/null
  k delete csv "$CSV_NAME" -n "$NS" --ignore-not-found >/dev/null
  webhook_gone() { ! k get mutatingwebhookconfiguration "$WEBHOOK_NAME"; }
  wait_for "the webhook configuration is deleted with the operator" webhook_gone || true
  if [[ -s $SNAPSHOT_FILE ]]; then
    expect "the Gateway API CRDs did not change after uninstall" diff "$SNAPSHOT_FILE" <(gateway_api_snapshot)
  fi
  log "left on the cluster on purpose: the CRDs (OLM never deletes CRDs), the namespace $NS and its secrets"
}

case ${1:-} in
  catalog) cmd_catalog ;;
  install) cmd_install ;;
  verify) cmd_verify ;;
  test) cmd_test ;;
  uninstall) cmd_uninstall ;;
  all) cmd_catalog && [[ $e2e_errors -eq 0 ]] && cmd_install && cmd_verify && cmd_test ;;
  *) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
finish
