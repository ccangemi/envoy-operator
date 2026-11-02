# The operator works only in envoy-gateway-system

The pod mutator webhook name, its RBAC rule and the Envoy Gateway extension manager address all contain the namespace, so the operator supports only `envoy-gateway-system`, and the bootstrap stops with a clear message anywhere else. Both controllers run in that one namespace, unlike the `agent-router-ocp` Helm chart, which used two. The CSV supports only the "All namespaces" install mode, because Envoy Gateway watches Gateways in every namespace.

## Considered Options

- Templating the namespace at install time: OLM has no install-time parameters for this, so it would need one bundle per namespace.
- Two namespaces, as in the Helm chart: one OLM install cannot span two namespaces.
