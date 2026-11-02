#!/usr/bin/env bash
# Generates the OLM bundle in bundle/ from the upstream Helm charts.
#
#   hack/generate-bundle.sh      (or: make bundle)
#
# Inputs:
#   versions.env                     upstream versions and operator version
#   config/values/*.yaml             values for rendering the upstream charts
#   config/manifests/csv-template.yaml
#   config/manifests/icon.svg
#   config/bootstrap/ar-bootstrap.py
#   samples/ocp/40-gateway.yaml      source of the alm-examples annotation
#
# The script needs network access: it pulls the charts from Docker Hub and
# resolves every image tag to a digest.
#
# What the script changes compared to the upstream charts, and why:
#   - No Gateway API CRDs and no ValidatingAdmissionPolicy. OpenShift owns the
#     Gateway API CRDs.
#   - No InferencePool CRDs. OpenShift AI (KServe) owns them on many clusters.
#   - No fixed user and group IDs, so the controllers run with the
#     restricted-v2 SCC.
#   - The certgen Job becomes an init container of the agent router pod. OLM
#     cannot run Jobs. It cannot run in the Envoy Gateway pod either, because
#     that pod mounts the secret that certgen creates.
#   - A bootstrap init container creates the agent router webhook
#     configuration. See config/bootstrap/ar-bootstrap.py.
#   - Every image is pinned by digest.

# The JSON strings below are passed to yq through the environment on purpose.
# shellcheck disable=SC2089,SC2090

# shellcheck source=hack/lib.sh
source "$(dirname "$0")/lib.sh"
require_tools HELM YQ

NS=$OPERATOR_NAMESPACE
CSV_NAME=$PACKAGE_NAME.v$OPERATOR_VERSION
OCI=oci://docker.io/envoyproxy
MANIFESTS=$BUNDLE_DIR/manifests
METADATA=$BUNDLE_DIR/metadata

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Common labels for every object that the bundle creates.
PART_OF=$PACKAGE_NAME

pull() {
  log "pulling $1 $2"
  "$HELM" pull "$OCI/$1" --version "$2" --untar --untardir "$work/charts" >/dev/null 2>&1 \
    || fail "cannot pull $OCI/$1 $2"
}
pull gateway-helm "$EG_VERSION"
pull gateway-crds-helm "$EG_VERSION"
pull ai-gateway-helm "$AR_VERSION"
pull ai-gateway-crds-helm "$AR_VERSION"

# ---------------------------------------------------------------------------
# Images
# ---------------------------------------------------------------------------
log "resolving image digests"
EG_IMAGE=$(pin "docker.io/envoyproxy/gateway:$EG_VERSION")
AR_IMAGE=$(pin "docker.io/envoyproxy/ai-gateway-controller:$AR_VERSION")
EXTPROC_IMAGE=$(pin "docker.io/envoyproxy/ai-gateway-extproc:$AR_VERSION")
BOOTSTRAP_IMAGE_PINNED=$(pin "$BOOTSTRAP_IMAGE")
RATELIMIT_TAG=$("$YQ" '.global.images.ratelimit.image' "$work/charts/gateway-helm/values.yaml")
RATELIMIT_IMAGE=$(pin "$RATELIMIT_TAG")
# The default Envoy proxy image is compiled into Envoy Gateway, already pinned
# by digest. It is listed in relatedImages so that mirroring tools copy it.
PROXY_IMAGE=$(curl -sSfL --retry 3 \
  "https://raw.githubusercontent.com/envoyproxy/gateway/$EG_VERSION/api/v1alpha1/shared_types.go" \
  | sed -nE 's/^\s*DefaultEnvoyProxyImage\s*=\s*"([^"]+)".*/\1/p')
[[ $PROXY_IMAGE == *@sha256:* ]] || fail "cannot find the default Envoy proxy image of Envoy Gateway $EG_VERSION"
# Keep only repository@digest, like the other images.
PROXY_IMAGE="${PROXY_IMAGE%%:*}@${PROXY_IMAGE##*@}"
export EG_IMAGE AR_IMAGE EXTPROC_IMAGE BOOTSTRAP_IMAGE_PINNED RATELIMIT_IMAGE PROXY_IMAGE

