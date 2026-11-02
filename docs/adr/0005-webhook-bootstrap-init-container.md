# An init container creates the pod mutator webhook

The agent router controller (v1.2) stops at startup when the MutatingWebhookConfiguration `envoy-ai-gateway-gateway-pod-mutator.<namespace>` does not exist. OLM-managed webhooks (`webhookdefinitions`) get a generated name, so OLM cannot create it.

So the bootstrap init container creates the webhook configuration with the fixed name, at every pod start, with server-side apply:

- The OpenShift service CA issues and rotates the serving certificate, and injects the CA bundle.
- Owner references to the OLM cluster roles make Kubernetes delete the webhook configuration when the operator is uninstalled.

The same container creates the MCP session encryption seed with a random value. A static secret in the bundle would be public and the same on every cluster.

## Consequences

- The bundle contains no webhook configuration and no `webhookdefinitions`. The bundle gate checks both.
- During an upgrade, the bootstrap moves the owner references to the new cluster roles.
- This is a workaround. Remove it when the agent router accepts a webhook configuration that it did not create. Check this at every upstream upgrade.
