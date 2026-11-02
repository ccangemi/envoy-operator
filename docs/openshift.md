# OpenShift design notes

This page explains how the bundle differs from the upstream Helm charts, and
why. `hack/generate-bundle.sh` makes all the changes, and
`hack/bundle-gate.sh` checks them on every pull request.

## The Gateway API belongs to OpenShift

OpenShift 4.22 ships the Gateway API v1.4.1 (standard channel, 6 CRDs). The
Ingress Operator owns these CRDs, and the admission policy
`openshift-ingress-operator-gatewayapi-crd-admission` rejects changes from
anyone else.

The upstream `gateway-helm` chart contains the Gateway API CRDs and a
`safe-upgrades` ValidatingAdmissionPolicy. That policy would also block the
Ingress Operator. The bundle contains neither of them:

* the generator renders only the Envoy Gateway CRDs from
  `gateway-crds-helm` (`crds.gatewayAPI.enabled=false`);
* the gate fails if the bundle contains a CRD of the group
  `gateway.networking.k8s.io`, any admission policy, or a namespace;
* the end-to-end tests take a snapshot of the Gateway API CRDs (name, UID,
  generation, bundle version) before the installation and compare it after
  the test.

The ClusterServiceVersion declares the Gateway API kinds in `nativeAPIs`. OLM
refuses to install the operator on a cluster that does not serve them.

### Gateway API version

The Agent Router v1.2 and Envoy Gateway v1.9 are tested upstream with Gateway
API v1.6. OpenShift 4.22 has v1.4.1. On v1.4.1, Envoy Gateway skips the APIs
that do not exist (for example `TCPRoute` and `UDPRoute` v1). The HTTP and AI
features work: the end-to-end test sends a chat completion through a Gateway.

## Security context constraints

The upstream charts set the fixed user and group ID 65532 for the
controllers. The `restricted-v2` SCC does not allow fixed IDs. The generator
removes `runAsUser`, `runAsGroup` and `fsGroup`, so OpenShift assigns IDs from
the namespace range. The controllers then run with `restricted-v2`, and the
bundle contains no SCC grant.

Envoy Gateway always runs the Envoy proxy with user ID 65532, and an
`EnvoyProxy` cannot remove it. The proxies therefore need the `nonroot-v2`
SCC, through a RoleBinding in each Gateway namespace. See
[install.md](install.md#1-allow-the-envoy-proxy-to-run-scc).

## Certificates for Envoy Gateway (certgen)

Envoy Gateway needs TLS certificates for the xDS connection to the proxies.
The upstream chart creates them with a Helm hook Job (`certgen`). OLM cannot
run Jobs, so the bundle runs `envoy-gateway certgen` as an init container.

The init container runs in the agent router pod, not in the Envoy Gateway
pod. The Envoy Gateway pod mounts the secret that certgen creates, and the
kubelet mounts all volumes before it starts the init containers. In the same
pod, the secret could never exist in time.

certgen does not overwrite existing secrets, so it is safe to run it at every
start. The certificates are valid for about 5 years.

## The agent router webhook

The agent router controller mutates the Envoy proxy pods: it adds the
external processor sidecar. Its mutating webhook configuration must have the
fixed name `envoy-ai-gateway-gateway-pod-mutator.<namespace>`: the controller
v1.2 stops at startup when it cannot find it.

OLM can manage webhooks (`webhookdefinitions`), but it gives them a generated
name. So the bundle uses a different approach:

* An init container (`ar-bootstrap`, a Python script with only the standard
  library, see `config/bootstrap/ar-bootstrap.py`) creates the webhook
  configuration with the fixed name, at every start of the pod. It uses
  server-side apply with its own field manager.
* The OpenShift service CA issues the serving certificate (annotation
  `service.beta.openshift.io/serving-cert-secret-name` on the Service), and
  injects the CA bundle into the webhook configuration (annotation
  `service.beta.openshift.io/inject-cabundle`). The service CA also renews
  the certificate, so the 365-day expiry of the Helm chart certificate is no
  longer a problem.
* The webhook configuration has owner references to the cluster roles that
  OLM creates for the operator. When you uninstall the operator, OLM deletes
  the cluster roles, and Kubernetes deletes the webhook configuration.
* The webhook selects only the pods with the label
  `app.kubernetes.io/managed-by: envoy-gateway` (the Envoy proxies), with
  `failurePolicy: Fail`.

The script also creates the secret with the MCP session encryption seed, with
a random value. A static secret in the bundle would be public and the same on
every cluster.

This is a workaround. When the agent router can work with a webhook
configuration that it did not create, the bootstrap can go away.

## One fixed namespace

The webhook name, the RBAC rule for the webhook and the Envoy Gateway
extension manager address all contain the namespace. So the operator works
only in `envoy-gateway-system`: the bootstrap init container stops with a
clear message in any other namespace. The ClusterServiceVersion suggests this
namespace, and supports only the "All namespaces" install mode, because Envoy
Gateway watches Gateways in all namespaces.

Both controllers run in the same namespace. This is a change from the
`agent-router-ocp` Helm chart, which used two namespaces.

## Envoy Gateway configuration

The bundle contains the config map `envoy-gateway-config`, with the settings
of the tested Helm chart:

* `controllerName: gateway.envoyproxy.io/gatewayclass-controller`;
* `provider.kubernetes.deploy.type: GatewayNamespace`: the proxy of each
  Gateway runs in the namespace of the Gateway;
* `extensionApis.enableBackend` and `enableEnvoyPatchPolicy`, and the
  `extensionManager` hooks that point to the agent router controller;
* the topology injector is disabled. It is a cluster-wide pod webhook that
  the platform does not need.

The configuration has no `provider.kubernetes.watch` block. With a watch
block, Envoy Gateway uses namespaced RBAC and fails.

## InferencePool CRDs

The bundle does not contain the Gateway API Inference Extension CRDs. On
clusters with OpenShift AI, KServe owns `inferencepools.inference.networking.k8s.io`
and restores its own version. Two owners would overwrite each other. The agent
router controller works without these CRDs: it skips the `InferencePool`
controller when the CRD does not exist.

## Images

Every image is pinned by digest and listed in `spec.relatedImages`:

| Name | Image |
|---|---|
| `envoy-gateway` | `docker.io/envoyproxy/gateway` (controller, certgen, shutdown manager) |
| `envoy-proxy` | `docker.io/envoyproxy/envoy` (default image of Envoy Gateway) |
| `envoy-ratelimit` | `docker.io/envoyproxy/ratelimit` |
| `ai-gateway-controller` | `docker.io/envoyproxy/ai-gateway-controller` |
| `ai-gateway-extproc` | `docker.io/envoyproxy/ai-gateway-extproc` |
| `bootstrap` | `registry.access.redhat.com/ubi9/python-312-minimal` |

## Bundle size

The Envoy Gateway and agent router CRDs are large: about 4.4 MB of YAML. OLM
stores the bundle compressed in a config map (limit 1 MiB). The compressed
manifests are about 0.6 MB, and the gate fails above 900 kB.

A catalog cannot serve this bundle inline: the bundle objects are larger than
the 2 MiB gRPC message limit of OLM. The local test catalog of the kind test
(`hack/build-catalog.sh`) therefore stores only the CSV metadata
(`olm.csv.metadata`), like the community catalogs, and OLM pulls the bundle
image.
