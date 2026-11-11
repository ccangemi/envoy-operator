#!/usr/bin/env bash
# Generates bundle/ and bundle.Dockerfile, the OLM bundle of the operator.
#
#   hack/generate-bundle.sh      (or: make bundle)
#
# The script needs no network access, and the same inputs always give the
# same bundle, so the CI can check that the committed bundle is up to date.
#
# Inputs: config/ (kustomize), versions.env, config/manifests/related-images.yaml
# and config/manifests/icon.svg.
#
# OPERATOR_IMAGE overrides the operator image (default
# <OPERATOR_IMAGE_REPOSITORY>:v<OPERATOR_VERSION>). The release workflow sets it
# to the image that it pushed, pinned by digest.

# shellcheck source=hack/lib.sh
source "$(dirname "$0")/lib.sh"
require_tools KUSTOMIZE YQ OPERATOR_SDK

export OPERATOR_IMAGE=${OPERATOR_IMAGE:-$OPERATOR_IMAGE_REPOSITORY:v$OPERATOR_VERSION}
CSV=$BUNDLE_DIR/manifests/$PACKAGE_NAME.clusterserviceversion.yaml
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

log "rendering config/manifests with the operator image $OPERATOR_IMAGE"
"$KUSTOMIZE" build "$ROOT_DIR/config/manifests" >"$work/manifests.yaml"
"$YQ" -i '(select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "manager") | .image)
  = strenv(OPERATOR_IMAGE)' "$work/manifests.yaml"

log "generating the bundle with operator-sdk"
rm -rf "$BUNDLE_DIR"
(cd "$ROOT_DIR" && "$OPERATOR_SDK" generate bundle -q --overwrite \
  --package "$PACKAGE_NAME" --version "$OPERATOR_VERSION" \
  --channels "$CHANNEL" --default-channel "$CHANNEL" \
  --output-dir "${BUNDLE_DIR#"$ROOT_DIR"/}" < <(cat "$work/manifests.yaml"))

log "completing the ClusterServiceVersion"
export CSV_NAME=$PACKAGE_NAME.v$OPERATOR_VERSION OPERATOR_VERSION REPLACES CHART_VERSION
ICON=$(base64 -w0 "$ROOT_DIR/config/manifests/icon.svg")
export ICON
RELATED=$("$YQ" -o json -I0 '.' "$ROOT_DIR/config/manifests/related-images.yaml")
export RELATED
"$YQ" -i '
  .metadata.name = strenv(CSV_NAME)
  | .spec.version = strenv(OPERATOR_VERSION)
  | del(.metadata.annotations.createdAt)
  | .metadata.annotations.containerImage = strenv(OPERATOR_IMAGE)
  | .spec.description |= sub("__CHART_VERSION__", strenv(CHART_VERSION))
  | .spec.icon = [{"base64data": strenv(ICON), "mediatype": "image/svg+xml"}]
  | .spec.relatedImages = [{"name": "operator", "image": strenv(OPERATOR_IMAGE)}] + (strenv(RELATED) | from_json)
  | (.spec.relatedImages | ...) style = ""
' "$CSV"
if [[ -n $REPLACES ]]; then
  "$YQ" -i '.spec.replaces = strenv(REPLACES)' "$CSV"
fi

# The upstream CRDs have no display name or description in the base CSV. Take
# the kind and the first sentence of the schema description of each CRD.
for f in "$BUNDLE_DIR"/manifests/*.yaml; do
  [[ $("$YQ" '.kind' "$f") == CustomResourceDefinition ]] || continue
  name=$("$YQ" '.metadata.name' "$f")
  kind=$("$YQ" '.spec.names.kind' "$f")
  description=$("$YQ" '.spec.versions[] | select(.storage) | .schema.openAPIV3Schema.description // ""' "$f" \
    | tr '\n' ' ' | sed -E 's/\s+/ /g; s/^ //; s/([.!?]) .*/\1/; s/ $//')
  NAME=$name KIND=$kind DESCRIPTION=${description:-$kind} "$YQ" -i '
    (.spec.customresourcedefinitions.owned[] | select(.name == strenv(NAME))) |= (
      .displayName = (.displayName // strenv(KIND))
      | .description = (.description // strenv(DESCRIPTION)))' "$CSV"
done

# OpenShift reads the supported versions from this annotation, in the bundle
# metadata and as a label of the bundle image.
export OPENSHIFT_VERSIONS
"$YQ" -i '.annotations."com.redhat.openshift.versions" = strenv(OPENSHIFT_VERSIONS)' "$BUNDLE_DIR/metadata/annotations.yaml"
{
  grep -v '^LABEL com.redhat.openshift.versions=' "$ROOT_DIR/bundle.Dockerfile" \
    | sed "/^LABEL operators.operatorframework.io.bundle.channel.default.v1=/a LABEL com.redhat.openshift.versions=$OPENSHIFT_VERSIONS"
} >"$work/bundle.Dockerfile"
mv "$work/bundle.Dockerfile" "$ROOT_DIR/bundle.Dockerfile"

log "bundle written to ${BUNDLE_DIR#"$ROOT_DIR"/} ($CSV_NAME)"
