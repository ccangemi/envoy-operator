# Installation

## Before you start

* OpenShift 4.22 or later. OLM refuses to install the operator when the cluster
  does not serve the Gateway API v1 kinds, including `BackendTLSPolicy`.
* Cluster administrator rights: the operator installs CRDs, cluster roles and
  a controller that watches all namespaces.

## 1. Install the operator

The operator supports only the OwnNamespace install mode: it reconciles the
`EnvoyGateway` resource of its own namespace. The suggested namespace is
`envoy-gateway-system`.

From the web console: **Operators → OperatorHub**, search for "Envoy Gateway
(Community)", and choose **A specific namespace on the cluster** with the
namespace `envoy-gateway-system`.

From the command line:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: envoy-gateway-system
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: envoy-gateway-operator
  namespace: envoy-gateway-system
spec:
  targetNamespaces:
    - envoy-gateway-system
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: envoy-gateway-operator
  namespace: envoy-gateway-system
spec:
  name: envoy-gateway-operator
  channel: alpha
  source: community-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Manual
```

With `installPlanApproval: Manual`, approve the InstallPlan after you check
it. To install with a policy, see [acm-policy.md](acm-policy.md).

## 2. Create the EnvoyGateway resource

Create one `EnvoyGateway`, named `envoy-gateway`, in the namespace of the
operator. The CRD refuses any other name. The spec holds the values of the
operator chart; the values of the upstream chart go under `gateway-helm`.

```yaml
apiVersion: envoygateway.ccangemi.github.io/v1alpha1
kind: EnvoyGateway
metadata:
  name: envoy-gateway
  namespace: envoy-gateway-system
spec:
  gateway-helm:
    config:
      envoyGateway:
        provider:
          type: Kubernetes
          kubernetes:
            deploy:
              type: GatewayNamespace
```

Wait until the release is deployed:

```console
$ oc get envoygateway -n envoy-gateway-system
NAME            DEPLOYED   REASON              AGE
envoy-gateway   True       InstallSuccessful   1m
```

The operator installs the Envoy Gateway controller and runs the upstream
`certgen` job, which creates the certificates of the control plane.

Some values are fixed by the operator chart, and some are refused. See
[openshift.md](openshift.md#values-that-the-operator-chart-sets).

### Deployment mode

* **ControllerNamespace** (the upstream default): the Envoy proxy of every
  Gateway runs in `envoy-gateway-system`.
* **GatewayNamespace**: the Envoy proxy of each Gateway runs in the namespace
  of the Gateway, with a service account that has the name of the Gateway. Set
  `gateway-helm.config.envoyGateway.provider.kubernetes.deploy.type` as in the
  example above.

### With The Agent Router

The Agent Router (formerly Envoy AI Gateway) needs extension settings in Envoy
Gateway. Use [samples/ocp/envoygateway-with-agent-router.yaml](../samples/ocp/envoygateway-with-agent-router.yaml),
then install the Agent Router operator. Until the Agent Router controller
answers, Envoy Gateway cannot program any Gateway.

## 3. Allow the Envoy proxy to run (SCC)

Envoy Gateway always runs the Envoy proxy with the fixed user ID 65532, and an
`EnvoyProxy` resource cannot remove it. The `restricted-v2` SCC does not allow
it. Give the service account of the proxy the `nonroot-v2` SCC:

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
  # GatewayNamespace mode: one subject per Gateway, named like the Gateway.
  - kind: ServiceAccount
    name: my-gateway
    namespace: my-gateways
```

In ControllerNamespace mode the proxy service accounts are in
`envoy-gateway-system` and have generated names. Bind the group
`system:serviceaccounts:envoy-gateway-system` there instead.

## 4. Create a Gateway

Create a GatewayClass with the controller name
`gateway.envoyproxy.io/gatewayclass-controller`, a Gateway and a route. The
directory [samples/ocp/test](../samples/ocp/test) has a complete example. The
Gateway gets a ClusterIP Service by default; expose it with an OpenShift Route
or with a Service of type LoadBalancer (in an `EnvoyProxy` resource).

## 5. Network policies

When the namespaces have a default-deny policy, allow these flows:

| From | To | Port |
|---|---|---|
| The Envoy proxies (GatewayNamespace mode: the Gateway namespaces) | Envoy Gateway in `envoy-gateway-system` | 18000 (xDS) |
| Envoy Gateway | The Agent Router controller, if you use it | 1063 |
| The kube-apiserver (host network) | The Agent Router webhook, if you use it | 9443 |

## Uninstall

1. Delete the Gateways and routes of Envoy Gateway.
2. Delete the `EnvoyGateway` resource. The operator uninstalls the Helm
   release.
3. Uninstall the operator (delete the Subscription and the
   ClusterServiceVersion).

The CRDs stay: OLM never deletes CRDs. See
[troubleshooting.md](troubleshooting.md#leftovers-after-uninstall).
