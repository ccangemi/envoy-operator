#!/usr/bin/env bash
# Prepares the directory operators/envoy-operator/ for a pull request to the
# community catalog (redhat-openshift-ecosystem/community-operators-prod).
#
#   hack/community-layout.sh [<output-dir>]     (default: build/community)
#
# Output:
#   <output-dir>/operators/envoy-operator/
#     ci.yaml
#     catalog-templates/basic.yaml
#     <OPERATOR_VERSION>/manifests/
#     <OPERATOR_VERSION>/metadata/
#     <OPERATOR_VERSION>/release-config.yaml
#
# Copy the directory into your fork of the community repository. Add the
# Makefile from the operator-pipelines repository (see community/README.md).

# shellcheck source=hack/lib.sh
source "$(dirname "$0")/lib.sh"

out=${1:-$ROOT_DIR/build/community}
dir=$out/operators/$PACKAGE_NAME
rm -rf "$dir"
mkdir -p "$dir/$OPERATOR_VERSION"

cp "$ROOT_DIR/community/ci.yaml" "$dir/"
cp -r "$ROOT_DIR/community/catalog-templates" "$dir/"
cp -r "$BUNDLE_DIR/manifests" "$BUNDLE_DIR/metadata" "$dir/$OPERATOR_VERSION/"

{
  echo "---"
  echo "catalog_templates:"
  echo "  - template_name: basic.yaml"
  echo "    channels: [$CHANNEL]"
  if [[ -n $REPLACES ]]; then
    echo "    replaces: $REPLACES"
  fi
} >"$dir/$OPERATOR_VERSION/release-config.yaml"

log "community layout written to ${dir#"$ROOT_DIR"/}"
