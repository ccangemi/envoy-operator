#!/usr/bin/env bash
# The sums are read through ${!sum}, which shellcheck cannot follow.
# shellcheck disable=SC2034
# Installs the pinned tools in bin/ and checks their SHA-256 sums.
# The generated bundle depends on the exact tool versions, so everyone (and the
# CI) must use the same ones.
#
#   hack/tools.sh            install helm, yq, operator-sdk and opm
#   hack/tools.sh kind       install kind (for the kind end-to-end test)
#   hack/tools.sh helm yq    install only some tools
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

# kind is only needed for hack/e2e/kind.sh.
KIND_VERSION=v0.33.0
KIND_SHA256_amd64=aee6151561422756b764a4ae28e7f44cda5af5a9eead3cc9985112b1de8d8e0d
KIND_SHA256_arm64=20022bee6cfcd5086cb7234d218e3454e6090022f2a8f55d1fa7fcf42c3867a2

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

install_kind() {
  local sum=KIND_SHA256_$ARCH stamp=$BIN_DIR/.kind-version
  installed "$BIN_DIR/kind" "$stamp" "$KIND_VERSION" && return
  log "installing kind $KIND_VERSION"
  fetch "https://github.com/kubernetes-sigs/kind/releases/download/$KIND_VERSION/kind-linux-$ARCH" "$BIN_DIR/kind" "${!sum}"
  chmod +x "$BIN_DIR/kind"
  echo "$KIND_VERSION" >"$stamp"
}

tools=("$@")
[[ ${#tools[@]} -gt 0 ]] || tools=(helm yq operator-sdk opm)
for t in "${tools[@]}"; do
  case $t in
    helm) install_helm ;;
    yq) install_yq ;;
    operator-sdk) install_operator_sdk ;;
    opm) install_opm ;;
    kind) install_kind ;;
    *) fail "unknown tool: $t" ;;
  esac
done
