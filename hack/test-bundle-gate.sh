#!/usr/bin/env bash
# Tests for hack/bundle-gate.sh. Each test copies the bundle and the operator
# chart, breaks one rule, and expects the gate to fail with the matching
# check. This makes sure that no check passes by mistake (for example because
# of a wrong yq expression).
#
#   hack/test-bundle-gate.sh      (or: make test-gate)

# shellcheck source=hack/lib.sh
source "$(dirname "$0")/lib.sh"
require_tools YQ HELM

CSV_FILE=manifests/$PACKAGE_NAME.clusterserviceversion.yaml
CRD_FILE=manifests/${CR_GROUP}_$(tr '[:upper:]' '[:lower:]' <<<"$CR_KIND")s.yaml
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
# expect_fail <name> <text of the check that must fail> <mutation command...>
# The mutation command runs in a directory with copies of the bundle
# (bundle/), the operator chart (chart/), watches.yaml and related-images.yaml.
expect_fail() {
  local name=$1 expected=$2 output
  shift 2
  rm -rf "$work/copy" && mkdir -p "$work/copy/helm-charts"
  cp -r "$BUNDLE_DIR" "$work/copy/bundle"
  cp -r "$CHART_DIR" "$work/copy/helm-charts/envoy-gateway"
  ln -s helm-charts/envoy-gateway "$work/copy/chart"
  cp "$ROOT_DIR/watches.yaml" "$ROOT_DIR/config/manifests/related-images.yaml" "$work/copy/"
  (cd "$work/copy" && "$@") || { echo "ERROR  $name: the mutation failed"; failures=$((failures + 1)); return; }
  if output=$(BUNDLE_DIR=$work/copy/bundle CHART_DIR=$work/copy/helm-charts/envoy-gateway \
    WATCHES_FILE=$work/copy/watches.yaml RELATED_IMAGES_FILE=$work/copy/related-images.yaml \
    "$ROOT_DIR/hack/bundle-gate.sh" 2>&1); then
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

# Helpers that the mutations use. They run inside the copy.
yqi() { "$YQ" -i "$@"; }
add_crd() {
  "$YQ" ".spec.group = \"$1\" | .metadata.name = \"tests.$1\"" bundle/manifests/gateway.envoyproxy.io_backends.yaml \
    >"bundle/manifests/$1_tests.yaml"
}
add_namespace() { printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: test\n' >bundle/manifests/test_v1_namespace.yaml; }
add_rule() { yqi ".spec.install.spec.clusterPermissions[0].rules += [$1]" "bundle/$CSV_FILE"; }
values_edit() { yqi "$1" chart/values.yaml; }

# Make sure that the unchanged copies pass, so that a failure below has a
# clear cause.
expect_pass() {
  BUNDLE_DIR=$BUNDLE_DIR "$ROOT_DIR/hack/bundle-gate.sh" >/dev/null || fail "the gate fails on the unchanged bundle"
}
expect_pass

D=".spec.install.spec.deployments"
B="bundle/$CSV_FILE"
# CRDs
expect_fail "Gateway API CRD" "no Gateway API CRD" add_crd gateway.networking.k8s.io
expect_fail "experimental Gateway API CRD" "no Gateway API CRD" add_crd gateway.networking.x-k8s.io
expect_fail "InferencePool CRD" "no InferencePool CRD" add_crd inference.networking.k8s.io
expect_fail "unknown CRD group" "every CRD group is allowed" add_crd example.com
expect_fail "owned CRD without file" "the CSV owns exactly the CRDs" rm bundle/manifests/gateway.envoyproxy.io_backends.yaml
expect_fail "no Envoy Gateway CRDs" "the bundle has Envoy Gateway CRDs" sh -c 'rm bundle/manifests/gateway.envoyproxy.io_*.yaml'
expect_fail "no CRD of the custom resource" "the bundle has the CRD of" rm "bundle/$CRD_FILE"
expect_fail "custom resource name not enforced" "allows only the name" \
  yqi 'del(.spec.versions[].schema.openAPIV3Schema.x-kubernetes-validations)' "bundle/$CRD_FILE"
expect_fail "empty values possible" "never sends empty values to Helm" \
  yqi 'del(.spec.versions[].schema.openAPIV3Schema.properties.spec.properties)' "bundle/$CRD_FILE"
# Forbidden objects
expect_fail "Namespace object" "no Namespace, admission policy" add_namespace
expect_fail "OLM webhook" "the CSV defines no OLM webhooks" \
  yqi '.spec.webhookdefinitions = [{"generateName": "x", "type": "MutatingAdmissionWebhook"}]' "$B"
# Permissions
expect_fail "permission on CRDs" "no permission on CRDs" \
  add_rule '{"apiGroups": ["apiextensions.k8s.io"], "resources": ["customresourcedefinitions"], "verbs": ["create"]}'
expect_fail "permission on all API groups" "no permission on CRDs" \
  add_rule '{"apiGroups": ["*"], "resources": ["*"], "verbs": ["get"]}'
expect_fail "permission on SCCs" "no permission on security context constraints" \
  add_rule '{"apiGroups": ["security.openshift.io"], "resources": ["securitycontextconstraints"], "verbs": ["use"]}'
# Operator chart
expect_fail "other chart in watches.yaml" "watches.yaml installs helm-charts/envoy-gateway" \
  yqi '.[0].chart = "helm-charts/gateway-helm"' watches.yaml
expect_fail "client dry run" "watches.yaml installs helm-charts/envoy-gateway" yqi 'del(.[0].dryRunOption)' watches.yaml
expect_fail "overrideValues" "watches.yaml has no overrideValues" \
  yqi '.[0].overrideValues = {"gateway-helm.crds.enabled": "false"}' watches.yaml
expect_fail "chart does not render" "the chart renders with the default values" \
  values_edit '."gateway-helm".crds.enabled = true'
expect_fail "Gateway API CRDs on by default" "the chart renders no CRD" \
  sh -c "rm chart/templates/validate.yaml && $YQ -i '.\"gateway-helm\".crds.enabled = true' chart/values.yaml"
expect_fail "fixed user ID" "no fixed runAsUser" values_edit 'del(."gateway-helm".deployment.pod.securityContext.runAsUser)'
expect_fail "fixed fsGroup in certgen" "no fixed runAsUser" values_edit 'del(."gateway-helm".certgen.job.pod.securityContext.fsGroup)'
expect_fail "CRDs not refused" "refuses gateway-helm.crds.enabled=true" rm chart/templates/validate.yaml
expect_fail "namespaceOverride not refused" "refuses a namespaceOverride" \
  sed -i '/namespaceOverride/,+4d' chart/templates/validate.yaml
expect_fail "chart version" "the chart versions match versions.env" yqi '.version = "9.9.9"' chart/Chart.yaml
expect_fail "dependency version" "the chart versions match versions.env" yqi '.dependencies[0].version = "v0.0.1"' chart/Chart.yaml
expect_fail "chart image by tag" "the images of the chart are pinned" \
  values_edit '."gateway-helm".global.images.envoyGateway.image = "docker.io/envoyproxy/gateway:v1.9.3"'
expect_fail "chart image not related" "the images of the chart are pinned" \
  values_edit '."gateway-helm".global.images.ratelimit.image = "docker.io/x/y:1@sha256:0000"'
# Images
expect_fail "related images differ" "relatedImages lists the images" \
  yqi '.spec.relatedImages += [{"name": "x", "image": "docker.io/x/y@sha256:0000"}]' "$B"
expect_fail "related image by tag" "every operand image in relatedImages is pinned" \
  sh -c "$YQ -i '.spec.relatedImages[1].image = \"docker.io/x/y:1\"' $B && $YQ -i '.[0].image = \"docker.io/x/y:1\"' related-images.yaml"
expect_fail "operator image not related" "the operator image is the containerImage" \
  yqi "(${D}[0].spec.template.spec.containers[] | select(.name == \"manager\") | .image) = \"example.com/other:1\"" "$B"
# The operator pod
expect_fail "fixed user ID in the operator" "no fixed runAsUser, runAsGroup or fsGroup in the operator pod" \
  yqi "${D}[0].spec.template.spec.securityContext.runAsUser = 1000" "$B"
expect_fail "privilege escalation" "drops all capabilities" \
  yqi "${D}[0].spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation = true" "$B"
expect_fail "capabilities kept" "drops all capabilities" \
  yqi "${D}[0].spec.template.spec.containers[0].securityContext.capabilities.drop = [\"NET_RAW\"]" "$B"
expect_fail "missing memory limit" "CPU and memory requests and limits" \
  yqi "del(${D}[0].spec.template.spec.containers[0].resources.limits.memory)" "$B"
expect_fail "missing probe" "readiness and liveness probes" \
  yqi "del(${D}[0].spec.template.spec.containers[0].livenessProbe)" "$B"
expect_fail "all namespaces" "WATCH_NAMESPACE" yqi "del(${D}[0].spec.template.spec.containers[0].env)" "$B"
# Versions and metadata
expect_fail "wrong CSV version" "the CSV name and version match" yqi '.spec.version = "9.9.9"' "$B"
expect_fail "extra install mode" "supports only the OwnNamespace install mode" \
  yqi '(.spec.installModes[] | select(.type == "AllNamespaces")).supported = true' "$B"
expect_fail "suggested namespace" "the suggested namespace is" \
  yqi '.metadata.annotations."operatorframework.io/suggested-namespace" = "other"' "$B"
expect_fail "example with another name" "the examples have one" \
  yqi '.metadata.annotations."alm-examples" = "[]"' "$B"
expect_fail "OpenShift versions" "the bundle supports OpenShift" \
  yqi '.annotations."com.redhat.openshift.versions" = "v4.12"' bundle/metadata/annotations.yaml
expect_fail "Dockerfile labels" "bundle.Dockerfile labels match" \
  yqi '.annotations."operators.operatorframework.io.bundle.channels.v1" = "other"' bundle/metadata/annotations.yaml
expect_fail "bundle too large" "the compressed manifests are smaller" \
  sh -c 'head -c 1000000 /dev/urandom | base64 >bundle/manifests/big.txt'

echo
[[ $failures -eq 0 ]] || fail "$failures gate test(s) failed"
echo "All gate tests passed."
