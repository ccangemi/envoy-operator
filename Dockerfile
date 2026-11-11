# The operator image: the upstream helm-operator with the watches file and the
# chart. Keep the version in step with HELM_OPERATOR_VERSION in hack/tools.sh.
FROM quay.io/operator-framework/helm-operator:v1.42.3@sha256:80e0787ff36e85129d7983dc219736ba8a61e69857fbe46ec7389fddcbbf92f1

LABEL org.opencontainers.image.title="envoy-gateway-operator" \
      org.opencontainers.image.description="Installs Envoy Gateway on OpenShift with its upstream Helm chart" \
      org.opencontainers.image.source="https://github.com/ccangemi/envoy-operator" \
      org.opencontainers.image.licenses="Apache-2.0"

ENV HOME=/opt/helm
COPY LICENSE /licenses/LICENSE
COPY watches.yaml ${HOME}/watches.yaml
COPY helm-charts  ${HOME}/helm-charts
WORKDIR ${HOME}
