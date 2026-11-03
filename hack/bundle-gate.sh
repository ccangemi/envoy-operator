#!/usr/bin/env bash
# Offline checks on the bundle and on the operator chart. They protect the
# rules that make the operator safe on OpenShift. The CI runs them on every
# pull request.
#
#   hack/bundle-gate.sh      (or: make bundle-gate)
#
# REQUIRE_PINNED_OPERATOR_IMAGE=true also requires the operator image to be
# pinned by digest; the release workflow sets it. The script needs no cluster
# and no network access.

# shellcheck source=hack/lib.sh
source "$(dirname "$0")/lib.sh"
require_tools YQ HELM

MANIFESTS=$BUNDLE_DIR/manifests
CSV=$MANIFESTS/$PACKAGE_NAME.clusterserviceversion.yaml
CSV_NAME=$PACKAGE_NAME.v$OPERATOR_VERSION
WATCHES_FILE=${WATCHES_FILE:-$ROOT_DIR/watches.yaml}
RELATED_IMAGES_FILE=${RELATED_IMAGES_FILE:-$ROOT_DIR/config/manifests/related-images.yaml}
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
# none <yq expression> <file...>: true when the expression matches nothing.
# It counts the matches, so a yq error (for example on a missing field) is a
# failure and never a silent pass.
none() {
  local expr=$1 n
  shift
  n=$("$YQ" ea -N "[$expr] | length" "$@") || return 1
  [[ $n == 0 ]]
}
# some <yq expression> <file...>: true when the expression matches at least
# once.
some() {
  local expr=$1 n
  shift
  n=$("$YQ" ea -N "[$expr] | length" "$@") || return 1
  [[ $n -gt 0 ]]
}

[[ -f $CSV ]] || fail "no ClusterServiceVersion found at $CSV. Run 'make bundle' first."

echo "Checking ${BUNDLE_DIR#"$ROOT_DIR"/} ($CSV_NAME) and ${CHART_DIR#"$ROOT_DIR"/}"

# --- CRDs ------------------------------------------------------------------
CRDS='select(.kind == "CustomResourceDefinition")'
check "the bundle has the CRD of $CR_KIND" some "$CRDS | select(.spec.group == \"$CR_GROUP\")" "$MANIFESTS"/*.yaml
check "the bundle has Envoy Gateway CRDs" some "$CRDS | select(.spec.group == \"gateway.envoyproxy.io\")" "$MANIFESTS"/*.yaml
check "no Gateway API CRD (gateway.networking.k8s.io, gateway.networking.x-k8s.io): OpenShift owns them" \
  none "$CRDS | select(.spec.group | test(\"^gateway\\.networking\\.(x-)?k8s\\.io$\"))" "$MANIFESTS"/*.yaml
check "no InferencePool CRD (inference.networking.*)" \
  none "$CRDS | select(.spec.group | test(\"^inference\\.networking\"))" "$MANIFESTS"/*.yaml
check "every CRD group is allowed ($ALLOWED_CRD_GROUPS)" \
  env G="$ALLOWED_CRD_GROUPS" "$YQ" ea -N -e "[$CRDS | select(.spec.group | test(strenv(G)) | not)] | length == 0" "$MANIFESTS"/*.yaml
owned_match() {
  diff <("$YQ" -N '.spec.customresourcedefinitions.owned[].name' "$CSV" | sort) \
       <("$YQ" -N 'select(.kind == "CustomResourceDefinition") | .metadata.name' "$MANIFESTS"/*.yaml | sort)
}
check "the CSV owns exactly the CRDs in the bundle" owned_match
check "the CRD of $CR_KIND allows only the name $CR_NAME" \
  env R="self.metadata.name == '$CR_NAME'" "$YQ" ea -N -e \
  "[$CRDS | select(.spec.group == \"$CR_GROUP\") | .spec.versions[].schema.openAPIV3Schema.x-kubernetes-validations[] | select(.rule == strenv(R))] | length > 0" \
  "$MANIFESTS"/*.yaml
# Both defaults are needed: spec defaults to {} when the resource has no
# spec, and spec.gateway-helm defaults to {} inside it.
empty_defaults() {
  local schemas
  schemas=$("$YQ" ea -N -o json -I0 "[$CRDS | select(.spec.group == \"$CR_GROUP\") | .spec.versions[].schema.openAPIV3Schema.properties.spec]" \
    "$MANIFESTS"/*.yaml) || return 1
  K="gateway-helm" "$YQ" -p json -e '[(length > 0), (map([
      ((.default // "x") | tag == "!!map"), ((.default // "x") | length == 0),
      ((.properties[strenv(K)].default // "x") | tag == "!!map"), ((.properties[strenv(K)].default // "x") | length == 0)
    ] | all) | all)] | all' <<<"$schemas"
}
check "the CRD of $CR_KIND never sends empty values to Helm (spec and spec.gateway-helm default to {})" empty_defaults

# --- Forbidden objects -------------------------------------------------------
FORBIDDEN='select(.kind | test("^(Namespace|ValidatingAdmissionPolicy|ValidatingAdmissionPolicyBinding|MutatingWebhookConfiguration|ValidatingWebhookConfiguration|SecurityContextConstraints)$"))'
check "no Namespace, admission policy, webhook configuration or SCC in the bundle" \
  none "$FORBIDDEN" "$MANIFESTS"/*.yaml
check "the CSV defines no OLM webhooks" "$YQ" -e '(.spec.webhookdefinitions // []) | length == 0' "$CSV"

# --- Permissions of the operator ---------------------------------------------
RULES='.spec.install.spec | (.clusterPermissions // [], .permissions // [])[] | .rules[]'
check "the operator has no permission on CRDs (it can never change the Gateway API CRDs)" \
  none "$RULES | select(.apiGroups[] | test(\"^(apiextensions\\.k8s\\.io|\\*)$\"))" "$CSV"
check "the operator has no permission on security context constraints" \
  none "$RULES | select((.apiGroups[] == \"security.openshift.io\") or (.resources[] == \"securitycontextconstraints\"))" "$CSV"

# --- Operator chart ----------------------------------------------------------
# render [helm arguments...]: renders the operator chart with the CRDs.
render() { "$HELM" template "$CR_NAME" "$CHART_DIR" --namespace "$OPERATOR_NAMESPACE" --include-crds "${RENDER_ARGS[@]}" "$@" 2>&1; }
# refuses <helm arguments...>: true when templates/validate.yaml stops the render.
refuses() {
  local out
  if out=$(render "$@"); then return 1; fi
  grep -q 'validate.yaml' <<<"$out"
}
watches_ok() {
  "$YQ" -e '[(length == 1), (.[0].chart == "helm-charts/envoy-gateway"), (.[0].dryRunOption == "server")] | all' "$WATCHES_FILE" &&
    [[ $CHART_DIR == */helm-charts/envoy-gateway ]]
}
check "watches.yaml installs helm-charts/envoy-gateway with dryRunOption server" watches_ok
check "watches.yaml has no overrideValues (helm-operator passes them as strings)" \
  "$YQ" -e '(.[0].overrideValues // {}) | length == 0' "$WATCHES_FILE"
