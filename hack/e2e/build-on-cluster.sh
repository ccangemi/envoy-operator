#!/usr/bin/env bash
# Builds the operator, bundle and catalog images inside an OpenShift cluster,
# with binary BuildConfigs and the internal image registry. Use it to test the
# current code with OLM before any image is published, without a container
# tool on your machine.
#
#   KUBECONFIG=<file> hack/e2e/build-on-cluster.sh
#
# Needs: the internal image registry enabled (managementState Managed, with
# storage), and the rights to create a namespace. The images go to the
# namespace BUILD_NAMESPACE (default operator-builds). Every service account of
# the cluster may pull them.
#
# The last line of the output is the catalog image. Give it to hack/e2e/ocp.sh:
#   CATALOG_IMAGE=<image> hack/e2e/ocp.sh install

# shellcheck source=hack/e2e/lib.sh
source "$(dirname "$0")/lib.sh"
require_tools YQ OPM KUSTOMIZE OPERATOR_SDK

BUILD_NAMESPACE=${BUILD_NAMESPACE:-operator-builds}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

k get namespace "$BUILD_NAMESPACE" >/dev/null 2>&1 || k create namespace "$BUILD_NAMESPACE" >/dev/null
k policy add-role-to-group system:image-puller system:serviceaccounts -n "$BUILD_NAMESPACE" >/dev/null

# build <name> <context-dir>: builds <context-dir>/Dockerfile and prints the
# image reference, pinned by digest, in the internal registry.
build() {
  local name=$1 dir=$2
  if ! k get buildconfig "$name" -n "$BUILD_NAMESPACE" >/dev/null 2>&1; then
    k new-build --binary --strategy=docker --name "$name" -n "$BUILD_NAMESPACE" >/dev/null
  fi
  log "building $name"
  k start-build "$name" -n "$BUILD_NAMESPACE" --from-dir "$dir" --follow --wait >"$work/$name.log" 2>&1 || {
    tail -30 "$work/$name.log" >&2
    fail "the build of $name failed"
  }
  k get istag "$name:latest" -n "$BUILD_NAMESPACE" -o jsonpath='{.image.dockerImageReference}'
}

# The operator image: only what the Dockerfile copies.
# Each context has the files that the Dockerfile needs and the .dockerignore of
# the repository, so the build also checks that .dockerignore keeps them.
mkdir -p "$work/operator"
cp -a "$ROOT_DIR/Dockerfile" "$ROOT_DIR/.dockerignore" "$ROOT_DIR/LICENSE" "$ROOT_DIR/watches.yaml" "$ROOT_DIR/helm-charts" \
  "$work/operator/"
operator_image=$(build "$PACKAGE_NAME" "$work/operator")
log "operator image: $operator_image"

# The bundle, generated in a copy of the repository for this operator image.
mkdir -p "$work/repo"
(cd "$ROOT_DIR" && tar --exclude=./bin --exclude=./build --exclude=./.git -cf - .) | tar -C "$work/repo" -xf -
BIN_DIR=$BIN_DIR OPERATOR_IMAGE=$operator_image run_quiet "cannot generate the bundle" "$work/repo/hack/generate-bundle.sh"
mkdir -p "$work/bundle"
cp -a "$work/repo/bundle" "$ROOT_DIR/.dockerignore" "$work/bundle/"
cp "$work/repo/bundle.Dockerfile" "$work/bundle/Dockerfile"
bundle_image=$(build "$PACKAGE_NAME-bundle" "$work/bundle")
log "bundle image: $bundle_image"

# The catalog, with the bundle rendered from its directory.
mkdir -p "$work/catalog/build"
run_quiet "cannot build the catalog" \
  "$ROOT_DIR/hack/build-catalog.sh" "$work/catalog/build/catalog" "$work/repo/bundle=$bundle_image"
cp "$ROOT_DIR/catalog.Dockerfile" "$work/catalog/Dockerfile"
cp "$ROOT_DIR/.dockerignore" "$work/catalog/"
catalog_image=$(build "$PACKAGE_NAME-catalog" "$work/catalog")
log "catalog image: $catalog_image"
echo "$catalog_image"
