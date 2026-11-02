# The operator is only an OLM bundle of the upstream controllers

The operator packages Envoy Gateway and The Agent Router as one OLM bundle. The generator builds it from the upstream charts. The operator has no controller of its own and no custom resource for the installation. When you install the operator, you install the controllers. Users create the Gateway resources themselves, for example with Argo CD.

We chose this to stay close to upstream. An upgrade is then a change in `versions.env`. The cost: we must work around the limits of OLM (no Jobs, generated webhook names) in the generator and in the bootstrap, not in code.

## Consequences

- Every OpenShift adaptation lives in `hack/generate-bundle.sh`. The bundle gate enforces it.
- Anything that OLM cannot create needs a workaround (see ADR-0005 and ADR-0006).
