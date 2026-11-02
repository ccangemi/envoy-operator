# An init container creates the pod mutator webhook

The agent router controller (v1.2) stops at startup unless the MutatingWebhookConfiguration `envoy-ai-gateway-gateway-pod-mutator.<namespace>` exists, and OLM-managed webhooks (`webhookdefinitions`) get a generated name. So the bootstrap init container creates it with the fixed name at every pod start (server-side apply), the OpenShift service CA issues and rotates the serving certificate and injects the CA bundle, and owner references to the OLM cluster roles make Kubernetes delete it on uninstall. The same container creates the MCP session encryption seed with a random value, because a static secret in the bundle would be public and identical on every cluster.

## Consequences

- The bundle contains no webhook configuration and no `webhookdefinitions`; the bundle gate checks both.
- On upgrade, the bootstrap moves the owner references to the new cluster roles.
- This is a workaround: remove it when the agent router accepts a webhook configuration it did not create. Check at every upstream upgrade.
