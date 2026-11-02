# The bundle never ships the Gateway API CRDs

On OpenShift, the Ingress Operator owns the `gateway.networking.k8s.io` CRDs. An admission policy rejects changes from anyone else. So the bundle never ships, changes or removes these CRDs.

The bundle also leaves out the upstream `safe-upgrades` ValidatingAdmissionPolicy. That policy would block the Ingress Operator too.

The CSV declares the Gateway API kinds in `nativeAPIs` instead. We accept the Gateway API version of OpenShift (v1.4.1 on 4.22), even though upstream tests with a newer one.

## Consequences

- The bundle gate fails on any CRD of that group and on any admission policy.
- The end-to-end tests take a snapshot of the Gateway API CRDs before the installation and compare it after.
- Do not add missing Gateway API features by shipping newer CRDs. Wait for OpenShift.
