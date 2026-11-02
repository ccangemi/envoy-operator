#!/usr/bin/env bash
# End-to-end test on a local kind cluster. The CI runs it on every pull
# request.
#
#   hack/e2e/kind.sh            create the cluster, install and test
#   KEEP_CLUSTER=true hack/e2e/kind.sh   do not delete the cluster at the end
#
# Needs: docker (or podman with KIND_EXPERIMENTAL_PROVIDER=podman), network
# access, and the tools from hack/tools.sh (including kind).
#
# How the test makes kind look like OpenShift 4.22:
#   - It installs the Gateway API v1.4.1 standard CRDs, the same version that
#     OpenShift 4.22 provides, before the operator.
#   - It installs OLM v0.
#   - It plays the role of the OpenShift service CA: it creates the serving
#     certificate secret of the agent router webhook and writes the CA into
#     the config map that the bundle creates.
#   - It plays the role of the restricted-v2 SCC for the user ID: a
#     MutatingAdmissionPolicy gives a numeric user ID to the pods without
#     runAsUser in the test namespaces. Some upstream images run as the
#     non-numeric user "nonroot", which the kubelet refuses with
#     runAsNonRoot when no runAsUser is set.
#   - It skips the nonroot-v2 RoleBinding of the examples (kind has no SCC).
# What it cannot test: SCCs and the real service CA. hack/e2e/ocp.sh covers
# them on OpenShift.

# Set before lib.sh, which defaults to oc.
KUBECTL=${KUBECTL:-kubectl}
TIMEOUT=${TIMEOUT:-300}

# shellcheck source=hack/e2e/lib.sh
source "$(dirname "$0")/lib.sh"
require_tools KIND OPERATOR_SDK OPM YQ

CONTAINER_TOOL=${CONTAINER_TOOL:-docker}
CLUSTER=${CLUSTER:-envoy-operator-e2e}
NODE_IMAGE=${NODE_IMAGE:-kindest/node:v1.35.8@sha256:07b2536e30b803ed61d1677a79df6115f798ce64c80f9e22f6ed45afd09323c0}
GATEWAY_API_VERSION=${GATEWAY_API_VERSION:-v1.4.1}
OLM_VERSION=${OLM_VERSION:-v0.46.0}
REGISTRY_NAME=${REGISTRY_NAME:-kind-registry}
REGISTRY_PORT=${REGISTRY_PORT:-5001}
REGISTRY=localhost:$REGISTRY_PORT
TAG=${TAG:-e2e}
BUNDLE_IMAGE=$REGISTRY/envoy-operator-bundle:$TAG
CATALOG_IMAGE=$REGISTRY/envoy-operator-catalog:$TAG
SNAPSHOT_FILE=$ROOT_DIR/build/kind-gateway-api-snapshot.tsv
export KUBECTL

cleanup() {
  if [[ ${KEEP_CLUSTER:-false} != true ]]; then
    log "deleting the kind cluster $CLUSTER"
    "$KIND" delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
  fi
}

dump_debug() {
  log "debug information"
  k get csv,subscription,installplan,catalogsource -A 2>&1 | tail -20 || true
  k get pods -A 2>&1 | grep -v -E 'kube-system|local-path' || true
  k describe pods -n "$NS" 2>&1 | tail -60 || true
  local p
  for p in $(k get pods -n "$NS" -o name 2>/dev/null); do
    echo "--- logs of $p"
    k logs "$p" -n "$NS" --all-containers --tail=40 2>&1 || true
  done
}

# --- Cluster with a local registry (https://kind.sigs.k8s.io/docs/user/local-registry/)
create_cluster() {
  if [[ -z $("$CONTAINER_TOOL" ps -q -f "name=^$REGISTRY_NAME$") ]]; then
    log "starting the local registry $REGISTRY"
    "$CONTAINER_TOOL" run -d --restart=always -p "127.0.0.1:$REGISTRY_PORT:5000" \
      --network bridge --name "$REGISTRY_NAME" docker.io/library/registry:2 >/dev/null
  fi
  log "creating the kind cluster $CLUSTER"
  "$KIND" create cluster --name "$CLUSTER" --image "$NODE_IMAGE" --wait 120s --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
featureGates:
  MutatingAdmissionPolicy: true
runtimeConfig:
  admissionregistration.k8s.io/v1beta1: "true"
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = "/etc/containerd/certs.d"
EOF
  local node
  for node in $("$KIND" get nodes --name "$CLUSTER"); do
    "$CONTAINER_TOOL" exec "$node" mkdir -p "/etc/containerd/certs.d/$REGISTRY"
    printf '[host."http://%s:5000"]\n' "$REGISTRY_NAME" |
      "$CONTAINER_TOOL" exec -i "$node" cp /dev/stdin "/etc/containerd/certs.d/$REGISTRY/hosts.toml"
  done
  "$CONTAINER_TOOL" network connect kind "$REGISTRY_NAME" 2>/dev/null || true
}