# ---------------------------------------------------------------------------
# CRDs
# ---------------------------------------------------------------------------
rm -rf "$BUNDLE_DIR"
mkdir -p "$MANIFESTS" "$METADATA" "$work/crds"

log "rendering the Envoy Gateway CRDs (without the Gateway API CRDs)"
"$HELM" template eg-crds "$work/charts/gateway-crds-helm" \
  --set crds.gatewayAPI.enabled=false --set crds.envoyGateway.enabled=true \
  >"$work/crds/eg.yaml"

# ai-gateway-crds-helm keeps its CRDs in templates/ as plain YAML. Refuse to
# copy them if that is no longer true.
if grep -l '{{' "$work"/charts/ai-gateway-crds-helm/templates/*.yaml; then
  fail "ai-gateway-crds-helm $AR_VERSION has templated CRDs; render them instead of copying them"
fi
cat "$work"/charts/ai-gateway-crds-helm/templates/*.yaml >"$work/crds/ar.yaml"

# One file per CRD, named <group>_<plural>.yaml like operator-sdk does. Helm
# labels are removed: OLM owns these CRDs, not Helm.
(cd "$MANIFESTS" && "$YQ" -s '.spec.group + "_" + .spec.names.plural + ".yaml"' \
  'select(.kind == "CustomResourceDefinition")
   | del(.metadata.labels."helm.sh/chart", .metadata.labels."app.kubernetes.io/managed-by",
         .metadata.labels."app.kubernetes.io/instance", .metadata.annotations."helm.sh/resource-policy")
   | del(.metadata.labels | select(length == 0))
   | del(.metadata.annotations | select(length == 0))' \
  "$work/crds/eg.yaml" "$work/crds/ar.yaml")

for f in "$MANIFESTS"/*.yaml; do
  # One document per file, without separators, comments or empty documents.
  "$YQ" -N 'select(.kind == "CustomResourceDefinition") | ... comments = ""' "$f" >"$work/crd.yaml"
  mv "$work/crd.yaml" "$f"
  group=$("$YQ" '.spec.group' "$f")
  [[ $group =~ $ALLOWED_CRD_GROUPS ]] || fail "$(basename "$f"): CRD group $group is not allowed in the bundle"
done

# ---------------------------------------------------------------------------
# Render the controllers
# ---------------------------------------------------------------------------
log "rendering gateway-helm $EG_VERSION and ai-gateway-helm $AR_VERSION"
sed "s/OPERATOR_NAMESPACE/$NS/g" "$ROOT_DIR/config/values/gateway-helm.yaml" >"$work/eg-values.yaml"
sed "s/OPERATOR_NAMESPACE/$NS/g" "$ROOT_DIR/config/values/ai-gateway-helm.yaml" >"$work/ar-values.yaml"
"$HELM" template envoy-gateway "$work/charts/gateway-helm" -n "$NS" -f "$work/eg-values.yaml" >"$work/eg.yaml"
"$HELM" template ai-gateway "$work/charts/ai-gateway-helm" -n "$NS" -f "$work/ar-values.yaml" >"$work/ar.yaml"

if "$YQ" -e 'select(.kind == "CustomResourceDefinition" or .kind == "ValidatingAdmissionPolicy"
              or .kind == "ValidatingAdmissionPolicyBinding" or .kind == "Namespace")' \
  "$work/eg.yaml" "$work/ar.yaml" >/dev/null 2>&1; then
  fail "the rendered charts contain CRDs, admission policies or namespaces; check config/values/"
fi

# rules_for <rendered file> <service account> <ClusterRoleBinding|RoleBinding>
# prints the rules of all roles bound to the service account, as a YAML list.
rules_for() {
  local file=$1 sa=$2 binding=$3 role_kind=ClusterRole names name
  [[ $binding == RoleBinding ]] && role_kind=Role
  names=$(SA=$sa "$YQ" -N "select(.kind == \"$binding\")
    | select(.subjects | any_c(.kind == \"ServiceAccount\" and .name == strenv(SA)))
    | select(.roleRef.kind == \"$role_kind\") | .roleRef.name" "$file")
  {
    echo "[]"
    for name in $names; do
      echo "---"
      N=$name "$YQ" -N "select(.kind == \"$role_kind\" and .metadata.name == strenv(N)) | .rules" "$file"
    done
  } | "$YQ" ea '[.[]] | flatten(1)'
}

rules_for "$work/eg.yaml" envoy-gateway ClusterRoleBinding >"$work/eg-cluster-rules.yaml"
rules_for "$work/ar.yaml" envoy-gateway ClusterRoleBinding >"$work/eg-cluster-rules-from-ar.yaml"
rules_for "$work/eg.yaml" envoy-gateway RoleBinding >"$work/eg-rules.yaml"
rules_for "$work/eg.yaml" envoy-gateway-certgen RoleBinding >"$work/certgen-rules.yaml"
rules_for "$work/ar.yaml" ai-gateway-controller ClusterRoleBinding >"$work/ar-cluster-rules.yaml"

for f in eg-cluster-rules eg-rules certgen-rules ar-cluster-rules; do
  [[ $("$YQ" 'length' "$work/$f.yaml") -gt 0 ]] || fail "no RBAC rules found for $f; did the upstream chart change?"
done

# The bootstrap init container creates the webhook configuration and reads
# the cluster roles that OLM creates for this operator (see the script).
cat >"$work/ar-bootstrap-rules.yaml" <<'EOF'
- apiGroups: [admissionregistration.k8s.io]
  resources: [mutatingwebhookconfigurations]
  verbs: [create]
- apiGroups: [rbac.authorization.k8s.io]
  resources: [clusterroles]
  verbs: [get, list]
EOF

# ---------------------------------------------------------------------------
# Envoy Gateway configuration
# ---------------------------------------------------------------------------
log "writing the Envoy Gateway configuration"
"$YQ" 'select(.kind == "ConfigMap" and .metadata.name == "envoy-gateway-config") | .data."envoy-gateway.yaml"' \
  "$work/eg.yaml" >"$work/eg-config.yaml"
"$YQ" -i '
  .provider.kubernetes.rateLimitDeployment.container.image = strenv(RATELIMIT_IMAGE)
  | .provider.kubernetes.shutdownManager.image = strenv(EG_IMAGE)' "$work/eg-config.yaml"
"$YQ" -e '.provider.kubernetes.watch' "$work/eg-config.yaml" >/dev/null 2>&1 \
  && fail "the Envoy Gateway configuration must not contain provider.kubernetes.watch"
"$YQ" -e '.proxyTopologyInjector.disabled == true' "$work/eg-config.yaml" >/dev/null \
  || fail "the Envoy Gateway topology injector must be disabled"

EG_CONFIG=$(cat "$work/eg-config.yaml") PART_OF=$PART_OF "$YQ" -n '
  .apiVersion = "v1"
  | .kind = "ConfigMap"
  | .metadata.name = "envoy-gateway-config"
  | .metadata.labels."app.kubernetes.io/name" = "envoy-gateway"
  | .metadata.labels."app.kubernetes.io/part-of" = strenv(PART_OF)
  | .data."envoy-gateway.yaml" = strenv(EG_CONFIG)' >"$MANIFESTS/envoy-gateway-config_v1_configmap.yaml"

# ---------------------------------------------------------------------------
# Services and other namespaced objects
# ---------------------------------------------------------------------------
log "writing services and config maps"
EG_SELECTOR='{"app.kubernetes.io/name": "envoy-gateway", "control-plane": "envoy-gateway"}'
AR_SELECTOR='{"app.kubernetes.io/name": "ai-gateway-controller"}'
export EG_SELECTOR AR_SELECTOR PART_OF

"$YQ" 'select(.kind == "Service" and .metadata.name == "envoy-gateway")
  | .metadata = {"name": "envoy-gateway",
                 "labels": {"app.kubernetes.io/name": "envoy-gateway",
                            "control-plane": "envoy-gateway",
                            "app.kubernetes.io/part-of": strenv(PART_OF)}}
  | .spec.selector = (strenv(EG_SELECTOR) | from_yaml)
  | (.. | select(tag == "!!map" or tag == "!!seq")) style = "" | (... | select(tag == "!!str")) style = "" | ... comments = ""' \
  "$work/eg.yaml" >"$MANIFESTS/envoy-gateway_v1_service.yaml"

# The OpenShift service CA creates the secret ai-gateway-controller-tls with a
# serving certificate for the webhook, and renews it.
"$YQ" 'select(.kind == "Service" and .metadata.name == "ai-gateway-controller")
  | .metadata = {"name": "ai-gateway-controller",
                 "labels": {"app.kubernetes.io/name": "ai-gateway-controller",
                            "app.kubernetes.io/part-of": strenv(PART_OF)},
                 "annotations": {"service.beta.openshift.io/serving-cert-secret-name": "ai-gateway-controller-tls"}}
  | .spec.selector = (strenv(AR_SELECTOR) | from_yaml)
  | (.. | select(tag == "!!map" or tag == "!!seq")) style = "" | (... | select(tag == "!!str")) style = "" | ... comments = ""' \
  "$work/ar.yaml" >"$MANIFESTS/ai-gateway-controller_v1_service.yaml"

# The OpenShift service CA writes its CA bundle into this config map. The
# controller compares it with the webhook configuration at startup.
cat >"$MANIFESTS/ai-gateway-controller-service-ca_v1_configmap.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ai-gateway-controller-service-ca
  labels:
    app.kubernetes.io/name: ai-gateway-controller
    app.kubernetes.io/part-of: $PART_OF
  annotations:
    service.beta.openshift.io/inject-cabundle: "true"
EOF

BOOTSTRAP_SCRIPT=$(cat "$ROOT_DIR/config/bootstrap/ar-bootstrap.py") "$YQ" -n '
  .apiVersion = "v1"
  | .kind = "ConfigMap"
  | .metadata.name = "envoy-operator-bootstrap"
  | .metadata.labels."app.kubernetes.io/name" = "ai-gateway-controller"
  | .metadata.labels."app.kubernetes.io/part-of" = strenv(PART_OF)
  | .data."ar-bootstrap.py" = strenv(BOOTSTRAP_SCRIPT)' >"$MANIFESTS/envoy-operator-bootstrap_v1_configmap.yaml"

# ---------------------------------------------------------------------------
# Deployments
# ---------------------------------------------------------------------------
log "writing the deployments"

# Removes fixed user and group IDs, so that OpenShift assigns IDs from the
# namespace range (restricted-v2 SCC).
STRIP_IDS='
  del(.spec.template.spec.securityContext.runAsUser, .spec.template.spec.securityContext.runAsGroup,
      .spec.template.spec.securityContext.fsGroup)
  | del(.spec.template.spec.containers[].securityContext.runAsUser,
        .spec.template.spec.containers[].securityContext.runAsGroup)
  | del(.spec.template.spec.imagePullSecrets)'

# Restricted container security context for the init containers.
INIT_SECURITY='{"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]},
  "privileged": false, "readOnlyRootFilesystem": true, "runAsNonRoot": true,
  "seccompProfile": {"type": "RuntimeDefault"}}'
export INIT_SECURITY OPERATOR_VERSION NS CSV_NAME

# Envoy Gateway controller.
"$YQ" "select(.kind == \"Deployment\" and .metadata.name == \"envoy-gateway\") | $STRIP_IDS" "$work/eg.yaml" \
  | "$YQ" '
  {"name": "envoy-gateway",
   "label": {"app.kubernetes.io/name": "envoy-gateway", "app.kubernetes.io/part-of": strenv(PART_OF)},
   "spec": .spec}
  | .spec.selector.matchLabels = (strenv(EG_SELECTOR) | from_yaml)
  | .spec.template.metadata.labels = ((strenv(EG_SELECTOR) | from_yaml)
      + {"app.kubernetes.io/part-of": strenv(PART_OF), "app.kubernetes.io/version": strenv(OPERATOR_VERSION)})
  | .spec.template.metadata.annotations."kubectl.kubernetes.io/default-container" = "envoy-gateway"
  | (.spec.template.spec.containers[] | select(.name == "envoy-gateway")) |= (
      .image = strenv(EG_IMAGE)
      | (.env[] | select(.name == "ENVOY_GATEWAY_FULLNAME")).value = "envoy-gateway"
      | .resources.limits.cpu = "1")' >"$work/eg-deployment.yaml"

# The certgen container, taken from the upstream Job.
"$YQ" 'select(.kind == "Job") | .spec.template.spec.containers[0]
  | .image = strenv(EG_IMAGE)
  | .name = "envoy-gateway-certgen"
  | .securityContext = (strenv(INIT_SECURITY) | from_yaml)
  | .resources = {"requests": {"cpu": "10m", "memory": "32Mi"}, "limits": {"cpu": "200m", "memory": "128Mi"}}' \
  "$work/eg.yaml" >"$work/certgen-container.yaml"
"$YQ" -e '.args[] | select(. == "--disable-topology-injector")' "$work/certgen-container.yaml" >/dev/null \
  || fail "the certgen container must run with --disable-topology-injector"

# The bootstrap container.
"$YQ" -n '
  .name = "ar-bootstrap"
  | .image = strenv(BOOTSTRAP_IMAGE_PINNED)
  | .command = ["python3", "-I", "/bootstrap/ar-bootstrap.py"]
  | .env = [
      {"name": "POD_NAMESPACE", "valueFrom": {"fieldRef": {"fieldPath": "metadata.namespace"}}},
      {"name": "EXPECTED_NAMESPACE", "value": strenv(NS)},
      {"name": "CSV_NAME", "value": strenv(CSV_NAME)}]
  | .volumeMounts = [
      {"name": "bootstrap", "mountPath": "/bootstrap", "readOnly": true},
      {"name": "tmp", "mountPath": "/tmp"}]
  | .securityContext = (strenv(INIT_SECURITY) | from_yaml)
  | .resources = {"requests": {"cpu": "10m", "memory": "64Mi"}, "limits": {"cpu": "200m", "memory": "256Mi"}}' \
  >"$work/bootstrap-container.yaml"

# Agent router controller.
"$YQ" "select(.kind == \"Deployment\" and .metadata.name == \"ai-gateway-controller\") | $STRIP_IDS" "$work/ar.yaml" \
  >"$work/ar-deployment-raw.yaml"
CERTGEN="$work/certgen-container.yaml" BOOTSTRAP="$work/bootstrap-container.yaml" "$YQ" '
  {"name": "ai-gateway-controller",
   "label": {"app.kubernetes.io/name": "ai-gateway-controller", "app.kubernetes.io/part-of": strenv(PART_OF)},
   "spec": .spec}
  | .spec.selector.matchLabels = (strenv(AR_SELECTOR) | from_yaml)
  | .spec.template.metadata.labels = ((strenv(AR_SELECTOR) | from_yaml)
      + {"app.kubernetes.io/part-of": strenv(PART_OF), "app.kubernetes.io/version": strenv(OPERATOR_VERSION)})
  | .spec.template.metadata.annotations."kubectl.kubernetes.io/default-container" = "ai-gateway-controller"
  | .spec.template.spec.containers[0].name = "ai-gateway-controller"
  | .spec.template.spec.containers[0] |= (
      .image = strenv(AR_IMAGE)
      | .args |= map(sub("^--extProcImage=.*$", "--extProcImage=" + strenv(EXTPROC_IMAGE)))
      | .resources = {"requests": {"cpu": "100m", "memory": "128Mi"}, "limits": {"cpu": "1", "memory": "1Gi"}})
  | .spec.template.spec.initContainers = [load(strenv(CERTGEN)), load(strenv(BOOTSTRAP))]
  | .spec.template.spec.volumes = [
      {"name": "certs", "projected": {"sources": [
        {"secret": {"name": "ai-gateway-controller-tls",
                    "items": [{"key": "tls.crt", "path": "tls.crt"}, {"key": "tls.key", "path": "tls.key"}]}},
        {"configMap": {"name": "ai-gateway-controller-service-ca",
                       "items": [{"key": "service-ca.crt", "path": "ca.crt"}]}}]}},
      {"name": "bootstrap", "configMap": {"name": "envoy-operator-bootstrap", "defaultMode": 365}},
      {"name": "tmp", "emptyDir": {}}]' "$work/ar-deployment-raw.yaml" >"$work/ar-deployment.yaml"

# Checks on the args that depend on the namespace.
for arg in "--envoyGatewayNamespace=$NS" "--quotaRateLimitServiceAddr=envoy-ai-gateway-ratelimit.$NS" \
           "--tlsCertDir=/certs" "--extProcImage=$EXTPROC_IMAGE"; do
  A=$arg "$YQ" -e '.spec.template.spec.containers[0].args[] | select(. == strenv(A))' \
    "$work/ar-deployment.yaml" >/dev/null || fail "the agent router controller has no argument $arg"
done
grep -q "secretKeyRef" "$work/ar-deployment.yaml" || fail "the agent router controller no longer reads the MCP seed from a secret"

# ---------------------------------------------------------------------------
# ClusterServiceVersion
# ---------------------------------------------------------------------------
log "writing the ClusterServiceVersion $CSV_NAME"

# Owned CRDs: one entry per CRD, for its storage version. The display name
# comes from the kind ("AIGatewayRoute" -> "AI Gateway Route"), the
# description from the first sentence of the schema description.
{
  echo "[]"
  for f in "$MANIFESTS"/*_*.yaml; do
    [[ $("$YQ" '.kind' "$f") == CustomResourceDefinition ]] || continue
    kind=$("$YQ" '.spec.names.kind' "$f")
    display=$(sed -E 's/([a-z0-9])([A-Z])/\1 \2/g; s/([A-Z]+)([A-Z][a-z])/\1 \2/g' <<<"$kind")
    echo "---"
    DISPLAY=$display "$YQ" '[{
      "name": .metadata.name,
      "kind": .spec.names.kind,
      "version": (.spec.versions[] | select(.storage) | .name),
      "displayName": strenv(DISPLAY),
      "description": (.spec.names.kind as $kind
                      | ((.spec.versions[] | select(.storage) | .schema.openAPIV3Schema.description) // $kind)
                      | split("\n") | join(" ") | sub("\. .*$", ".") )
    }]' "$f"
  done
} | "$YQ" ea '[.[]] | flatten(1) | sort_by(.name)' >"$work/owned.yaml"

# alm-examples: the custom resources from the example, without namespace.
"$YQ" -o json -I 2 ea '[select(.apiVersion | test("^(gateway|aigateway)\.envoyproxy\.io/")) | del(.metadata.namespace)]' \
  "$ROOT_DIR/samples/ocp/40-gateway.yaml" >"$work/alm-examples.json"

ICON=$(base64 -w0 "$ROOT_DIR/config/manifests/icon.svg")
DESCRIPTION=$("$YQ" '.spec.description' "$ROOT_DIR/config/manifests/csv-template.yaml" \
  | sed "s/__EG_VERSION__/$EG_VERSION/g; s/__AR_VERSION__/$AR_VERSION/g")
ALM_EXAMPLES=$(cat "$work/alm-examples.json")
export ICON DESCRIPTION ALM_EXAMPLES EG_VERSION AR_VERSION REPLACES OPENSHIFT_VERSIONS CHANNEL

W=$work "$YQ" '
  .metadata.name = strenv(CSV_NAME)
  | .metadata.annotations."alm-examples" = strenv(ALM_EXAMPLES)
  | .metadata.annotations.containerImage = strenv(AR_IMAGE)
  | .spec.version = strenv(OPERATOR_VERSION)
  | .spec.description = strenv(DESCRIPTION)
  | .spec.icon = [{"base64data": strenv(ICON), "mediatype": "image/svg+xml"}]
  | .spec.customresourcedefinitions.owned = load(strenv(W) + "/owned.yaml")
  | .spec.install.strategy = "deployment"
  | .spec.install.spec.deployments = [load(strenv(W) + "/eg-deployment.yaml"), load(strenv(W) + "/ar-deployment.yaml")]
  | .spec.install.spec.clusterPermissions = [
      {"serviceAccountName": "envoy-gateway",
       "rules": load(strenv(W) + "/eg-cluster-rules.yaml") + load(strenv(W) + "/eg-cluster-rules-from-ar.yaml")},
      {"serviceAccountName": "ai-gateway-controller",
       "rules": load(strenv(W) + "/ar-cluster-rules.yaml") + load(strenv(W) + "/ar-bootstrap-rules.yaml")}]
  | .spec.install.spec.permissions = [
      {"serviceAccountName": "envoy-gateway", "rules": load(strenv(W) + "/eg-rules.yaml")},
      {"serviceAccountName": "ai-gateway-controller", "rules": load(strenv(W) + "/certgen-rules.yaml")}]
  | .spec.relatedImages = [
      {"name": "envoy-gateway", "image": strenv(EG_IMAGE)},
      {"name": "envoy-proxy", "image": strenv(PROXY_IMAGE)},
      {"name": "envoy-ratelimit", "image": strenv(RATELIMIT_IMAGE)},
      {"name": "ai-gateway-controller", "image": strenv(AR_IMAGE)},
      {"name": "ai-gateway-extproc", "image": strenv(EXTPROC_IMAGE)},
      {"name": "bootstrap", "image": strenv(BOOTSTRAP_IMAGE_PINNED)}]
  | .metadata.annotations."envoy-operator.io/envoy-gateway-version" = strenv(EG_VERSION)
  | .metadata.annotations."envoy-operator.io/agent-router-version" = strenv(AR_VERSION)
  | . head_comment = ""
  | .spec.replaces = strenv(REPLACES)
  | del(.spec.replaces | select(. == ""))
  | (.. | select(tag == "!!map" or tag == "!!seq")) style = ""
  | (... | select(tag == "!!str" and (test("\n") | not))) style = ""
  | ... comments = ""' \
  "$ROOT_DIR/config/manifests/csv-template.yaml" >"$MANIFESTS/$PACKAGE_NAME.clusterserviceversion.yaml"

# ---------------------------------------------------------------------------
# Metadata and scorecard
# ---------------------------------------------------------------------------
cat >"$METADATA/annotations.yaml" <<EOF
annotations:
  operators.operatorframework.io.bundle.mediatype.v1: registry+v1
  operators.operatorframework.io.bundle.manifests.v1: manifests/
  operators.operatorframework.io.bundle.metadata.v1: metadata/
  operators.operatorframework.io.bundle.package.v1: $PACKAGE_NAME
  operators.operatorframework.io.bundle.channels.v1: $CHANNEL
  operators.operatorframework.io.bundle.channel.default.v1: $CHANNEL
  operators.operatorframework.io.test.config.v1: tests/scorecard/
  operators.operatorframework.io.test.mediatype.v1: scorecard+v1
  com.redhat.openshift.versions: $OPENSHIFT_VERSIONS
EOF

# The scorecard test image must match the operator-sdk version in tools.sh.
SDK_VERSION=$(sed -n 's/^OPERATOR_SDK_VERSION=//p' "$ROOT_DIR/hack/tools.sh")
[[ -n $SDK_VERSION ]] || fail "cannot read OPERATOR_SDK_VERSION from hack/tools.sh"
mkdir -p "$BUNDLE_DIR/tests/scorecard"
cat >"$BUNDLE_DIR/tests/scorecard/config.yaml" <<EOF
apiVersion: scorecard.operatorframework.io/v1alpha3
kind: Configuration
metadata:
  name: config
stages:
  - parallel: true
    tests:
      - entrypoint: [scorecard-test, basic-check-spec]
        image: quay.io/operator-framework/scorecard-test:$SDK_VERSION
        labels:
          suite: basic
          test: basic-check-spec-test
      - entrypoint: [scorecard-test, olm-bundle-validation]
        image: quay.io/operator-framework/scorecard-test:$SDK_VERSION
        labels:
          suite: olm
          test: olm-bundle-validation-test
EOF

# The bundle image labels must match metadata/annotations.yaml.
{
  echo "# Generated by hack/generate-bundle.sh. Do not edit."
  echo "FROM scratch"
  echo
  "$YQ" '.annotations | to_entries | .[] | "LABEL " + .key + "=" + .value' "$METADATA/annotations.yaml"
  echo
  echo "COPY bundle/manifests /manifests/"
  echo "COPY bundle/metadata /metadata/"
  echo "COPY bundle/tests/scorecard /tests/scorecard/"
} >"$ROOT_DIR/bundle.Dockerfile"

log "bundle written to ${BUNDLE_DIR#"$ROOT_DIR"/}: $(find "$MANIFESTS" -type f | wc -l) manifests, $(du -sh "$MANIFESTS" | cut -f1)"
