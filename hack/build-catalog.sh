#!/usr/bin/env bash
# Builds a file-based catalog (FBC) for tests. The community catalog builds its
# own catalog from the bundle, so this one is only for CI and lab tests.
#
#   hack/build-catalog.sh <output-dir> <bundle-dir>=<bundle-image> [<bundle-dir>=<bundle-image>...]
#
# Example:
#   hack/build-catalog.sh build/catalog bundle=quay.io/example/envoy-operator-bundle:v0.1.0
#
# The script renders each bundle from its directory, so it does not need to
# pull the bundle images. Give the bundles in upgrade order (oldest first):
# each bundle becomes an entry of the channel, with the "replaces" field of
# its ClusterServiceVersion.

# shellcheck source=hack/lib.sh
source "$(dirname "$0")/lib.sh"
require_tools OPM YQ

[[ $# -ge 2 ]] || fail "usage: $0 <output-dir> <bundle-dir>=<bundle-image> [...]"
out=$1
shift

rm -rf "$out"
mkdir -p "$out/$PACKAGE_NAME"
catalog=$out/$PACKAGE_NAME/catalog.yaml
entries=$(mktemp)
trap 'rm -f "$entries"' EXIT

channel=""
{
  for pair in "$@"; do
    dir=${pair%%=*}
    image=${pair#*=}
    [[ -d $dir/manifests && -n $image && $image != "$pair" ]] || fail "invalid argument: $pair"
    csv=$(find "$dir/manifests" -name '*.clusterserviceversion.yaml' | head -1)
    name=$("$YQ" '.metadata.name' "$csv")
    replaces=$("$YQ" '.spec.replaces // ""' "$csv")
    channel=$("$YQ" '.annotations."operators.operatorframework.io.bundle.channel.default.v1"' "$dir/metadata/annotations.yaml")
    channels=$("$YQ" '.annotations."operators.operatorframework.io.bundle.channels.v1"' "$dir/metadata/annotations.yaml")
    # The test catalog has one channel. Publishing to several channels is the
    # job of the community catalog templates.
    [[ $channels == "$channel" ]] || fail "$name: the test catalog supports one channel, but the bundle has '$channels'"
    log "adding $name ($image)"
    echo "---"
    # Replace the bundle objects with the CSV metadata, like the community
    # catalogs do. OLM then pulls the bundle image for the manifests. A bundle
    # with its objects inline is larger than the 2 MiB gRPC message limit.
    metadata=$("$YQ" -o json -I 0 '
      .spec
      | pick(["apiservicedefinitions", "customresourcedefinitions", "description", "displayName",
              "installModes", "keywords", "links", "maintainers", "maturity", "minKubeVersion",
              "nativeAPIs", "provider"])
      | with_entries(.key |= (sub("^customresourcedefinitions$", "crdDescriptions")
                            | sub("^apiservicedefinitions$", "apiServiceDefinitions")))' "$csv")
    metadata=$(M=$metadata F=$csv "$YQ" -n -o json -I 0 \
      '(strenv(M) | from_json) + {"annotations": load(strenv(F)).metadata.annotations, "labels": load(strenv(F)).metadata.labels}')
    "$OPM" render "$dir" -o yaml | IMAGE=$image M=$metadata "$YQ" '
      .image = strenv(IMAGE)
      | .properties |= (map(select(.type != "olm.bundle.object"))
                        + [{"type": "olm.csv.metadata", "value": (strenv(M) | from_json)}])'
    if [[ -n $replaces ]]; then
      printf -- '- name: %s\n  replaces: %s\n' "$name" "$replaces" >>"$entries"
    else
      printf -- '- name: %s\n' "$name" >>"$entries"
    fi
  done
} >"$out/bundles.yaml"

{
  printf -- '---\nschema: olm.package\nname: %s\ndefaultChannel: %s\n' "$PACKAGE_NAME" "$channel"
  printf -- '---\nschema: olm.channel\npackage: %s\nname: %s\nentries:\n' "$PACKAGE_NAME" "$channel"
  cat "$entries"
  cat "$out/bundles.yaml"
} >"$catalog"
rm -f "$out/bundles.yaml"

"$OPM" validate "$out" || fail "the catalog in $out is not valid"
log "catalog written to $catalog"
