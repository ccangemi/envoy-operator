# certgen runs as an init container in the agent router pod

Upstream creates the xDS certificates with a Helm hook Job, and OLM cannot run Jobs, so the bundle runs `envoy-gateway certgen` as an init container. It runs in the agent router pod, not the Envoy Gateway pod: the Envoy Gateway pod mounts the secret that certgen creates, and the kubelet mounts all volumes before init containers start, so in the same pod the secret could never exist in time. certgen does not overwrite existing secrets, so running it at every start is safe.
