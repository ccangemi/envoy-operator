#!/usr/bin/env bash
# Offline checks on the generated bundle. They protect the rules that make the
# operator safe on OpenShift. The CI runs them on every pull request.
#
#   hack/bundle-gate.sh      (or: make bundle-gate)
#
# The script does not need a cluster or network access.

# shellcheck source=hack/lib.sh
source "$(dirname "$0")/lib.sh"
require_tools YQ

MANIFESTS=$BUNDLE_DIR/manifests
CSV=$MANIFESTS/$PACKAGE_NAME.clusterserviceversion.yaml
NS=$OPERATOR_NAMESPACE
CSV_NAME=$PACKAGE_NAME.v$OPERATOR_VERSION
# OLM stores the bundle in a config map, compressed. A config map holds at
# most 1 MiB, so keep a safety margin.
MAX_COMPRESSED_BYTES=${MAX_COMPRESSED_BYTES:-900000}

errors=0
check() {
  local description=$1
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'ok    %s\n' "$description"
  else
    printf 'FAIL  %s\n' "$description"
    errors=$((errors + 1))
  fi
}
not() { ! "$@"; }

[[ -f $CSV ]] || fail "no ClusterServiceVersion found at $CSV. Run 'make bundle' first."

# yq expression for all containers and init containers of all deployments.
ALL_CONTAINERS='.spec.install.spec.deployments[].spec.template.spec | (.containers[], .initContainers[])'

echo "Checking ${BUNDLE_DIR#"$ROOT_DIR"/} ($CSV_NAME)"

