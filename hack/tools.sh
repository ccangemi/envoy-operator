#!/usr/bin/env bash
# The sums are read through ${!sum}, which shellcheck cannot follow.
# shellcheck disable=SC2034
# Installs the pinned tools in bin/ and checks their SHA-256 sums.
# The generated bundle depends on the exact tool versions, so everyone (and the
# CI) must use the same ones.
#
#   hack/tools.sh                 install helm, yq, kustomize, operator-sdk and opm
#   hack/tools.sh helm-operator   install helm-operator (for `make run`)
#   hack/tools.sh helm yq         install only some tools
#
# To move a tool to a new version, change the version and both sums. Take the
# sums from the checksum file of the upstream release.

# shellcheck source=hack/lib.sh
source "$(dirname "$0")/lib.sh"

HELM_VERSION=v3.22.0
HELM_SHA256_amd64=1e4ab49e429626cf6c6958d914248b78c9730803c2751b87627e171dc800e7bb
HELM_SHA256_arm64=f14e804dfee240f55525b667488fe9adca349e63e00c9af634c0beb1421ac310

YQ_VERSION=v4.53.3
YQ_SHA256_amd64=fa52a4e758c63d38299163fbdd1edfb4c4963247918bf9c1c5d31d84789eded4
YQ_SHA256_arm64=578648e463a11c1b6db6010cbf41eafed6bee79466fcffa1bb446672cf7945ea

OPERATOR_SDK_VERSION=v1.42.3
OPERATOR_SDK_SHA256_amd64=887a3bb0d63ccc4ca47a522d0c8ffac56d9d5246f6a2bd886b4ed23eb2e2672f
OPERATOR_SDK_SHA256_arm64=6db93cd821b429f0bb514cea4bbb5553827d273fc8aa211f13e14798599d31cd

OPM_VERSION=v1.74.0
OPM_SHA256_amd64=cf1bd699be72e0a4511208afdf45444fc47d21eb2ffed0c204520ff50b5a4691
OPM_SHA256_arm64=348a9682975eb220bea3b98b83aa82dc6d2630e6868331ed9bf14f97e462d8be

KUSTOMIZE_VERSION=v5.8.3
KUSTOMIZE_SHA256_amd64=cb9e31198d3f63b44848bd0afc4c8efc56e6cfef9c93a4a39a211940e6decd61
KUSTOMIZE_SHA256_arm64=9867b76482cfc6d25b546abc1d2b5a32bd137505aba640649b4b378f64f6d68f

# helm-operator runs the operator on your machine (`make run`). Keep it at the
# same version as the base image in the Dockerfile.
HELM_OPERATOR_VERSION=v1.42.3
HELM_OPERATOR_SHA256_amd64=f244bb81bc00afabfcbd1e23070ca9c18f4cfe09bf7a8dbbcbe2999df739cf92
HELM_OPERATOR_SHA256_arm64=44f24480e85f38e3f9c976092a4aa996567b893723842f9ded0d264a31c7ec35

case $(uname -s)/$(uname -m) in
  Linux/x86_64) ARCH=amd64 ;;
  Linux/aarch64 | Linux/arm64) ARCH=arm64 ;;
  *) fail "no pinned tools for $(uname -s)/$(uname -m)" ;;
esac

mkdir -p "$BIN_DIR"

# fetch <url> <file> <sha256>: download to a temporary file, check the sum,
# then move the file in place.
fetch() {
  local url=$1 file=$2 sum=$3
  curl -sSfL --retry 3 -o "$file.part" "$url" || fail "cannot download $url"
  if ! sha256sum -c --status <<<"$sum  $file.part"; then
    rm -f "$file.part"
    fail "$url does not match its pinned SHA-256 sum"
  fi
  mv "$file.part" "$file"
}

# installed <binary> <stamp-file> <version>: true when the binary exists and
# the stamp file records the same version.
installed() { [[ -x $1 && -f $2 && $(cat "$2") == "$3" ]]; }

