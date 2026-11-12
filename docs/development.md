# Development, tests and releases

## Tools

`make tools` installs the pinned versions of helm, yq, kustomize,
operator-sdk and opm in `bin/`, and checks their SHA-256 sums
([hack/tools.sh](../hack/tools.sh)). `make run` also installs helm-operator.
The lint target needs `shellcheck`, `yamllint` and `python3`.

## Move to a new upstream version

This is the usual change, and it needs no code:

1. Change `CHART_VERSION` (and `OPERATOR_VERSION`, `REPLACES`) in
   [versions.env](../versions.env).
2. Run `make update-upstream`. It replaces
   `helm-charts/envoy-gateway/charts/gateway-helm` with the new upstream chart,
   renders the new CRDs, pins the new images and regenerates the RBAC.
3. Run `make bundle`.
4. Review the diff: the upstream chart, the CRDs, `config/rbac/role.yaml`
   (new permissions of the controller) and the bundle.
5. Read the upstream release notes, in particular the Gateway API version
   that the release needs, and new values that might need an OpenShift
   setting in `helm-charts/envoy-gateway/values.yaml`.
6. Run `make check` and the end-to-end test on OpenShift.

Never edit the upstream chart by hand. `make chart-check` compares it with
the upstream chart.

## How the bundle is generated

[hack/generate-bundle.sh](../hack/generate-bundle.sh) runs offline, and the
same inputs always give the same bundle:

1. `kustomize build config/manifests`: the CRDs (`config/crd`), the RBAC
   (`config/rbac`), the operator deployment (`config/manager`), the samples
   and the CSV base (`config/manifests/bases`);
2. `operator-sdk generate bundle`;
3. yq: the version, `relatedImages` (operator image and
   `config/manifests/related-images.yaml`), the icon, the descriptions of the
   upstream CRDs and the annotation `com.redhat.openshift.versions`.

`OPERATOR_IMAGE` overrides the operator image (default
`<OPERATOR_IMAGE_REPOSITORY>:v<OPERATOR_VERSION>`).

## Offline checks

| Target | What it checks |
|---|---|
| `make lint` | shellcheck, Python syntax, yamllint |
| `make rbac-check` | `config/rbac/role.yaml` matches the chart |
| `make bundle-check` | the committed bundle is up to date |
| `make bundle-gate` | the safety rules of the bundle and of the operator chart ([hack/bundle-gate.sh](../hack/bundle-gate.sh)) |
| `make test-gate` | every gate check fails on a bundle or chart that breaks its rule |
| `make validate` | `operator-sdk bundle validate`, operatorframework and community suites |
| `make chart-check` | the upstream chart, the image pins, the CRDs and the RBAC are what `make update-upstream` writes (needs network access) |
| `make check` | lint, rbac-check, bundle-check, bundle-gate, test-gate and validate |

## Run the operator on your machine

```console
$ export KUBECONFIG=<file>
$ oc create namespace envoy-gateway-system
$ make run
```

`make run` applies the CRDs and runs helm-operator in the foreground, with
your own permissions. Create the `EnvoyGateway` resource in another terminal.
This is fast for chart changes, but it does not test the permissions of the
operator: use OLM for that.

## Test on OpenShift with OLM

[hack/e2e/build-on-cluster.sh](../hack/e2e/build-on-cluster.sh) builds the
operator, bundle and catalog images in the cluster, with binary builds and
the internal image registry. No published image and no container tool are
needed. The internal registry must be enabled.

```console
$ export KUBECONFIG=<file>
$ CATALOG_IMAGE=$(hack/e2e/build-on-cluster.sh | tail -1)
$ CATALOG_IMAGE=$CATALOG_IMAGE hack/e2e/ocp.sh all
$ hack/e2e/ocp.sh uninstall
```

[hack/e2e/ocp.sh](../hack/e2e/ocp.sh) installs the operator through OLM in
the OwnNamespace mode, creates the `EnvoyGateway` resource
(`samples/ocp/envoygateway.yaml`), and checks:

* the release, the pods and their SCC (`restricted-v2`);
* that the Gateway API CRDs did not change (a snapshot before and after);
* that the release keeps its revision over three reconcile periods;
* that a request through a Gateway (`samples/ocp/test`) returns HTTP 200.

Without `CATALOG_IMAGE`, the script installs the operator from the
community catalog.

## Commits and branches

* Work on a feature branch and open a pull request to `main`.
* Sign off every commit (`git commit -s`), see [CONTRIBUTING.md](../CONTRIBUTING.md).
* Commit the generated files (`bundle/`, `config/rbac/role.yaml`,
  `config/crd/upstream/`) with the change that causes them.

## Release

The operator image is published on quay.io, in the repository of
`OPERATOR_IMAGE_REPOSITORY` in [versions.env](../versions.env). The community
catalog pipeline builds only the bundle image, so the operator image must
exist before the community pull request.

Before the first release:

* Create the image repository on quay.io and make it public.
* Create a robot account with write access to it.
* Add two repository secrets for GitHub Actions: `QUAY_USERNAME` (the robot
  name, for example `gateway-operators+github_actions`) and `QUAY_PASSWORD`
  (the robot token).

Then:

1. Merge the version change (see above) into `main`.
2. Push the tag `v<OPERATOR_VERSION>`, for example `v0.1.0`.
3. The release workflow ([.github/workflows/release.yaml](../.github/workflows/release.yaml)):
   * runs all checks, and checks the pinned bundle with a placeholder digest,
     so that a problem stops the release before the image is public;
   * builds the operator image for amd64 and arm64 and pushes it to
     `quay.io/<organization>/envoy-gateway-operator:v<OPERATOR_VERSION>`;
   * regenerates the bundle with the image pinned by digest, and runs the
     gate with `REQUIRE_PINNED_OPERATOR_IMAGE=true`. When you run the job
     again, it reuses the image that an earlier run pushed, so the digest of
     a published tag never changes;
   * creates a GitHub release with the directory for the community catalog.

## Community catalog

`make community` (or the release archive) gives
`build/community/operators/envoy-gateway-operator/` with `ci.yaml`, the
catalog template and the bundle of the version. Copy it into a fork of
[community-operators-prod](https://github.com/redhat-openshift-ecosystem/community-operators-prod)
and open a pull request. See [community/README.md](../community/README.md).
