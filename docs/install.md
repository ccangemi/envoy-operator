# Installation

## Requirements

* OpenShift 4.22 or later. The operator needs the Gateway API v1.4 APIs,
  including `BackendTLSPolicy` v1. OLM checks this before it installs the
  operator (`nativeAPIs` in the ClusterServiceVersion).
* Cluster administrator rights.
* The cluster must be able to pull images from `docker.io` and
  `registry.access.redhat.com`, or from a mirror (see
  [Disconnected clusters](#disconnected-clusters)).

## Install from the OpenShift console

1. Open **Ecosystem > Software Catalog** (or **Operators > OperatorHub** on
   older consoles) and search for "Envoy Gateway and Agent Router".
2. Select the `alpha` channel.
3. Keep the install mode **All namespaces on the cluster**.
4. Keep the suggested namespace **envoy-gateway-system**. The operator does
   not start in another namespace.
5. Click **Install**.

## Install from the command line

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: envoy-gateway-system
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: envoy-operator
  namespace: envoy-gateway-system
spec: {}            # no target namespaces: "All namespaces" install mode
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: envoy-operator
  namespace: envoy-gateway-system
spec:
  name: envoy-operator
  channel: alpha
  source: community-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Manual   # or Automatic
```

The operator is published only in the OpenShift community catalog
(`community-operators`).

Check the result:

```console
$ oc get csv -n envoy-gateway-system
$ oc get pods -n envoy-gateway-system
```

Both pods (`envoy-gateway` and `ai-gateway-controller`) must be `Running`.

## After the installation

### 1. Allow the Envoy proxy to run (SCC)

Envoy Gateway always runs the Envoy proxy pods with the fixed user ID 65532.
The `restricted-v2` SCC does not allow it. Each Gateway gets a service account
with the same name as the Gateway, in the namespace of the Gateway. Give it
the `nonroot-v2` SCC:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: nonroot-v2-envoy-proxies
  namespace: my-gateways
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:openshift:scc:nonroot-v2
subjects:
  - kind: ServiceAccount
    name: my-gateway          # the name of the Gateway
    namespace: my-gateways
```

Add one subject for each Gateway. If you rename a Gateway, update the
RoleBinding too, or the proxy pods do not start.

### 2. Create a GatewayClass and a Gateway

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: agent-router
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
```

This GatewayClass is independent from the GatewayClass that OpenShift uses
for its own Gateway API implementation (`openshift.io/gateway-controller/v1`).
Both can exist on the same cluster.

The directory [samples/ocp](../samples/ocp) has a complete example: a
namespace, the RoleBinding, a GatewayClass, an `EnvoyProxy`, a Gateway, an
`AIServiceBackend`, an `AIGatewayRoute` and a test backend.

### 3. Network policies

If your namespaces deny traffic by default, allow these flows:

| From | To | Port | Why |
|---|---|---|---|
| Kubernetes API server (host network) | `ai-gateway-controller` in `envoy-gateway-system` | 9443 | Mutating webhook for the proxy pods |
| `envoy-gateway` pod | `ai-gateway-controller` | 1063 | Envoy Gateway extension server |
| Envoy proxy pods (label `app.kubernetes.io/managed-by: envoy-gateway`) | `envoy-gateway` pod | 18000 | xDS configuration |

On OpenShift with OVN-Kubernetes, select the API server with a namespace
selector on the label `policy-group.network.openshift.io/host-network: ""`.

The table does not cover the rate limit flows of `QuotaPolicy` (the agent
router controller listens on port 18002 for them). Test them before you use
`QuotaPolicy` in namespaces that deny traffic by default.

### 4. InferencePool (optional)

The operator does not install the Gateway API Inference Extension CRDs.

* With OpenShift AI (KServe enabled), the CRDs already exist. Do not install
  them again: KServe owns them.
* Without OpenShift AI, install them from the
  [upstream release](https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases).

The agent router controller checks for the `InferencePool` CRD only at
startup. After you install the CRDs, restart it:

```console
$ oc rollout restart deployment/ai-gateway-controller -n envoy-gateway-system
```

## Configuration

You can change the resources, node selectors, tolerations and environment
variables of the controllers with the `spec.config` field of the
Subscription. See the
[OLM documentation](https://olm.operatorframework.io/docs/advanced-tasks/configuring-operators/).
`spec.config` changes only the main containers, not the init containers.

The Envoy Gateway configuration is in the config map
`envoy-gateway-config`. OLM owns it, so OLM restores it on every upgrade. The
operator does not support changes to this file yet.

## Disconnected clusters

The ClusterServiceVersion lists every image in `spec.relatedImages`, pinned
by digest. `oc-mirror` copies them, and an `ImageDigestMirrorSet` redirects
the pulls. The Envoy proxy image is the default image of Envoy Gateway; it is
also in the list.

## Uninstall

1. Delete your Gateways, routes and other custom resources.
2. Uninstall the operator in the console, or delete the Subscription and the
   ClusterServiceVersion:

   ```console
   $ oc delete subscription envoy-operator -n envoy-gateway-system
   $ oc delete csv -n envoy-gateway-system -l operators.coreos.com/envoy-operator.envoy-gateway-system
   ```

The mutating webhook configuration is deleted with the operator. OLM never
deletes CRDs. The secrets that certgen created stay in the namespace. See
[troubleshooting.md](troubleshooting.md#leftovers-after-uninstall) for a full
cleanup.

The Gateway API CRDs of OpenShift are never touched.