# --- CRDs ------------------------------------------------------------------
crd_groups() { "$YQ" -N 'select(.kind == "CustomResourceDefinition") | .spec.group' "$MANIFESTS"/*.yaml; }
only_allowed_groups() {
  local g
  for g in $(crd_groups); do [[ $g =~ $ALLOWED_CRD_GROUPS ]] || return 1; done
}
check "no Gateway API CRD (gateway.networking.k8s.io): OpenShift owns them" \
  not grep -qx 'gateway.networking.k8s.io' <(crd_groups)
check "no InferencePool CRD (inference.networking.*)" \
  not grep -q '^inference\.networking' <(crd_groups)
check "every CRD group is allowed ($ALLOWED_CRD_GROUPS)" only_allowed_groups

owned_match() {
  diff <("$YQ" -N '.spec.customresourcedefinitions.owned[].name' "$CSV" | sort) \
       <("$YQ" -N 'select(.kind == "CustomResourceDefinition") | .metadata.name' "$MANIFESTS"/*.yaml | sort)
}
check "the CSV owns exactly the CRDs in the bundle" owned_match

# --- Forbidden objects -------------------------------------------------------
forbidden_kinds() {
  "$YQ" -N '.kind' "$MANIFESTS"/*.yaml | grep -E -x \
    'Namespace|ValidatingAdmissionPolicy|ValidatingAdmissionPolicyBinding|MutatingWebhookConfiguration|ValidatingWebhookConfiguration|SecurityContextConstraints'
}
check "no Namespace, admission policy, webhook configuration or SCC in the bundle" not forbidden_kinds
check "the CSV defines no OLM webhooks (the bootstrap creates the webhook)" \
  "$YQ" -e '(.spec.webhookdefinitions // []) | length == 0' "$CSV"

# --- Envoy Gateway configuration --------------------------------------------
eg_config() {
  "$YQ" '.data."envoy-gateway.yaml"' "$MANIFESTS/envoy-gateway-config_v1_configmap.yaml"
}
check "Envoy Gateway has no provider.kubernetes.watch block" \
  not "$YQ" -e '.provider.kubernetes.watch' <(eg_config)
check "the Envoy Gateway topology injector is disabled" \
  "$YQ" -e '.proxyTopologyInjector.disabled == true' <(eg_config)
check "Envoy Gateway uses the GatewayNamespace or ControllerNamespace deploy type" \
  "$YQ" -e '.provider.kubernetes.deploy.type | test("^(GatewayNamespace|ControllerNamespace)$")' <(eg_config)
check "the extension manager points to the agent router in $NS" \
  env H="ai-gateway-controller.$NS.svc.cluster.local" \
  "$YQ" -e '.extensionManager.service.fqdn.hostname == strenv(H) and .extensionManager.service.fqdn.port == 1063' <(eg_config)
check "Envoy Gateway enables Backend and EnvoyPatchPolicy" \
  "$YQ" -e '.extensionApis.enableBackend and .extensionApis.enableEnvoyPatchPolicy' <(eg_config)

# --- Images ------------------------------------------------------------------
all_images() {
  "$YQ" -N "$ALL_CONTAINERS | .image" "$CSV"
  "$YQ" -N "$ALL_CONTAINERS | .args[]? | select(test(\"^--extProcImage=\")) | sub(\"^--extProcImage=\", \"\")" "$CSV"
  "$YQ" -N '.. | select(has("image")) | .image' <(eg_config)
}
images_pinned() {
  local i
  for i in $(all_images); do [[ $i == *@sha256:* ]] || { echo "not pinned: $i"; return 1; }; done
}
images_related() {
  local i
  for i in $(all_images); do
    I=$i "$YQ" -e '.spec.relatedImages[] | select(.image == strenv(I))' "$CSV" || { echo "not in relatedImages: $i"; return 1; }
  done
}
check "every image is pinned by digest" images_pinned
check "every image is listed in relatedImages" images_related
check "every related image is pinned by digest" \
  not "$YQ" -e '.spec.relatedImages[] | select(.image | test("@sha256:") | not)' "$CSV"

# --- Pod security and resources ----------------------------------------------
check "no fixed runAsUser, runAsGroup or fsGroup (restricted-v2 SCC)" \
  not "$YQ" -e '.spec.install.spec.deployments[].spec.template.spec | .. | select(has("runAsUser") or has("runAsGroup") or has("fsGroup"))' "$CSV"
check "every container drops all capabilities and disallows privilege escalation" \
  not "$YQ" -e "$ALL_CONTAINERS | select(.securityContext.allowPrivilegeEscalation != false or (.securityContext.capabilities.drop | contains([\"ALL\"]) | not))" "$CSV"
check "every container has CPU and memory requests and limits" \
  not "$YQ" -e "$ALL_CONTAINERS | select(.resources.requests.cpu == null or .resources.requests.memory == null or .resources.limits.cpu == null or .resources.limits.memory == null)" "$CSV"
check "every main container has readiness and liveness probes" \
  not "$YQ" -e '.spec.install.spec.deployments[].spec.template.spec.containers[] | select(.readinessProbe == null or .livenessProbe == null)' "$CSV"

# --- Agent router bootstrap --------------------------------------------------
bootstrap_in_sync() {
  diff <("$YQ" '.data."ar-bootstrap.py"' "$MANIFESTS/envoy-operator-bootstrap_v1_configmap.yaml") \
       "$ROOT_DIR/config/bootstrap/ar-bootstrap.py"
}
python_syntax() {
  python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$ROOT_DIR/config/bootstrap/ar-bootstrap.py"
}
check "the bootstrap script in the bundle matches config/bootstrap/ar-bootstrap.py" bootstrap_in_sync
check "the bootstrap script has valid Python syntax" python_syntax
BOOTSTRAP_ENV='.spec.install.spec.deployments[].spec.template.spec.initContainers[] | select(.name == "ar-bootstrap") | .env[]'
check "the bootstrap container knows the CSV name" \
  env C="$CSV_NAME" "$YQ" -e "$BOOTSTRAP_ENV"' | select(.name == "CSV_NAME" and .value == strenv(C))' "$CSV"
check "the bootstrap container knows the expected namespace" \
  env N="$NS" "$YQ" -e "$BOOTSTRAP_ENV"' | select(.name == "EXPECTED_NAMESPACE" and .value == strenv(N))' "$CSV"
check "the agent router serving certificate comes from the OpenShift service CA" \
  "$YQ" -e '.metadata.annotations."service.beta.openshift.io/serving-cert-secret-name" == "ai-gateway-controller-tls"' \
  "$MANIFESTS/ai-gateway-controller_v1_service.yaml"

# --- Versions and metadata ---------------------------------------------------
check "the CSV name and version match versions.env" \
  env C="$CSV_NAME" V="$OPERATOR_VERSION" "$YQ" -e '.metadata.name == strenv(C) and .spec.version == strenv(V)' "$CSV"
check "the CSV supports only the AllNamespaces install mode" \
  "$YQ" -e '[.spec.installModes[] | select(.supported) | .type] | join(",") == "AllNamespaces"' "$CSV"
check "the suggested namespace is $NS" \
  env N="$NS" "$YQ" -e '.metadata.annotations."operatorframework.io/suggested-namespace" == strenv(N)' "$CSV"
check "the bundle supports OpenShift $OPENSHIFT_VERSIONS" \
  env V="$OPENSHIFT_VERSIONS" "$YQ" -e '.annotations."com.redhat.openshift.versions" == strenv(V)' "$BUNDLE_DIR/metadata/annotations.yaml"
labels_match() {
  diff <("$YQ" '.annotations | to_entries | .[] | "LABEL " + .key + "=" + .value' "$BUNDLE_DIR/metadata/annotations.yaml") \
       <(grep '^LABEL ' "$ROOT_DIR/bundle.Dockerfile")
}
check "bundle.Dockerfile labels match metadata/annotations.yaml" labels_match

# --- Size --------------------------------------------------------------------
compressed_size() {
  local f total=0
  for f in "$MANIFESTS"/*; do total=$((total + $(gzip -9 -c "$f" | wc -c))); done
  echo "$total"
}
size=$(compressed_size)
check "the compressed manifests are smaller than $MAX_COMPRESSED_BYTES bytes ($size bytes)" \
  test "$size" -lt "$MAX_COMPRESSED_BYTES"

echo
if [[ $errors -gt 0 ]]; then
  fail "$errors check(s) failed"
fi
echo "All checks passed."
