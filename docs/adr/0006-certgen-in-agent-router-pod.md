# certgen runs as an init container in the agent router pod

Upstream creates the xDS certificates with a Helm hook Job. OLM cannot run Jobs, so the bundle runs `envoy-gateway certgen` as an init container.

It runs in the agent router pod, not in the Envoy Gateway pod. The Envoy Gateway pod mounts the secret that certgen creates. The kubelet mounts all volumes before the init containers start. In the same pod, the secret could never exist in time.

certgen does not overwrite existing secrets, so it is safe to run it at every start.