rendered=$(mktemp)
trap 'rm -f "$rendered"' EXIT
render >"$rendered" || true
check "the chart renders with the default values" "$YQ" -e '[select(.kind == "Deployment")] | length > 0' "$rendered"
check "the chart renders no CRD, admission policy, webhook or Namespace by default" \
  none 'select(.kind | test("^(CustomResourceDefinition|Namespace|ValidatingAdmissionPolicy|ValidatingAdmissionPolicyBinding|MutatingWebhookConfiguration|ValidatingWebhookConfiguration)$"))' "$rendered"
check "the chart renders no fixed runAsUser, runAsGroup or fsGroup (restricted-v2 SCC)" \
  none '.. | select(tag == "!!map") | select(has("runAsUser") or has("runAsGroup") or has("fsGroup"))' "$rendered"
check "the chart refuses gateway-helm.crds.enabled=true" refuses --set gateway-helm.crds.enabled=true
check "the chart refuses gateway-helm.createNamespace=true" refuses --set gateway-helm.createNamespace=true
check "the chart refuses a namespaceOverride" refuses --set gateway-helm.namespaceOverride=other
check "the chart refuses a provider.kubernetes.watch block" \
  refuses --set gateway-helm.config.envoyGateway.provider.kubernetes.watch.type=Namespaces
versions_match() {
  V=$OPERATOR_VERSION C=$CHART_VERSION N=$CHART_NAME "$YQ" -e '[(.version == strenv(V)), (.appVersion == strenv(C)),
    ([.dependencies[] | select(.name == strenv(N)) | select(.version == strenv(C))] | length == 1)] | all' "$CHART_DIR/Chart.yaml" &&
    C=$CHART_VERSION "$YQ" -e '.version == strenv(C)' "$CHART_DIR/charts/$CHART_NAME/Chart.yaml"
}
check "the chart versions match versions.env (operator $OPERATOR_VERSION, $CHART_NAME $CHART_VERSION)" versions_match
rendered_images_related() {
  local i images
  images=$(rendered_images "$rendered" | sort -u) || return 1
  [[ -n $images ]] || return 1
  for i in $images; do
    [[ $i == *@sha256:* ]] || { echo "not pinned: $i"; return 1; }
    I=$i "$YQ" -e '.[] | select(.image == strenv(I))' "$RELATED_IMAGES_FILE" || { echo "not in related-images.yaml: $i"; return 1; }
  done
}
check "every image of the rendered chart is pinned by digest and listed in related-images.yaml" rendered_images_related

