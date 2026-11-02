# Troubleshooting

## The operator does not install

**OLM reports `RequirementsNotMet` for native APIs.** The cluster does not
serve the Gateway API v1.4 kinds. The operator needs OpenShift 4.22 or later.

**The InstallPlan fails with `ResourceExhausted ... larger than max`.** The
catalog serves the bundle objects inline, and they are larger than the 2 MiB
gRPC limit. Use a catalog with `olm.csv.metadata` and a bundle image. See
[openshift.md](openshift.md#bundle-size).

## The agent router pod does not start

Check the init containers:

```console
$ oc logs -n envoy-gateway-system deployment/ai-gateway-controller -c envoy-gateway-certgen
$ oc logs -n envoy-gateway-system deployment/ai-gateway-controller -c ar-bootstrap
```

**`the operator runs in namespace 'X', but it supports only 'envoy-gateway-system'`.**
Uninstall the operator and install it again in `envoy-gateway-system`.

**The pod stays in `ContainerCreating` or `Init:0/2`.** The pod waits for the
secret `ai-gateway-controller-tls` and for the CA in the config map
`ai-gateway-controller-service-ca`. The OpenShift service CA creates both.
Check the service CA operator:

```console
$ oc get clusteroperator service-ca
$ oc get secret ai-gateway-controller-tls -n envoy-gateway-system
$ oc get configmap ai-gateway-controller-service-ca -n envoy-gateway-system -o yaml
```

**`failed to patch admission webhook`** in the controller log. The webhook
configuration does not exist or has more than one webhook. The bootstrap
creates it; check its log.

## The Envoy Gateway pod stays in `ContainerCreating`

The pod mounts the secret `envoy-gateway`, which certgen creates in the agent
router pod. Fix the agent router pod first.

## The Gateway is not programmed, or the proxy pod does not start

**`unable to validate against any security context constraint`** in the
events of the proxy ReplicaSet. The service account of the Gateway does not
have the `nonroot-v2` SCC. See
[install.md](install.md#1-allow-the-envoy-proxy-to-run-scc).

**The proxy pod has no `ai-gateway-extproc` init container.** The pod was
created before the webhook was ready. Delete the pod; the new pod gets the
sidecar.

**Pod creation fails with `failed calling webhook`.** The agent router
controller is not ready, or a network policy blocks the API server. See the
network policy table in [install.md](install.md#3-network-policies).

**The Gateway stays `Programmed=False` with network policies.** The proxies
cannot reach Envoy Gateway on port 18000.

## Leftovers after uninstall

OLM deletes the deployments, the service accounts, the RBAC and (through the
owner references) the webhook configuration. These objects stay:

* the CRDs `*.gateway.envoyproxy.io` and `*.aigateway.envoyproxy.io`: OLM never
  deletes CRDs;
* in `envoy-gateway-system`: the secrets `envoy-gateway`, `envoy`,
  `envoy-rate-limit`, `envoy-oidc-hmac` (certgen),
  `ai-gateway-controller-mcp-session-encryption` (bootstrap) and
  `ai-gateway-controller-tls` (service CA);
* in the Gateway namespaces: the filter configuration secrets of the agent
  router (`<gateway>-<namespace>-<hash>`).

For a full cleanup, after you delete all Gateways and routes:

```console
$ oc delete namespace envoy-gateway-system
$ oc get crd -o name | grep -E '\.(ai)?gateway\.envoyproxy\.io$' | xargs oc delete
```

Never delete the `*.gateway.networking.k8s.io` CRDs: they belong to OpenShift.
