# envoy-operator

A community operator for [Operator Lifecycle Manager (OLM)](https://olm.operatorframework.io/).
It installs [Envoy Gateway](https://gateway.envoyproxy.io/) and
[The Agent Router](https://github.com/theagentrouter/agent-router)
(formerly Envoy AI Gateway) on OpenShift.

The operator uses the Gateway API that OpenShift already provides. It never
installs, changes or removes the Gateway API CRDs.

> This is a community project. It is not affiliated with, or endorsed by, the
> Envoy project.

## Status

Work in progress. See the open pull requests.

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
