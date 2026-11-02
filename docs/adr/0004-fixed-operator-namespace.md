# The operator works only in envoy-gateway-system

The pod mutator webhook name, its RBAC rule and the Envoy Gateway extension manager address all contain the namespace. So the operator supports only `envoy-gateway-system`. In any other namespace, the bootstrap stops with a clear message.

Both controllers run in this one namespace. The `agent-router-ocp` Helm chart used two namespaces.

The CSV supports only the "All namespaces" install mode, because Envoy Gateway watches Gateways in every namespace.

## Considered Options

- **Two separate operators**, one for each controller. Rejected:
  - OLM dependencies between operators in the same namespace;
  - two bundles to maintain and release;
  - certgen runs in the agent router pod but creates the certificates for Envoy Gateway, so the two controllers are not independent.
- **A namespace chosen at install time.** OLM has no install-time parameter for this, so it would need one bundle per namespace.
- **Two namespaces, as in the Helm chart.** One OLM installation cannot span two namespaces.
