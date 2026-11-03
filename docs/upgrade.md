# Upgrades

## Operator upgrades

Each operator version installs one Envoy Gateway version. OLM upgrades the
operator through the channel `alpha`, following the `replaces` field of each
ClusterServiceVersion.

During an upgrade:

1. OLM upgrades the Envoy Gateway CRDs of the bundle. OLM first checks that the
   existing resources are valid with the new CRDs.
2. OLM replaces the operator deployment.
3. The new operator compares the release with the new chart and upgrades it.
   Helm runs the `certgen` job again; it does not replace existing
   certificates.

Read the upstream release notes before you approve an upgrade, in particular
the Gateway API version that the new Envoy Gateway needs.

With `installPlanApproval: Manual`, or with the `versions` list of an ACM
`OperatorPolicy`, nothing changes before you approve it.

## Changes to the EnvoyGateway resource

A change to the spec gives one Helm upgrade. The status shows the result:

```console
$ oc get envoygateway envoy-gateway -n envoy-gateway-system -o jsonpath='{.status.conditions}'
```

If an upgrade fails, the operator rolls back the release and reports the
error in the condition `ReleaseFailed`.

Setting `spec: {}` goes back to the chart defaults. The CRD makes sure that
the values are never empty, because with empty values Helm would keep the
values of the previous release.

## Certificates of the control plane

`certgen` creates the certificates `envoy-gateway`, `envoy` and
`envoy-rate-limit` when they do not exist. They are valid for about five
years, and nothing renews them. To renew them, delete the three secrets in
`envoy-gateway-system` and change a value of the `EnvoyGateway` resource, for
example a pod annotation in `gateway-helm.deployment.pod.annotations`: the
Helm upgrade runs `certgen` again. Restart the Envoy proxies after that.
