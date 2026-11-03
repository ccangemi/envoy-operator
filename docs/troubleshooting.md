# Troubleshooting

## The operator does not install

**OLM reports `RequirementsNotMet` for native APIs.** The cluster does not
serve the Gateway API v1 kinds. The operator needs OpenShift 4.22 or later.

**The OperatorGroup does not fit.** The operator supports only the
OwnNamespace install mode. The OperatorGroup must target its own namespace
(`spec.targetNamespaces: [envoy-gateway-system]`).

## The EnvoyGateway resource does not become Deployed

Read the conditions of the resource and the operator log:

```console
$ oc get envoygateway envoy-gateway -n envoy-gateway-system -o yaml
$ oc logs -n envoy-gateway-system deployment/envoy-gateway-operator-controller-manager
```

**`the EnvoyGateway resource must be named envoy-gateway`.** The CRD accepts
only this name.

**`execution error at (envoy-gateway/templates/validate.yaml ...)`.** The
operator chart refused a value. The message names the value and the reason.
See [openshift.md](openshift.md#values-that-the-operator-chart-sets).

**`invalid ownership metadata`.** An object with the same name exists, and it
does not belong to this release, for example from an earlier manual
installation of Envoy Gateway. Remove the old installation first.

**Warning events `OverrideValuesInUse`.** The operator does not use
`overrideValues`. If you see these events, the operator image is not the one
of this repository.

## The pods do not start

**`unable to validate against any security context constraint`** for the
controller or for `certgen`. A value of the resource sets `runAsUser`,
`runAsGroup` or `fsGroup` again. Remove it.

**The same error for an Envoy proxy.** The service account of the proxy does
not have the `nonroot-v2` SCC. See
[install.md](install.md#3-allow-the-envoy-proxy-to-run-scc).

## The Gateway is not programmed

**`Accepted=False` on the GatewayClass.** Check the controller name:
`gateway.envoyproxy.io/gatewayclass-controller`.

**With The Agent Router: no Gateway is programmed.** The extension manager
points to the Agent Router controller, and Envoy Gateway cannot build any
configuration while that controller does not answer. Check the Agent Router
operator, and the network policies (port 1063).

**With network policies: `Programmed=False` and the proxy never gets a
configuration.** The proxies cannot reach Envoy Gateway on port 18000.

## Leftovers after uninstall

When you delete the `EnvoyGateway` resource, the operator uninstalls the Helm
release. These objects stay:

* the CRDs `*.gateway.envoyproxy.io` and
  `envoygateways.envoygateway.ccangemi.github.io`: OLM never deletes CRDs;
* in `envoy-gateway-system`: the secrets that `certgen` created (`envoy-gateway`,
  `envoy`, `envoy-rate-limit`, `envoy-oidc-hmac`).

For a full cleanup, after you delete all Gateways, routes and Envoy Gateway
resources:

```console
$ oc delete namespace envoy-gateway-system
$ oc get crd -o name | grep -E '\.gateway\.envoyproxy\.io$' | xargs oc delete
$ oc delete crd envoygateways.envoygateway.ccangemi.github.io
```

Never delete the `*.gateway.networking.k8s.io` CRDs: they belong to OpenShift.
