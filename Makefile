# envoy-operator Makefile. Run `make help` for the list of targets.

SHELL := /usr/bin/env bash -o pipefail
.SHELLFLAGS := -ec
.DEFAULT_GOAL := help

include versions.env

CONTAINER_TOOL ?= $(shell command -v podman >/dev/null 2>&1 && echo podman || echo docker)
# Images for local tests only. The community catalog pipeline builds the
# published bundle image itself.
IMAGE_REGISTRY ?= localhost:5001
IMAGE_TAG ?= v$(OPERATOR_VERSION)
BUNDLE_IMAGE ?= $(IMAGE_REGISTRY)/envoy-operator-bundle:$(IMAGE_TAG)
CATALOG_IMAGE ?= $(IMAGE_REGISTRY)/envoy-operator-catalog:$(IMAGE_TAG)

BIN := $(CURDIR)/bin
OPERATOR_SDK := $(BIN)/operator-sdk

##@ General

.PHONY: help
help: ## Show this help.
	@awk 'BEGIN {FS = ":.*##"; printf "Usage: make <target>\n"} \
	  /^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2 } \
	  /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

.PHONY: tools
tools: ## Install the pinned tools (helm, yq, operator-sdk, opm) in bin/.
	hack/tools.sh

##@ Bundle

.PHONY: bundle
bundle: tools ## Generate bundle/ from the upstream charts (needs network access).
	hack/generate-bundle.sh

.PHONY: bundle-gate
bundle-gate: tools ## Run the offline safety checks on bundle/.
	hack/bundle-gate.sh

.PHONY: test-gate
test-gate: tools ## Test that every bundle-gate check detects a broken bundle.
	hack/test-bundle-gate.sh

.PHONY: validate
validate: tools ## Validate bundle/ with operator-sdk (operatorframework and community suites).
	$(OPERATOR_SDK) bundle validate ./bundle --select-optional suite=operatorframework
	$(OPERATOR_SDK) bundle validate ./bundle --select-optional name=community \
	  --optional-values=index-path=bundle.Dockerfile

.PHONY: bundle-check
bundle-check: bundle ## Regenerate bundle/ and fail if it differs from the committed files.
	@if [[ -n "$$(git status --porcelain -- bundle bundle.Dockerfile)" ]]; then \
	  git status --short -- bundle bundle.Dockerfile; \
	  echo "ERROR: bundle/ is not up to date. Run 'make bundle' and commit the result."; \
	  exit 1; \
	fi

.PHONY: lint
lint: ## Run shellcheck and yamllint (they must be installed).
	shellcheck -x hack/*.sh hack/e2e/*.sh
	python3 -I -m py_compile config/bootstrap/ar-bootstrap.py
	yamllint -c .yamllint.yaml .

.PHONY: check
check: lint bundle-gate test-gate validate ## Run all offline checks, like the CI.

##@ Images and catalog

.PHONY: bundle-image
bundle-image: ## Build a local bundle image (BUNDLE_IMAGE), for tests.
	$(CONTAINER_TOOL) build -f bundle.Dockerfile -t $(BUNDLE_IMAGE) .

.PHONY: catalog
catalog: tools ## Generate a test catalog in build/catalog for BUNDLE_IMAGE.
	hack/build-catalog.sh build/catalog bundle=$(BUNDLE_IMAGE)

.PHONY: catalog-image
catalog-image: catalog ## Build a local test catalog image (CATALOG_IMAGE).
	$(CONTAINER_TOOL) build -f catalog.Dockerfile -t $(CATALOG_IMAGE) .

.PHONY: community
community: ## Prepare build/community/operators/envoy-operator for the community catalog.
	hack/community-layout.sh

##@ End-to-end tests

.PHONY: e2e-kind
e2e-kind: tools ## Run the end-to-end test on a kind cluster (needs kind and a container tool).
	hack/e2e/kind.sh

.PHONY: e2e-ocp
e2e-ocp: tools ## Install from the community catalog and test on OpenShift (needs KUBECONFIG).
	hack/e2e/ocp.sh all

.PHONY: e2e-ocp-uninstall
e2e-ocp-uninstall: tools ## Uninstall the operator and the examples from OpenShift.
	hack/e2e/ocp.sh uninstall

.PHONY: direct-install
direct-install: tools ## Install bundle/ without OLM, for debugging (needs KUBECONFIG).
	hack/e2e/direct-install.sh apply
