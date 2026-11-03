#!/usr/bin/env bash
# Checks that the upstream chart in helm-charts/envoy-gateway/charts/ and the
# CRDs in config/crd are exactly what hack/update-upstream.sh writes for the
# versions in versions.env. Nobody may change the upstream chart by hand.
#
#   hack/chart-check.sh      (or: make chart-check)
#
# It needs network access to pull the upstream charts.

# shellcheck source=hack/lib.sh
source "$(dirname "$0")/lib.sh"
require_tools HELM YQ

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

log "pulling $CHART_NAME $CHART_VERSION"
"$HELM" pull "$CHART_OCI/$CHART_NAME" --version "$CHART_VERSION" --untar --untardir "$work" >/dev/null 2>&1 \
  || fail "cannot pull $CHART_OCI/$CHART_NAME $CHART_VERSION"
diff -r "$work/$CHART_NAME" "$UPSTREAM_CHART_DIR" \
  || fail "${UPSTREAM_CHART_DIR#"$ROOT_DIR"/} differs from the upstream chart. Never change it by hand; run 'make update-upstream'."
log "${UPSTREAM_CHART_DIR#"$ROOT_DIR"/} is the upstream chart $CHART_VERSION, unchanged"

# The CRDs: run hack/update-upstream.sh in a copy of the repository and
# compare its config/crd with ours.
copy=$work/copy
mkdir -p "$copy/config/crd/bases" "$copy/config/manifests" "$copy/config/rbac"
cp -a "$ROOT_DIR/hack" "$ROOT_DIR/helm-charts" "$ROOT_DIR/versions.env" "$copy/"
cp -a "$ROOT_DIR"/config/crd/bases/. "$copy/config/crd/bases/"
BIN_DIR=$BIN_DIR "$copy/hack/update-upstream.sh" >/dev/null 2>&1 || fail "cannot run hack/update-upstream.sh in a copy"
diff -r "$copy/config/crd" "$ROOT_DIR/config/crd" \
  || fail "config/crd is not what hack/update-upstream.sh writes. Run 'make update-upstream'."
log "config/crd is up to date"