# --- Images ------------------------------------------------------------------
related_match() {
  diff <("$YQ" -N '.[].image' "$RELATED_IMAGES_FILE" | sort) \
       <("$YQ" -N '.spec.relatedImages[] | select(.name != "operator") | .image' "$CSV" | sort)
}
check "relatedImages lists the images of related-images.yaml" related_match
operator_image_ok() {
  local image
  image=$("$YQ" -N '.spec.install.spec.deployments[0].spec.template.spec.containers[] | select(.name == "manager") | .image' "$CSV")
  [[ -n $image ]] &&
    I=$image "$YQ" -e '[(.metadata.annotations.containerImage == strenv(I)),
      ([.spec.relatedImages[] | select(.name == "operator") | select(.image == strenv(I))] | length == 1)] | all' "$CSV" &&
    if [[ ${REQUIRE_PINNED_OPERATOR_IMAGE:-false} == true ]]; then [[ $image == *@sha256:* ]]; fi
}
check "the operator image is the containerImage and a related image" operator_image_ok
check "every operand image in relatedImages is pinned by digest" \
  none '.spec.relatedImages[] | select(.name != "operator") | select(.image | test("@sha256:") | not)' "$CSV"

# --- The operator pod ----------------------------------------------------------
CONTAINERS='.spec.install.spec.deployments[].spec.template.spec | (.containers[], .initContainers[])'
check "no fixed runAsUser, runAsGroup or fsGroup in the operator pod" \
  none '.spec.install.spec.deployments[].spec.template.spec | .. | select(tag == "!!map") | select(has("runAsUser") or has("runAsGroup") or has("fsGroup"))' "$CSV"
check "every container drops all capabilities and disallows privilege escalation" \
  none "$CONTAINERS | select(.securityContext.allowPrivilegeEscalation != false or (((.securityContext.capabilities.drop // []) | contains([\"ALL\"])) | not))" "$CSV"
check "every container has CPU and memory requests and limits" \
  none "$CONTAINERS | select(.resources.requests.cpu == null or .resources.requests.memory == null or .resources.limits.cpu == null or .resources.limits.memory == null)" "$CSV"
check "every container has readiness and liveness probes" \
  none '.spec.install.spec.deployments[].spec.template.spec.containers[] | select(.readinessProbe == null or .livenessProbe == null)' "$CSV"
check "the operator watches only the namespaces that OLM gives it (WATCH_NAMESPACE)" \
  some '.spec.install.spec.deployments[].spec.template.spec.containers[] | select(.name == "manager") | .env[]
    | select(.name == "WATCH_NAMESPACE" and .valueFrom.fieldRef.fieldPath == "metadata.annotations['"'"'olm.targetNamespaces'"'"']")' "$CSV"

# --- Versions and metadata ---------------------------------------------------
check "the CSV name and version match versions.env" \
  env C="$CSV_NAME" V="$OPERATOR_VERSION" "$YQ" -e '[(.metadata.name == strenv(C)), (.spec.version == strenv(V))] | all' "$CSV"
check "the CSV supports only the OwnNamespace install mode" \
  "$YQ" -e '[.spec.installModes[] | select(.supported) | .type] | join(",") == "OwnNamespace"' "$CSV"
check "the suggested namespace is $OPERATOR_NAMESPACE" \
  env N="$OPERATOR_NAMESPACE" "$YQ" -e '.metadata.annotations."operatorframework.io/suggested-namespace" == strenv(N)' "$CSV"
check "the examples have one $CR_KIND named $CR_NAME" \
  env K="$CR_KIND" N="$CR_NAME" "$YQ" -e '[.metadata.annotations."alm-examples" | from_json | .[] | select(.kind == strenv(K) and .metadata.name == strenv(N))] | length == 1' "$CSV"
check "the bundle supports OpenShift $OPENSHIFT_VERSIONS" \
  env V="$OPENSHIFT_VERSIONS" "$YQ" -e '.annotations."com.redhat.openshift.versions" == strenv(V)' "$BUNDLE_DIR/metadata/annotations.yaml"
labels_match() {
  diff <("$YQ" '.annotations | to_entries | .[] | "LABEL " + .key + "=" + .value' "$BUNDLE_DIR/metadata/annotations.yaml" | sort) \
       <(grep '^LABEL ' "$ROOT_DIR/bundle.Dockerfile" | sort)
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
