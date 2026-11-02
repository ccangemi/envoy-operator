# The bundle never ships the Gateway API CRDs

On OpenShift the Ingress Operator owns the `gateway.networking.k8s.io` CRDs, and an admission policy rejects changes from anyone else. So the bundle never ships, changes or removes them, nor the upstream `safe-upgrades` ValidatingAdmissionPolicy (which would also block the Ingress Operator). The CSV declares the Gateway API kinds in `nativeAPIs` instead, and we accept running on OpenShift's Gateway API version (v1.4.1 on 4.22) even though upstream tests with a newer one.

## Consequences

- The bundle gate fails on any CRD of that group and on any admission policy.
- The end-to-end tests snapshot the Gateway API CRDs before the install and compare them after.
- Do not "fix" missing Gateway API features by shipping newer CRDs: wait for OpenShift.