install_helm() {
  local sum=HELM_SHA256_$ARCH stamp=$BIN_DIR/.helm-version tmp
  installed "$BIN_DIR/helm" "$stamp" "$HELM_VERSION" && return
  log "installing helm $HELM_VERSION"
  tmp=$(mktemp -d)
  fetch "https://get.helm.sh/helm-$HELM_VERSION-linux-$ARCH.tar.gz" "$tmp/helm.tgz" "${!sum}"
  tar -xzf "$tmp/helm.tgz" -C "$tmp"
  mv "$tmp/linux-$ARCH/helm" "$BIN_DIR/helm"
  rm -rf "$tmp"
  echo "$HELM_VERSION" >"$stamp"
}

install_yq() {
  local sum=YQ_SHA256_$ARCH stamp=$BIN_DIR/.yq-version
  installed "$BIN_DIR/yq" "$stamp" "$YQ_VERSION" && return
  log "installing yq $YQ_VERSION"
  fetch "https://github.com/mikefarah/yq/releases/download/$YQ_VERSION/yq_linux_$ARCH" "$BIN_DIR/yq" "${!sum}"
  chmod +x "$BIN_DIR/yq"
  echo "$YQ_VERSION" >"$stamp"
}

install_operator_sdk() {
  local sum=OPERATOR_SDK_SHA256_$ARCH stamp=$BIN_DIR/.operator-sdk-version
  installed "$BIN_DIR/operator-sdk" "$stamp" "$OPERATOR_SDK_VERSION" && return
  log "installing operator-sdk $OPERATOR_SDK_VERSION"
  fetch "https://github.com/operator-framework/operator-sdk/releases/download/$OPERATOR_SDK_VERSION/operator-sdk_linux_$ARCH" \
    "$BIN_DIR/operator-sdk" "${!sum}"
  chmod +x "$BIN_DIR/operator-sdk"
  echo "$OPERATOR_SDK_VERSION" >"$stamp"
}

install_opm() {
  local sum=OPM_SHA256_$ARCH stamp=$BIN_DIR/.opm-version
  installed "$BIN_DIR/opm" "$stamp" "$OPM_VERSION" && return
  log "installing opm $OPM_VERSION"
  fetch "https://github.com/operator-framework/operator-registry/releases/download/$OPM_VERSION/linux-$ARCH-opm" \
    "$BIN_DIR/opm" "${!sum}"
  chmod +x "$BIN_DIR/opm"
  echo "$OPM_VERSION" >"$stamp"
}

install_kustomize() {
  local sum=KUSTOMIZE_SHA256_$ARCH stamp=$BIN_DIR/.kustomize-version tmp
  installed "$BIN_DIR/kustomize" "$stamp" "$KUSTOMIZE_VERSION" && return
  log "installing kustomize $KUSTOMIZE_VERSION"
  tmp=$(mktemp -d)
  fetch "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F$KUSTOMIZE_VERSION/kustomize_${KUSTOMIZE_VERSION}_linux_$ARCH.tar.gz" \
    "$tmp/kustomize.tgz" "${!sum}"
  tar -xzf "$tmp/kustomize.tgz" -C "$tmp"
  mv "$tmp/kustomize" "$BIN_DIR/kustomize"
  rm -rf "$tmp"
  echo "$KUSTOMIZE_VERSION" >"$stamp"
}

install_helm_operator() {
  local sum=HELM_OPERATOR_SHA256_$ARCH stamp=$BIN_DIR/.helm-operator-version
  installed "$BIN_DIR/helm-operator" "$stamp" "$HELM_OPERATOR_VERSION" && return
  log "installing helm-operator $HELM_OPERATOR_VERSION"
  fetch "https://github.com/operator-framework/operator-sdk/releases/download/$HELM_OPERATOR_VERSION/helm-operator_linux_$ARCH" \
    "$BIN_DIR/helm-operator" "${!sum}"
  chmod +x "$BIN_DIR/helm-operator"
  echo "$HELM_OPERATOR_VERSION" >"$stamp"
}

tools=("$@")
[[ ${#tools[@]} -gt 0 ]] || tools=(helm yq kustomize operator-sdk opm)
for t in "${tools[@]}"; do
  case $t in
    helm) install_helm ;;
    yq) install_yq ;;
    operator-sdk) install_operator_sdk ;;
    opm) install_opm ;;
    kustomize) install_kustomize ;;
    helm-operator) install_helm_operator ;;
    *) fail "unknown tool: $t" ;;
  esac
done
