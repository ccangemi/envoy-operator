# shellcheck shell=bash
# Common settings and helpers. The other scripts in hack/ source this file.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BIN_DIR=${BIN_DIR:-$ROOT_DIR/bin}
BUNDLE_DIR=${BUNDLE_DIR:-$ROOT_DIR/bundle}
# shellcheck disable=SC2034 # used by the scripts that source this file
PACKAGE_NAME=envoy-operator

# shellcheck source=versions.env
source "$ROOT_DIR/versions.env"

# The only CRD groups that the bundle may contain.
# Never gateway.networking.k8s.io: the OpenShift Ingress Operator owns those
# CRDs, and an admission policy rejects changes from anyone else.
# Never inference.networking.*: on clusters with OpenShift AI, KServe owns the
# InferencePool CRD, and two owners would overwrite each other.
# shellcheck disable=SC2034
ALLOWED_CRD_GROUPS='^(gateway\.envoyproxy\.io|aigateway\.envoyproxy\.io)$'

# Tools. hack/tools.sh installs the pinned versions in bin/. You can point
# these variables to other binaries, but the generated files may then differ.
HELM=${HELM:-$BIN_DIR/helm}
YQ=${YQ:-$BIN_DIR/yq}
OPERATOR_SDK=${OPERATOR_SDK:-$BIN_DIR/operator-sdk}
OPM=${OPM:-$BIN_DIR/opm}
KIND=${KIND:-$BIN_DIR/kind}

log() { printf '==> %s\n' "$*" >&2; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_tools() {
  local t
  for t in "$@"; do
    [[ -x ${!t} ]] || command -v "${!t}" >/dev/null 2>&1 \
      || fail "$t (${!t}) not found. Run 'make tools' first."
  done
}

# resolve_digest <registry/repository:tag>
# Prints the digest of the tag (for a multi-arch image, the digest of the
# index). It uses the registry API with an anonymous token, so it works for
# public images on docker.io and quay.io without extra tools.
resolve_digest() {
  local ref=$1 registry rest repo tag api accept headers auth realm service token digest
  registry=${ref%%/*}
  rest=${ref#*/}
  repo=${rest%:*}
  tag=${rest##*:}
  api=$registry
  [[ $registry == docker.io ]] && api="registry-1.docker.io"
  accept='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'
  headers=$(curl -sSI --retry 3 "https://$api/v2/$repo/manifests/$tag" -H "Accept: $accept") \
    || fail "cannot reach the registry for $ref"
  if grep -qi '^www-authenticate: bearer' <<<"$headers"; then
    auth=$(grep -i '^www-authenticate:' <<<"$headers" | tr -d '\r')
    realm=$(sed -E 's/.*realm="([^"]+)".*/\1/' <<<"$auth")
    service=$(sed -E 's/.*service="([^"]+)".*/\1/' <<<"$auth")
    token=$(curl -sSf --retry 3 "$realm?service=$service&scope=repository:$repo:pull" \
      | "$YQ" -p json '.token // .access_token') || fail "cannot get a registry token for $ref"
    headers=$(curl -sSI --retry 3 "https://$api/v2/$repo/manifests/$tag" \
      -H "Accept: $accept" -H "Authorization: Bearer $token") || fail "cannot read the manifest of $ref"
  fi
  digest=$(grep -i '^docker-content-digest:' <<<"$headers" | awk '{print $2}' | tr -d '\r')
  [[ $digest == sha256:* ]] || fail "no digest found for $ref"
  printf '%s\n' "$digest"
}

# pin <registry/repository:tag> prints repository@digest. A reference that
# already has a digest is printed as it is.
pin() {
  local ref=$1
  if [[ $ref == *@sha256:* ]]; then
    printf '%s\n' "$ref"
    return
  fi
  printf '%s@%s\n' "${ref%:*}" "$(resolve_digest "$ref")"
}
