#!/usr/bin/env bash
# Installs the bundle WITHOUT OLM, for development and debugging only.
#
#   KUBECONFIG=<file> hack/e2e/direct-install.sh apply
#   KUBECONFIG=<file> hack/e2e/direct-install.sh delete
#
# The script turns the ClusterServiceVersion into plain objects, in the same
# way as OLM does: service accounts, cluster roles with the OLM owner labels,
# roles, bindings and deployments. It then applies them together with the
# other bundle manifests and the CRDs.
#
# Use it to test the runtime behavior (SCC, certgen, webhook bootstrap,
# traffic) when the cluster cannot pull a bundle image. It does not test OLM
# itself: always run hack/e2e/ocp.sh before a release.

# shellcheck source=hack/e2e/lib.sh
source "$(dirname "$0")/lib.sh"
require_tools YQ

CSV=$BUNDLE_DIR/manifests/$PACKAGE_NAME.clusterserviceversion.yaml
LABEL=envoy-operator.io/direct-install

render() {
  # CRDs and the other bundle manifests (config maps and services).
  local f
  for f in "$BUNDLE_DIR"/manifests/*.yaml; do
    [[ $f == "$CSV" ]] && continue
    echo "---"
    if [[ $("$YQ" '.kind' "$f") == CustomResourceDefinition ]]; then
      "$YQ" ".metadata.labels.\"$LABEL\" = \"true\"" "$f"
    else
      N=$NS "$YQ" ".metadata.namespace = strenv(N) | .metadata.labels.\"$LABEL\" = \"true\"" "$f"
    fi
  done
  # The objects that OLM creates from the install strategy.
  echo "---"
  # shellcheck disable=SC2016 # $s is a yq variable, not a shell variable
  C=$CSV_NAME N=$NS L=$LABEL "$YQ" '
    .spec.install.spec as $s
    | (([$s.clusterPermissions[].serviceAccountName, $s.permissions[].serviceAccountName] | unique | .[]
        | {"apiVersion": "v1", "kind": "ServiceAccount",
           "metadata": {"name": ., "namespace": strenv(N), "labels": {strenv(L): "true"}}}),
      ($s.clusterPermissions[]
        | {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRole",
           "metadata": {"name": strenv(C) + "-" + .serviceAccountName,
                        "labels": {strenv(L): "true", "olm.owner": strenv(C),
                                   "olm.owner.kind": "ClusterServiceVersion", "olm.owner.namespace": strenv(N)}},
           "rules": .rules}),
      ($s.clusterPermissions[]
        | {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRoleBinding",
           "metadata": {"name": strenv(C) + "-" + .serviceAccountName, "labels": {strenv(L): "true"}},
           "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole",
                       "name": strenv(C) + "-" + .serviceAccountName},
           "subjects": [{"kind": "ServiceAccount", "name": .serviceAccountName, "namespace": strenv(N)}]}),
      ($s.permissions[]
        | {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "Role",
           "metadata": {"name": strenv(C) + "-" + .serviceAccountName, "namespace": strenv(N),
                        "labels": {strenv(L): "true"}},
           "rules": .rules}),
      ($s.permissions[]
        | {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "RoleBinding",
           "metadata": {"name": strenv(C) + "-" + .serviceAccountName, "namespace": strenv(N),
                        "labels": {strenv(L): "true"}},
           "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "Role",
                       "name": strenv(C) + "-" + .serviceAccountName},
           "subjects": [{"kind": "ServiceAccount", "name": .serviceAccountName, "namespace": strenv(N)}]}),
      ($s.deployments[]
        | {"apiVersion": "apps/v1", "kind": "Deployment",
           "metadata": {"name": .name, "namespace": strenv(N), "labels": (.label + {strenv(L): "true"})},
           "spec": (.spec
             | .template.spec.containers[].env += [{"name": "OPERATOR_CONDITION_NAME", "value": strenv(C)}])}))
    | split_doc' "$CSV"
}

case ${1:-} in
  apply)
    k create namespace "$NS" --dry-run=client -o yaml | k apply -f - >/dev/null
    render | k apply --server-side --force-conflicts --field-manager=envoy-operator-direct -f -
    wait_for "deployment ai-gateway-controller is available" deployment_available ai-gateway-controller
    wait_for "deployment envoy-gateway is available" deployment_available envoy-gateway
    ;;
  delete)
    k delete deployment,service,configmap,serviceaccount,role,rolebinding -n "$NS" -l "$LABEL=true" --ignore-not-found
    k delete clusterrolebinding,clusterrole -l "$LABEL=true" --ignore-not-found
    log "the CRDs stay on the cluster; delete them with: $KUBECTL delete crd -l $LABEL=true"
    ;;
  render) render; exit 0 ;;
  *) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
finish
