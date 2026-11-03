# envoy-gateway-operator Makefile. Run `make help` for the list of targets.

SHELL := /usr/bin/env bash -o pipefail
.SHELLFLAGS := -ec
.DEFAULT_GOAL := help

include versions.env

CONTAINER_TOOL ?= $(shell command -v podman >/dev/null 2>&1 && echo podman || echo docker)
# Images for local tests only. The release workflow builds and pushes the
# published operator image; the community catalog pipeline builds the bundle
# image.
IMAGE_TAG ?= v$(OPERATOR_VERSION)
IMG ?= $(OPERATOR_IMAGE_REPOSITORY):$(IMAGE_TAG)
BUNDLE_IMG ?= $(OPERATOR_IMAGE_REPOSITORY)-bundle:$(IMAGE_TAG)
CATALOG_IMG ?= $(OPERATOR_IMAGE_REPOSITORY)-catalog:$(IMAGE_TAG)
PACKAGE := envoy-gateway-operator

BIN := $(CURDIR)/bin
OPERATOR_SDK := $(BIN)/operator-sdk
KUSTOMIZE := $(BIN)/kustomize
KUBECTL ?= oc

##@ General

.PHONY: help
help: ## Show this help.
	@awk 'BEGIN {FS = ":.*##"; printf "Usage: make <target>\n"} \
	  /^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2 } \
	  /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

.PHONY: tools
tools: ## Install the pinned tools (helm, yq, kustomize, operator-sdk, opm) in bin/.
	hack/tools.sh

##@ Upstream

.PHONY: update-upstream
update-upstream: tools ## Pull the chart and CRDs of versions.env, pin the images, regenerate the RBAC (needs network access).
	hack/update-upstream.sh

.PHONY: chart-check
chart-check: tools ## Check that the chart and the CRDs are the upstream ones, unchanged (needs network access).
	hack/chart-check.sh

.PHONY: rbac-check
rbac-check: tools ## Check that config/rbac/role.yaml matches the chart.
	hack/generate-rbac.sh --check

##@ Bundle

.PHONY: bundle
bundle: tools ## Generate bundle/ and bundle.Dockerfile (offline).
	hack/generate-bundle.sh

.PHONY: bundle-check
bundle-check: bundle ## Regenerate bundle/ and fail if it differs from the committed files.
	@if [[ -n "$$(git status --porcelain -- bundle bundle.Dockerfile)" ]]; then \
	  git status --short -- bundle bundle.Dockerfile; \
	  echo "ERROR: bundle/ is not up to date. Run 'make bundle' and commit the result."; \
	  exit 1; \
	fi

.PHONY: bundle-gate
bundle-gate: tools ## Run the offline safety checks on bundle/ and on the operator chart.
	hack/bundle-gate.sh

.PHONY: test-gate
test-gate: tools ## Test that every bundle-gate check detects a broken bundle or chart.
	hack/test-bundle-gate.sh

.PHONY: validate
validate: tools ## Validate bundle/ with operator-sdk (operatorframework and community suites).
	$(OPERATOR_SDK) bundle validate ./bundle --select-optional suite=operatorframework
	$(OPERATOR_SDK) bundle validate ./bundle --select-optional name=community \
	  --optional-values=index-path=bundle.Dockerfile

.PHONY: lint
lint: ## Run shellcheck, a Python syntax check and yamllint (they must be installed).
	shellcheck -x hack/*.sh hack/e2e/*.sh
	python3 -I -m py_compile hack/rbac.py
	yamllint -c .yamllint.yaml .

.PHONY: check
check: lint rbac-check bundle-gate test-gate validate ## Run all offline checks, like the CI.

##@ Catalog and community

.PHONY: catalog
catalog: tools ## Generate a test catalog in build/catalog for BUNDLE_IMG.
	hack/build-catalog.sh build/catalog bundle=$(BUNDLE_IMG)

.PHONY: catalog-image
catalog-image: catalog ## Build a local test catalog image (CATALOG_IMG).
	$(CONTAINER_TOOL) build -f catalog.Dockerfile -t $(CATALOG_IMG) .

.PHONY: community
community: ## Prepare build/community/operators/$(PACKAGE) for the community catalog.
	hack/community-layout.sh

##@ End-to-end tests (OpenShift)

.PHONY: build-on-cluster
build-on-cluster: tools ## Build the operator, bundle and catalog images in the cluster (needs KUBECONFIG).
	hack/e2e/build-on-cluster.sh

.PHONY: e2e-ocp
e2e-ocp: tools ## Install with OLM and test on OpenShift; set CATALOG_IMAGE for a test catalog (needs KUBECONFIG).
	hack/e2e/ocp.sh all

.PHONY: e2e-ocp-uninstall
e2e-ocp-uninstall: tools ## Delete the examples and the resource, and uninstall the operator (needs KUBECONFIG).
	hack/e2e/ocp.sh uninstall

##@ Development

.PHONY: install-crds
install-crds: tools ## Apply the CRDs of config/crd to the cluster (needs KUBECONFIG).
	$(KUSTOMIZE) build config/crd | $(KUBECTL) apply --server-side -f -

.PHONY: run
run: tools install-crds ## Run the operator on your machine against the cluster, in OPERATOR_NAMESPACE (needs KUBECONFIG).
	hack/tools.sh helm-operator
	WATCH_NAMESPACE=$(OPERATOR_NAMESPACE) $(BIN)/helm-operator run --watches-file watches.yaml \
	  --leader-elect=false --health-probe-bind-address=:8081

.PHONY: docker-build
docker-build: ## Build the operator image (IMG) for local tests.
	$(CONTAINER_TOOL) build -t $(IMG) .

.PHONY: bundle-build
bundle-build: ## Build the bundle image (BUNDLE_IMG) for local tests.
	$(CONTAINER_TOOL) build -f bundle.Dockerfile -t $(BUNDLE_IMG) .
