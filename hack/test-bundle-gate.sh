#!/usr/bin/env bash
# Tests for hack/bundle-gate.sh. Each test copies the bundle, breaks one rule,
# and expects the gate to fail with the matching check. This makes sure that
# no check passes by mistake (for example because of a wrong yq expression).
#
#   hack/test-bundle-gate.sh      (or: make test-gate)

# shellcheck source=hack/lib.sh
source "$(dirname "$0")/lib.sh"
require_tools YQ

CSV_FILE=manifests/$PACKAGE_NAME.clusterserviceversion.yaml
EG_CONFIG_FILE=manifests/envoy-gateway-config_v1_configmap.yaml
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
# expect_fail <name> <text of the check that must fail> <mutation command...>
# The mutation command runs inside the copy of the bundle.
expect_fail() {
  local name=$1 expected=$2 output
  shift 2
  rm -rf "$work/bundle" && cp -r "$BUNDLE_DIR" "$work/bundle"
  (cd "$work/bundle" && "$@") || { echo "ERROR  $name: the mutation failed"; failures=$((failures + 1)); return; }
  if output=$(BUNDLE_DIR=$work/bundle "$ROOT_DIR/hack/bundle-gate.sh" 2>&1); then
    echo "FAIL   $name: the gate passed"
    failures=$((failures + 1))
  elif grep "^FAIL" <<<"$output" | grep -qF "$expected"; then
    echo "ok     $name"
  else
    echo "FAIL   $name: the gate failed, but not on \"$expected\""
    grep '^FAIL' <<<"$output" | sed 's/^/         /'
    failures=$((failures + 1))
  fi
}

