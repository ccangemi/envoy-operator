# The bundle does not ship the InferencePool CRDs

On clusters with OpenShift AI, KServe owns `inferencepools.inference.networking.k8s.io` and restores its own version. A second owner would keep overwriting it. The agent router works without these CRDs: it skips its `InferencePool` controller. So the bundle leaves the CRDs out, and the bundle gate rejects any `inference.networking.*` CRD.

## Consequences

- Without OpenShift AI, users who need `InferencePool` install the CRDs from the upstream release (see `docs/install.md`).
- The agent router controller checks for the CRD only at startup. After the CRDs are installed, restart the controller.
