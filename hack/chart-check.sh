#!/usr/bin/env bash
# Checks that every file that hack/update-upstream.sh writes is exactly what it
# writes today for the versions in versions.env: the upstream chart (never
# changed by hand), the versions and the pinned images of the operator chart,
# related-images.yaml, the CRDs and the RBAC.
#
#   hack/chart-check.sh      (or: make chart-check)
#
# It runs hack/update-upstream.sh in a copy of the repository, so it needs
# network access. A difference in the image digests means that an image was
# pinned by hand, or that upstream moved a tag.

# shellcheck source=hack/lib.sh
source "$(dirname "$0")/lib.sh"
require_tools HELM YQ

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

copy=$work/copy
mkdir -p "$copy/config/crd" "$copy/config/manifests" "$copy/config/rbac"
cp -a "$ROOT_DIR/hack" "$ROOT_DIR/helm-charts" "$ROOT_DIR/versions.env" "$copy/"
cp -a "$ROOT_DIR/config/crd/bases" "$copy/config/crd/"
cp -a "$ROOT_DIR/config/manifests/related-images.yaml" "$copy/config/manifests/"
cp -a "$ROOT_DIR/config/rbac/role.yaml" "$copy/config/rbac/"
log "running hack/update-upstream.sh in a copy of the repository"
BIN_DIR=$BIN_DIR run_quiet "hack/update-upstream.sh failed in the copy" "$copy/hack/update-upstream.sh"

errors=0
compare() {
  if diff -ru "$ROOT_DIR/$1" "$copy/$1"; then
    log "$1 is up to date"
  else
    printf 'ERROR: %s is not what hack/update-upstream.sh writes\n' "$1" >&2
    errors=$((errors + 1))
  fi
}
compare helm-charts
compare config/crd
compare config/manifests/related-images.yaml
compare config/rbac/role.yaml

[[ $errors -eq 0 ]] || fail "$errors path(s) differ. Never change the upstream chart or the pins by hand; run 'make update-upstream'."
log "the upstream chart, the pins, the CRDs and the RBAC match versions.env"
