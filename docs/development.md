# Development, tests and releases

## Tools

`make tools` installs the pinned versions of helm, yq, operator-sdk and opm
in `bin/`, and checks their SHA-256 sums. The generated bundle depends on the
exact versions, so always use these tools. `hack/tools.sh kind` also installs
kind for the kind end-to-end test.

`make lint` needs `shellcheck`, `yamllint` and `python3` from your system.

Run `make help` for the list of targets.

## How the bundle is generated

`make bundle` runs `hack/generate-bundle.sh`. The script:

1. pulls the upstream charts `gateway-helm`, `gateway-crds-helm`,
   `ai-gateway-helm` and `ai-gateway-crds-helm` at the versions in
   `versions.env`;
2. renders the CRDs, without the Gateway API CRDs;
3. renders the controllers with the values in `config/values/`;
4. turns the Deployments, the RBAC rules and the configuration into a
   ClusterServiceVersion, based on `config/manifests/csv-template.yaml`;
5. adds the certgen and bootstrap init containers, removes the fixed user
   IDs, and pins every image by digest.

[openshift.md](openshift.md) explains each change. The output in `bundle/`
is committed. Never edit it by hand: change the inputs and run `make bundle`
again. The CI fails when `bundle/` does not match the inputs.

## Offline checks

| Target | What it does |
|---|---|
| `make bundle-gate` | The safety checks: no Gateway API CRDs, no admission policies, allowed CRD groups, Envoy Gateway configuration, images by digest, no fixed user IDs, resources and probes, bundle size, and more. |
| `make test-gate` | Breaks one rule at a time in a copy of the bundle and checks that the gate fails with the right check. |
| `make validate` | `operator-sdk bundle validate` with the `operatorframework` and `community` suites. |
| `make check` | All of the above, plus lint. |

The validators print warnings about deprecated APIs for `endpointslices`,
`horizontalpodautoscalers` and `poddisruptionbudgets`. They are false
positives: the RBAC rules use the current API groups (`discovery.k8s.io`,
`autoscaling`, `policy`). The warnings about missing examples refer to the
kinds that have no entry in `alm-examples`.

## Test on kind

```console
$ make tools && hack/tools.sh kind
$ make e2e-kind
```

The test creates a kind cluster with a local registry, installs the Gateway
API v1.4.1 CRDs and OLM, builds the bundle and catalog images, installs the
operator through OLM and sends a chat completion through a Gateway. It plays
the role of the OpenShift service CA. Set `KEEP_CLUSTER=true` to keep the
cluster.

## Test on OpenShift

You need a cluster with OpenShift 4.22 and a catalog image that the cluster
can pull. The `Images` workflow pushes one for each push to a `feature/**`
branch:

```
ghcr.io/<owner>/envoy-operator-catalog:sha-<commit>
ghcr.io/<owner>/envoy-operator-catalog:<branch name with "-" instead of "/">
```

The packages on ghcr.io are private after the first push. Make them public
(package settings on GitHub), or add a pull secret to the cluster.

Log in with a kubeconfig file outside the repository, then run the test:

```console
$ export KUBECONFIG=~/.kube/my-lab
$ oc login --server=https://api.<cluster>:6443 ...
$ CATALOG_IMAGE=ghcr.io/<owner>/envoy-operator-catalog:sha-<commit> hack/e2e/ocp.sh all
```

The commands of `hack/e2e/ocp.sh`:

| Command | What it does |
|---|---|
| `catalog` | Creates a CatalogSource for `CATALOG_IMAGE` in `envoy-gateway-system`. |
| `install` | Saves a snapshot of the Gateway API CRDs, then installs the operator through OLM. |
| `verify` | Checks the operator, the SCCs, the webhook, and that the Gateway API CRDs did not change. |
| `test` | Applies `samples/ocp` and sends a chat completion through the Gateway. |
| `uninstall` | Deletes the examples and the operator, and checks that the webhook is gone. |
| `all` | `catalog`, `install`, `verify`, `test`. |

### Without an image registry

`hack/e2e/direct-install.sh apply` installs the bundle without OLM: it turns
the ClusterServiceVersion into plain objects, as OLM does. Use it to test the
runtime (SCCs, certgen, webhook bootstrap, traffic) when the cluster cannot
pull a bundle image. Then run `hack/e2e/ocp.sh verify` and
`hack/e2e/ocp.sh test`. It does not test OLM, so always run the full test
before a release.

## Commits and branches

* Work on a feature branch (`feature/<short-name>`) and open a pull request
  against `main`.
* Sign off every commit (`git commit -s`). The CI checks it.
* Write commit messages in the Conventional Commits style, in clear English.

## Release

1. Make sure that `versions.env` has the new `OPERATOR_VERSION`, the right
   `CHANNEL` and `REPLACES`, and that `bundle/` is up to date.
2. Run the OpenShift end-to-end test with the images of the release commit,
   including the upgrade from the previous version.
3. Create and push the tag `v<OPERATOR_VERSION>` on `main`.
4. The `Release` workflow checks the bundle again, pushes the images to
   ghcr.io and creates a GitHub release. The release has an archive with the
   directory `operators/envoy-operator/<version>/` for the community catalog.

## Community catalog

The OpenShift community catalog is the repository
[redhat-openshift-ecosystem/community-operators-prod](https://github.com/redhat-openshift-ecosystem/community-operators-prod).
The directory [community/](../community) has the files for the first pull
request. See [community/README.md](../community/README.md).
