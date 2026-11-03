#!/usr/bin/env bash
# Installs the pinned tools in bin/ and checks their SHA-256 sums.
# The generated bundle depends on the exact tool versions, so everyone (and the
# CI) must use the same ones.
#
#   hack/tools.sh                 install helm, yq, kustomize, operator-sdk and opm
#   hack/tools.sh helm-operator   install helm-operator (for `make run`)
#   hack/tools.sh helm yq         install only some tools
#
# To move a tool to a new version, change the version and both sums in the
# table below. Take the sums from the checksum file of the upstream release.

# shellcheck source=hack/lib.sh
source "$(dirname "$0")/lib.sh"

case $(uname -s)/$(uname -m) in
  Linux/x86_64) ARCH=amd64 ;;
  Linux/aarch64 | Linux/arm64) ARCH=arm64 ;;
  *) fail "no pinned tools for $(uname -s)/$(uname -m)" ;;
esac

# tool <name>: prints "<version> <url> <sha256> <path in archive>" for this
# architecture. The path is "-" when the download is the binary itself.
# helm-operator must stay at the version of the base image in the Dockerfile.
tool() {
  local v
  case $1/$ARCH in
    helm/amd64) v=v3.22.0; echo "$v https://get.helm.sh/helm-$v-linux-amd64.tar.gz 1e4ab49e429626cf6c6958d914248b78c9730803c2751b87627e171dc800e7bb linux-amd64/helm" ;;
    helm/arm64) v=v3.22.0; echo "$v https://get.helm.sh/helm-$v-linux-arm64.tar.gz f14e804dfee240f55525b667488fe9adca349e63e00c9af634c0beb1421ac310 linux-arm64/helm" ;;
    yq/amd64) v=v4.53.3; echo "$v https://github.com/mikefarah/yq/releases/download/$v/yq_linux_amd64 fa52a4e758c63d38299163fbdd1edfb4c4963247918bf9c1c5d31d84789eded4 -" ;;
    yq/arm64) v=v4.53.3; echo "$v https://github.com/mikefarah/yq/releases/download/$v/yq_linux_arm64 578648e463a11c1b6db6010cbf41eafed6bee79466fcffa1bb446672cf7945ea -" ;;
    kustomize/amd64) v=v5.8.3; echo "$v https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F$v/kustomize_${v}_linux_amd64.tar.gz cb9e31198d3f63b44848bd0afc4c8efc56e6cfef9c93a4a39a211940e6decd61 kustomize" ;;
    kustomize/arm64) v=v5.8.3; echo "$v https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F$v/kustomize_${v}_linux_arm64.tar.gz 9867b76482cfc6d25b546abc1d2b5a32bd137505aba640649b4b378f64f6d68f kustomize" ;;
    operator-sdk/amd64) v=v1.42.3; echo "$v https://github.com/operator-framework/operator-sdk/releases/download/$v/operator-sdk_linux_amd64 887a3bb0d63ccc4ca47a522d0c8ffac56d9d5246f6a2bd886b4ed23eb2e2672f -" ;;
    operator-sdk/arm64) v=v1.42.3; echo "$v https://github.com/operator-framework/operator-sdk/releases/download/$v/operator-sdk_linux_arm64 6db93cd821b429f0bb514cea4bbb5553827d273fc8aa211f13e14798599d31cd -" ;;
    opm/amd64) v=v1.74.0; echo "$v https://github.com/operator-framework/operator-registry/releases/download/$v/linux-amd64-opm cf1bd699be72e0a4511208afdf45444fc47d21eb2ffed0c204520ff50b5a4691 -" ;;
    opm/arm64) v=v1.74.0; echo "$v https://github.com/operator-framework/operator-registry/releases/download/$v/linux-arm64-opm 348a9682975eb220bea3b98b83aa82dc6d2630e6868331ed9bf14f97e462d8be -" ;;
    helm-operator/amd64) v=v1.42.3; echo "$v https://github.com/operator-framework/operator-sdk/releases/download/$v/helm-operator_linux_amd64 f244bb81bc00afabfcbd1e23070ca9c18f4cfe09bf7a8dbbcbe2999df739cf92 -" ;;
    helm-operator/arm64) v=v1.42.3; echo "$v https://github.com/operator-framework/operator-sdk/releases/download/$v/helm-operator_linux_arm64 44f24480e85f38e3f9c976092a4aa996567b893723842f9ded0d264a31c7ec35 -" ;;
    *) return 1 ;;
  esac
}

# install <name>: downloads the tool to a temporary directory, checks the sum,
# then moves the binary to bin/<name>. A stamp file records the version, so a
# tool that is already installed at the right version is not downloaded again.
install() {
  local name=$1 version url sum path stamp tmp
  read -r version url sum path < <(tool "$name") || fail "unknown tool: $name"
  stamp=$BIN_DIR/.$name-version
  if [[ -x $BIN_DIR/$name && -f $stamp && $(cat "$stamp") == "$version" ]]; then
    return
  fi
  log "installing $name $version"
  tmp=$(mktemp -d)
  curl -sSfL --retry 3 -o "$tmp/download" "$url" || { rm -rf "$tmp"; fail "cannot download $url"; }
  if ! sha256sum -c --status <<<"$sum  $tmp/download"; then
    rm -rf "$tmp"
    fail "$url does not match its pinned SHA-256 sum"
  fi
  if [[ $path == - ]]; then
    mv "$tmp/download" "$tmp/bin"
  else
    tar -xzf "$tmp/download" -C "$tmp" "$path"
    mv "$tmp/$path" "$tmp/bin"
  fi
  chmod +x "$tmp/bin"
  mv "$tmp/bin" "$BIN_DIR/$name"
  rm -rf "$tmp"
  echo "$version" >"$stamp"
}

mkdir -p "$BIN_DIR"
tools=("$@")
[[ ${#tools[@]} -gt 0 ]] || tools=(helm yq kustomize operator-sdk opm)
for t in "${tools[@]}"; do
  install "$t"
done