# Helpers that the mutations use.
yqi() { "$YQ" -i "$@"; }
eg_config_edit() {
  local config
  config=$("$YQ" '.data."envoy-gateway.yaml"' "$EG_CONFIG_FILE" | "$YQ" "$1")
  CONFIG=$config "$YQ" -i '.data."envoy-gateway.yaml" = strenv(CONFIG)' "$EG_CONFIG_FILE"
}
add_crd() {
  "$YQ" ".spec.group = \"$1\" | .metadata.name = \"tests.$1\"" manifests/gateway.envoyproxy.io_backends.yaml >"manifests/$1_tests.yaml"
}
add_namespace() { printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: test\n' >manifests/test_v1_namespace.yaml; }

# Make sure that the unchanged bundle passes, so that a failure below has a
# clear cause.
BUNDLE_DIR=$BUNDLE_DIR "$ROOT_DIR/hack/bundle-gate.sh" >/dev/null || fail "the gate fails on the unchanged bundle"

D='.spec.install.spec.deployments'
expect_fail "Gateway API CRD" "no Gateway API CRD" add_crd gateway.networking.k8s.io
expect_fail "InferencePool CRD" "no InferencePool CRD" add_crd inference.networking.k8s.io
expect_fail "unknown CRD group" "every CRD group is allowed" add_crd example.com
expect_fail "owned CRD without file" "the CSV owns exactly the CRDs" rm manifests/gateway.envoyproxy.io_backends.yaml
expect_fail "Namespace object" "no Namespace, admission policy" add_namespace
expect_fail "OLM webhook" "the CSV defines no OLM webhooks" \
  yqi '.spec.webhookdefinitions = [{"generateName": "x", "type": "MutatingAdmissionWebhook"}]' "$CSV_FILE"
expect_fail "watch block" "no provider.kubernetes.watch block" \
  eg_config_edit '.provider.kubernetes.watch = {"type": "Namespaces", "namespaces": ["a"]}'
expect_fail "topology injector" "topology injector is disabled" eg_config_edit '.proxyTopologyInjector.disabled = false'
expect_fail "deploy type" "deploy type" eg_config_edit '.provider.kubernetes.deploy.type = "Other"'
expect_fail "extension manager host" "the extension manager points" \
  eg_config_edit '.extensionManager.service.fqdn.hostname = "wrong.example.com"'
expect_fail "extension manager port" "the extension manager points" \
  eg_config_edit '.extensionManager.service.fqdn.port = 1064'
expect_fail "Backend disabled" "enables Backend and EnvoyPatchPolicy" eg_config_edit '.extensionApis.enableBackend = false'
expect_fail "EnvoyPatchPolicy disabled" "enables Backend and EnvoyPatchPolicy" \
  eg_config_edit '.extensionApis.enableEnvoyPatchPolicy = false'
expect_fail "image by tag" "every image is pinned by digest" \
  yqi "${D}[0].spec.template.spec.containers[0].image = \"docker.io/envoyproxy/gateway:v1.0.0\"" "$CSV_FILE"
expect_fail "rate limit image by tag" "every image is pinned by digest" \
  eg_config_edit '.provider.kubernetes.rateLimitDeployment.container.image = "docker.io/envoyproxy/ratelimit:latest"'
expect_fail "extproc image not related" "every image is listed in relatedImages" \
  yqi "(${D}[1].spec.template.spec.containers[0].args[] | select(test(\"^--extProcImage=\"))) = \"--extProcImage=docker.io/x/y@sha256:0000\"" "$CSV_FILE"
expect_fail "related image by tag" "every related image is pinned" \
  yqi '.spec.relatedImages += [{"name": "x", "image": "docker.io/x/y:1"}]' "$CSV_FILE"
expect_fail "fixed user ID" "no fixed runAsUser" \
  yqi "${D}[0].spec.template.spec.containers[0].securityContext.runAsUser = 65532" "$CSV_FILE"
expect_fail "fixed fsGroup" "no fixed runAsUser" \
  yqi "${D}[1].spec.template.spec.securityContext.fsGroup = 65532" "$CSV_FILE"
expect_fail "privilege escalation" "drops all capabilities" \
  yqi "${D}[1].spec.template.spec.initContainers[1].securityContext.allowPrivilegeEscalation = true" "$CSV_FILE"
expect_fail "capabilities kept" "drops all capabilities" \
  yqi "${D}[0].spec.template.spec.containers[0].securityContext.capabilities.drop = [\"NET_RAW\"]" "$CSV_FILE"
expect_fail "missing CPU limit" "CPU and memory requests and limits" \
  yqi "del(${D}[1].spec.template.spec.initContainers[0].resources.limits.cpu)" "$CSV_FILE"
expect_fail "missing memory request" "CPU and memory requests and limits" \
  yqi "del(${D}[0].spec.template.spec.containers[0].resources.requests.memory)" "$CSV_FILE"
expect_fail "missing probe" "readiness and liveness probes" \
  yqi "del(${D}[1].spec.template.spec.containers[0].readinessProbe)" "$CSV_FILE"
expect_fail "bootstrap script drift" "matches config/bootstrap/ar-bootstrap.py" \
  yqi '.data."ar-bootstrap.py" += "# changed\n"' manifests/envoy-operator-bootstrap_v1_configmap.yaml
expect_fail "wrong CSV name in bootstrap" "the bootstrap container knows the CSV name" \
  yqi "(${D}[1].spec.template.spec.initContainers[1].env[] | select(.name == \"CSV_NAME\")).value = \"other\"" "$CSV_FILE"
expect_fail "wrong namespace in bootstrap" "the bootstrap container knows the expected namespace" \
  yqi "(${D}[1].spec.template.spec.initContainers[1].env[] | select(.name == \"EXPECTED_NAMESPACE\")).value = \"other\"" "$CSV_FILE"
expect_fail "no service CA certificate" "comes from the OpenShift service CA" \
  yqi 'del(.metadata.annotations)' manifests/ai-gateway-controller_v1_service.yaml
expect_fail "wrong CSV version" "the CSV name and version match" yqi '.spec.version = "9.9.9"' "$CSV_FILE"
expect_fail "extra install mode" "supports only the AllNamespaces install mode" \
  yqi '(.spec.installModes[] | select(.type == "OwnNamespace")).supported = true' "$CSV_FILE"
expect_fail "suggested namespace" "the suggested namespace is" \
  yqi '.metadata.annotations."operatorframework.io/suggested-namespace" = "other"' "$CSV_FILE"
expect_fail "OpenShift versions" "the bundle supports OpenShift" \
  yqi '.annotations."com.redhat.openshift.versions" = "v4.12"' metadata/annotations.yaml
expect_fail "Dockerfile labels" "bundle.Dockerfile labels match" \
  yqi '.annotations."operators.operatorframework.io.bundle.channels.v1" = "other"' metadata/annotations.yaml
expect_fail "bundle too large" "the compressed manifests are smaller" \
  sh -c 'head -c 1000000 /dev/urandom | base64 >manifests/big.txt'

echo
[[ $failures -eq 0 ]] || fail "$failures gate test(s) failed"
echo "All gate tests passed."
