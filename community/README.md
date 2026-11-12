# Community catalog

These files are for the pull request to the OpenShift community catalog,
[redhat-openshift-ecosystem/community-operators-prod](https://github.com/redhat-openshift-ecosystem/community-operators-prod).
The operator uses the file-based catalog (FBC) workflow with automatic
release.

| File | Destination in the community repository |
|---|---|
| `ci.yaml` | `operators/envoy-gateway-operator/ci.yaml` |
| `catalog-templates/basic.yaml` | `operators/envoy-gateway-operator/catalog-templates/basic.yaml` |
| `bundle/manifests`, `bundle/metadata` | `operators/envoy-gateway-operator/<version>/` |
| (generated) `release-config.yaml` | `operators/envoy-gateway-operator/<version>/release-config.yaml` |

## Prepare the pull request

1. Check the GitHub user names of the maintainers in `reviewers` in
   `ci.yaml`.
2. Make sure that the operator image of the version exists and is public
   (the release workflow pushes it to quay.io). The community pipeline
   builds only the bundle image.
3. Run `make community` (or download the archive from the GitHub release).
   It writes `build/community/operators/envoy-gateway-operator/`.
4. Copy the directory into a fork of the community repository.
5. Add the FBC Makefile from the operator pipelines and keep only the
   supported OpenShift versions (`OCP_VERSIONS`, here only `v4.22`):

   ```console
   $ cd operators/envoy-gateway-operator
   $ wget https://raw.githubusercontent.com/redhat-openshift-ecosystem/operator-pipelines/main/fbc/Makefile
   ```

6. Commit with a sign-off (`git commit -s`) and open the pull request. The
   pipeline builds the bundle image, tests it and, after the merge, opens a
   second pull request that adds the bundle to the catalog.

Check the current requirements in the
[operator pipelines documentation](https://github.com/redhat-openshift-ecosystem/operator-pipelines/tree/main/docs/users)
before you open the pull request. They change over time.
