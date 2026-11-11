# OpenShift design notes

This page explains how the operator installs Envoy Gateway on OpenShift, and
why it differs from a plain `helm install` of the upstream chart.

## A Helm operator around the upstream chart

The operator is the upstream `helm-operator` of Operator SDK, with two inputs:

* [watches.yaml](../watches.yaml): the custom resource to watch
  (`EnvoyGateway`) and the chart to install for each resource;
* [helm-charts/envoy-gateway](../helm-charts/envoy-gateway): the operator
  chart.

The operator chart is small. Its only dependency is the upstream chart in
`charts/gateway-helm`, which stays exactly as `helm pull` writes it
(`make chart-check` proves it). The operator chart adds:

* `values.yaml`: the values that OpenShift needs, under `gateway-helm`;
* `templates/validate.yaml`: checks that refuse values that would harm the
  cluster.

Each `EnvoyGateway` resource is one Helm release, with the same name and
namespace. The spec of the resource is merged on top of `values.yaml`. The
operator compares the release with the spec at every change and once a
minute, and upgrades the release when they differ.

### Why not overrideValues

`watches.yaml` can force values with `overrideValues`, but `helm-operator`
parses them as strings. A string `"false"` is not a boolean for a chart
condition, and a string `"null"` does not remove a default. A test showed it:
with `crds.enabled: "false"` the release tried to install the Gateway API
CRDs. The values of the operator chart have real types, so the operator uses
no `overrideValues`.

### Dry run in server mode

To detect changes, `helm-operator` renders the chart in a dry run. With
`dryRunOption: server`, the dry run can read the cluster (Helm `lookup`), like
a real upgrade. Envoy Gateway does not need it today, but a chart that reuses
existing objects would otherwise look different at every dry run, and the
operator would upgrade the release every minute.

### Empty values

When the values are empty, `helm upgrade` keeps the values of the previous
release instead of the chart defaults. The CRD therefore declares
`spec.gateway-helm` with the default `{}`, so that the values are never
empty, and `spec: {}` means "the defaults".

## Values that the operator chart sets

| Value under `gateway-helm` | Operator chart | Why |
|---|---|---|
| `crds.enabled` | `false`, refused if `true` | The upstream subchart installs the Gateway API CRDs and a `safe-upgrades` admission policy. The OpenShift Ingress Operator owns those CRDs, and its admission policy rejects changes from anyone else. |
| `createNamespace` | `false`, refused if `true` | The release goes in the namespace of the resource, which exists. |
| `namespaceOverride` | refused unless it is the release namespace | One operator, one namespace. |
| `config.envoyGateway.provider.kubernetes.watch` | refused | A watch block moves the controller permissions into namespaced Roles, and the controller then fails to list resources at the cluster scope. |
| `topologyInjector.enabled` | `false` (you can turn it on) | A cluster-wide mutating webhook for every pod. The topology injector adds zone labels for zone-aware routing. |
| `deployment.envoyGateway.securityContext`, `deployment.pod.securityContext`, `certgen.job.pod.securityContext`, `certgen.job.securityContext` | `runAsUser`, `runAsGroup` and `fsGroup` removed | The `restricted-v2` SCC does not allow the fixed ID 65532. Without them, OpenShift assigns IDs from the namespace range. |
| `global.images.envoyGateway.image`, `global.images.ratelimit.image` | pinned by digest | The bundle lists the same images in `relatedImages`, for disconnected clusters. |

The controller and the `certgen` job therefore run with `restricted-v2`. The
bundle contains no SCC and no SCC grant.

## The Gateway API belongs to OpenShift

OpenShift 4.22 ships the Gateway API v1.4.1 (standard channel). The Ingress
Operator owns these CRDs. The operator protects them in several ways:

* the operator chart never renders a CRD (`crds.enabled=false`, refused if
  `true`);
* the operator has no permission on CRDs at all, so even a wrong value cannot
  create or change one;
* the bundle contains only the CRDs of `envoygateway.ccangemi.github.io` and
  `gateway.envoyproxy.io`;
* the ClusterServiceVersion declares the Gateway API kinds in `nativeAPIs`;
* the gate (`make bundle-gate`) checks all of this on every pull request, and
  the end-to-end test compares a snapshot of the Gateway API CRDs before and
  after.

Envoy Gateway v1.9 is tested upstream with Gateway API v1.6. On v1.4.1 it
skips the APIs that do not exist (for example `TCPRoute` and `UDPRoute` v1).

## CRDs

The Envoy Gateway CRDs come from the upstream `gateway-crds-helm` chart,
rendered without the Gateway API CRDs (`make update-upstream`). They are part
of the bundle, so OLM installs them before the operator and upgrades them with
each operator version, with its checks for existing resources. Helm alone
never upgrades CRDs.

## Permissions of the operator

`hack/generate-rbac.sh` builds the ClusterRole of the operator from the chart:

* full control of every kind of object that the chart renders;
* every permission that the roles of the chart grant. Kubernetes does not let
  a user create a role with permissions that the user does not have, so the
  operator needs the permissions of the Envoy Gateway controller too.

The ClusterRole has no rule on CRDs and no rule on SCCs.

## One namespace, one resource

The operator watches only its own namespace (`WATCH_NAMESPACE` comes from the
OperatorGroup). The CRD accepts only the name `envoy-gateway`: the names of the
cluster-scoped objects of the chart contain the release name, so a second
release would install a second, conflicting controller.

## The Envoy proxy and the SCC

Envoy Gateway runs the Envoy proxy with the fixed user ID 65532, and an
`EnvoyProxy` resource cannot remove it. The proxies need the `nonroot-v2` SCC
through a RoleBinding (see [install.md](install.md#3-allow-the-envoy-proxy-to-run-scc)).
These RoleBindings depend on the Gateways, so they belong with the Gateways,
not with the operator.

## Images

| Name in `relatedImages` | Image |
|---|---|
| `operator` | `ghcr.io/ccangemi/envoy-gateway-operator` |
| `envoy-gateway` | `docker.io/envoyproxy/gateway` (controller, certgen) |
| `envoy-ratelimit` | `docker.io/envoyproxy/ratelimit` |
| `envoy-proxy` | `docker.io/envoyproxy/envoy`, the default proxy image compiled into Envoy Gateway |

All operand images are pinned by digest. The released bundle pins the operator
image by digest too.
