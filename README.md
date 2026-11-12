# envoy-gateway-operator

A community operator for [Operator Lifecycle Manager (OLM)](https://olm.operatorframework.io/)
that installs [Envoy Gateway](https://gateway.envoyproxy.io/) on OpenShift.

It is a Helm operator, built with [Operator SDK](https://sdk.operatorframework.io/).
It installs the upstream `gateway-helm` chart, unchanged, with the values that
OpenShift needs. The operator uses the Gateway API that OpenShift provides: it
never installs, changes or removes the Gateway API CRDs.

> This is a community project. It is not affiliated with, or endorsed by, the
> Envoy project.

## Versions

| Component | Version |
|---|---|
| Operator | 0.1.1 (channel `alpha`) |
| Envoy Gateway | v1.9.3 |
| OpenShift | 4.22 only (Gateway API v1.4.1) |
| helm-operator (Operator SDK) | v1.42.3 |

The file [versions.env](versions.env) defines these versions.

## How it works

* You install the operator in the namespace `envoy-gateway-system`, with the
  "A specific namespace on the cluster" install mode.
* You create one `EnvoyGateway` resource, named `envoy-gateway`, in that
  namespace. Its spec holds the chart values: the values of the upstream chart
  go under the key `gateway-helm`.
* The operator installs the chart as a Helm release in the same namespace, and
  keeps the release in line with the spec.
* OLM installs and upgrades the Envoy Gateway CRDs (`gateway.envoyproxy.io`).
  They come with the operator bundle, not with the Helm release.

```yaml
apiVersion: envoygateway.ccangemi.github.io/v1alpha1
kind: EnvoyGateway
metadata:
  name: envoy-gateway
  namespace: envoy-gateway-system
spec:
  gateway-helm:
    deployment:
      replicas: 2
```

The operator does not create any GatewayClass, Gateway or route. You create
them, for example with a Helm chart that Argo CD syncs.

## Quick start

1. Make sure that the cluster runs OpenShift 4.22.
2. Install the operator. See [docs/install.md](docs/install.md).
3. Create the `EnvoyGateway` resource. The directory [samples/ocp](samples/ocp)
   has examples, also one for [The Agent Router](https://github.com/theagentrouter/agent-router).
4. Create a GatewayClass, a Gateway and a route. The directory
   [samples/ocp/test](samples/ocp/test) has a complete example with a test
   backend.

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
| `versions.env` | The versions of the operator and of the upstream chart |
| `watches.yaml` | The custom resource that the operator watches, and its chart |
| `helm-charts/envoy-gateway/` | The operator chart: OpenShift values and checks |
| `helm-charts/envoy-gateway/charts/gateway-helm/` | The upstream chart, unchanged |
| `config/` | Kustomize inputs of the bundle: CRDs, RBAC, manager, CSV base |
| `hack/` | Scripts: tools, upstream update, generators, safety gate, tests |
| `bundle/` | The generated OLM bundle (committed, do not edit by hand) |
| `samples/ocp/` | Example resources for OpenShift |
| `community/` | Files for the community catalog pull request |
| `docs/` | Documentation |

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