# --- Images ----------------------------------------------------------------------
build_images() {
  log "building and pushing $BUNDLE_IMAGE"
  "$CONTAINER_TOOL" build -q -f "$ROOT_DIR/bundle.Dockerfile" -t "$BUNDLE_IMAGE" "$ROOT_DIR" >/dev/null
  "$CONTAINER_TOOL" push -q "$BUNDLE_IMAGE" >/dev/null
  "$ROOT_DIR/hack/build-catalog.sh" "$ROOT_DIR/build/catalog" "$BUNDLE_DIR=$BUNDLE_IMAGE"
  log "building and pushing $CATALOG_IMAGE"
  "$CONTAINER_TOOL" build -q -f "$ROOT_DIR/catalog.Dockerfile" -t "$CATALOG_IMAGE" "$ROOT_DIR" >/dev/null
  "$CONTAINER_TOOL" push -q "$CATALOG_IMAGE" >/dev/null
}

# --- OpenShift look-alike ------------------------------------------------------
install_platform() {
  log "installing the Gateway API $GATEWAY_API_VERSION standard CRDs"
  k apply --server-side -f \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_API_VERSION/standard-install.yaml" >/dev/null
  mkdir -p "$ROOT_DIR/build"
  gateway_api_snapshot >"$SNAPSHOT_FILE"
  log "installing the fake SCC user ID policy"
  k apply -f - >/dev/null <<EOF
apiVersion: admissionregistration.k8s.io/v1beta1
kind: MutatingAdmissionPolicy
metadata:
  name: e2e-fake-scc-uid
spec:
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE"]
        resources: ["pods"]
  matchConditions:
    - name: no-pod-user-id
      expression: "!has(object.spec.securityContext) || !has(object.spec.securityContext.runAsUser)"
  failurePolicy: Fail
  reinvocationPolicy: Never
  mutations:
    - patchType: ApplyConfiguration
      applyConfiguration:
        expression: >-
          Object{spec: Object.spec{securityContext: Object.spec.securityContext{runAsUser: 1000700000}}}
---
apiVersion: admissionregistration.k8s.io/v1beta1
kind: MutatingAdmissionPolicyBinding
metadata:
  name: e2e-fake-scc-uid
spec:
  policyName: e2e-fake-scc-uid
  matchResources:
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: In
          values: [$NS, $TEST_NS]
EOF
  log "installing OLM $OLM_VERSION"
  "$OPERATOR_SDK" olm install --version "$OLM_VERSION" --timeout 5m >/dev/null
}

# The serving certificate that the OpenShift service CA would create.
fake_service_ca() {
  local dir
  dir=$(mktemp -d)
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=fake-service-ca" \
    -keyout "$dir/ca.key" -out "$dir/ca.crt" 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -subj "/CN=ai-gateway-controller.$NS.svc" \
    -keyout "$dir/tls.key" -out "$dir/tls.csr" 2>/dev/null
  printf 'subjectAltName=DNS:ai-gateway-controller.%s.svc,DNS:ai-gateway-controller.%s.svc.cluster.local\n' "$NS" "$NS" >"$dir/ext"
  openssl x509 -req -in "$dir/tls.csr" -CA "$dir/ca.crt" -CAkey "$dir/ca.key" -CAcreateserial \
    -days 1 -extfile "$dir/ext" -out "$dir/tls.crt" 2>/dev/null
  k create namespace "$NS" --dry-run=client -o yaml | k apply -f - >/dev/null
  k create secret tls ai-gateway-controller-tls -n "$NS" --cert="$dir/tls.crt" --key="$dir/tls.key" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  cp "$dir/ca.crt" "$ROOT_DIR/build/fake-service-ca.crt"
  rm -rf "$dir"
}

# OLM creates the config map from the bundle, empty. Write the CA into it, as
# the service CA operator does on OpenShift.
configmap_exists() { k get configmap ai-gateway-controller-service-ca -n "$NS"; }
inject_service_ca() {
  wait_for "OLM created the config map ai-gateway-controller-service-ca" configmap_exists || return 1
  k create configmap ai-gateway-controller-service-ca -n "$NS" \
    --from-file=service-ca.crt="$ROOT_DIR/build/fake-service-ca.crt" --dry-run=client -o yaml \
    | "$YQ" '.metadata.annotations."service.beta.openshift.io/inject-cabundle" = "true"' \
    | k apply -f - >/dev/null
}

main() {
  trap cleanup EXIT
  create_cluster
  build_images
  install_platform
  fake_service_ca

  log "creating CatalogSource $CATALOG_NAME"
  k apply -f - >/dev/null <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: $CATALOG_NAME
  namespace: $NS
spec:
  sourceType: grpc
  image: $CATALOG_IMAGE
  displayName: envoy-operator test catalog
EOF
  catalog_ready() {
    [[ $(k get catalogsource "$CATALOG_NAME" -n "$NS" -o jsonpath='{.status.connectionState.lastObservedState}') == READY ]]
  }
  wait_for "CatalogSource $CATALOG_NAME is READY" catalog_ready || { dump_debug; finish; }

  # Write the CA as soon as OLM creates the config map, in parallel with the
  # installation.
  inject_service_ca &
  local injector=$!
  if ! install_operator; then
    wait "$injector" || true
    dump_debug
    finish
  fi
  wait "$injector" || true

  verify_operator
  expect "the Gateway API CRDs did not change" diff "$SNAPSHOT_FILE" <(gateway_api_snapshot)
  SKIP_SCC=true CURL_IMAGE=${CURL_IMAGE:-registry.access.redhat.com/ubi9/ubi-minimal:latest} functional_test
  expect "the Gateway API CRDs did not change after the test" diff "$SNAPSHOT_FILE" <(gateway_api_snapshot)

  [[ $e2e_errors -eq 0 ]] || dump_debug
  finish
}

main "$@"
