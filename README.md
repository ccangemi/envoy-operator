# envoy-operator

A community operator for [Operator Lifecycle Manager (OLM)](https://olm.operatorframework.io/).
It installs [Envoy Gateway](https://gateway.envoyproxy.io/) and
[The Agent Router](https://github.com/theagentrouter/agent-router)
(formerly Envoy AI Gateway) on OpenShift.

The operator uses the Gateway API that OpenShift already provides. It never
installs, changes or removes the Gateway API CRDs.

> This is a community project. It is not affiliated with, or endorsed by, the
> Envoy project.

## Versions

| Component | Version |
|---|---|
| Operator | 0.1.0 (channel `alpha`) |
| Envoy Gateway | v1.9.3 |
| The Agent Router | v1.2.0 |
| OpenShift | 4.22 or later (Gateway API v1.4.1) |

The file [versions.env](versions.env) defines these versions.

## What the operator does

* It deploys the Envoy Gateway controller and the agent router controller in
  the namespace `envoy-gateway-system`.
* It owns the Envoy Gateway CRDs (`gateway.envoyproxy.io`) and the agent
  router CRDs (`aigateway.envoyproxy.io`). OLM installs and upgrades them.
* It does not ship the Gateway API CRDs (`gateway.networking.k8s.io`). They
  belong to the OpenShift Ingress Operator, and an admission policy protects
  them.
* It does not ship the Gateway API Inference Extension CRDs (`InferencePool`).
  OpenShift AI provides them.
* It does not create any GatewayClass, Gateway or route. You create them, for
  example with a Helm chart that Argo CD syncs.

The operator is an OLM bundle of the upstream controllers. There is no extra
controller and no custom resource for the installation. See
[docs/openshift.md](docs/openshift.md) for the design and the differences from
the upstream Helm charts.

## Quick start

1. Make sure that the cluster runs OpenShift 4.22 or later.
2. Install the operator in the namespace `envoy-gateway-system` with the
   "All namespaces" install mode. See [docs/install.md](docs/install.md).
3. Create a GatewayClass, a Gateway and an `AIGatewayRoute`. The directory
   [samples/ocp](samples/ocp) has a complete example with a test backend.

## Documentation

* [Installation](docs/install.md)
* [OpenShift design notes](docs/openshift.md)
* [Install with Red Hat Advanced Cluster Management](docs/acm-policy.md)
* [Upgrades](docs/upgrade.md)
* [Troubleshooting](docs/troubleshooting.md)
* [Development, tests and releases](docs/development.md)

## Repository layout

| Path | Content |
|---|---|
| `versions.env` | The versions of the operator and of the upstream components |
| `config/` | Inputs of the bundle generator: Helm values, CSV template, bootstrap script |
| `hack/` | Scripts: tools, generator, bundle gate, catalog, end-to-end tests |
| `bundle/` | The generated OLM bundle (committed, do not edit by hand) |
| `samples/ocp/` | An example Gateway for OpenShift |
| `community/` | Files for the community catalog pull request |
| `docs/` | Documentation |

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
