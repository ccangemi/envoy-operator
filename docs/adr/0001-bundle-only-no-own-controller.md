# The operator is only an OLM bundle of the upstream controllers

The operator packages Envoy Gateway and The Agent Router as an OLM bundle generated from the upstream charts. It has no controller of its own and no custom resource for the installation: installing the operator installs the controllers, and users create the Gateway resources themselves (for example with Argo CD). We chose this to stay as close to upstream as possible and keep upgrades a matter of changing `versions.env`, at the cost of handling OLM's limits (no Jobs, generated webhook names) in the generator and the bootstrap instead of in code.

## Consequences

- Every OpenShift adaptation lives in `hack/generate-bundle.sh` and is enforced by the bundle gate.
- Anything OLM cannot create needs a workaround (see ADR-0005, ADR-0006).
