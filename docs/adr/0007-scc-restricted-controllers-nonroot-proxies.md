# Controllers run with restricted-v2; each Envoy proxy needs nonroot-v2

The generator removes the fixed user and group ID 65532 from the controllers. They run with `restricted-v2` and get IDs from the namespace range. The bundle contains no SCC grant.

Envoy Gateway always runs the Envoy proxy with user ID 65532, and an `EnvoyProxy` cannot change it. Each Gateway gets a service account with the same name as the Gateway, in the Gateway namespace. A RoleBinding must give `nonroot-v2` to that service account. Do not give it to all the service accounts of the namespace.

The bundle does not ship these RoleBindings. They depend on where users create Gateways, so they belong with the Gateway resources (see `samples/ocp` and `docs/install.md`).
