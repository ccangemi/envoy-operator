# Upgrades

## Upgrade the operator on a cluster

OLM upgrades the operator when a new version is in the channel of the
Subscription. With `installPlanApproval: Manual`, approve the InstallPlan:

```console
$ oc get installplan -n envoy-gateway-system
$ oc patch installplan <name> -n envoy-gateway-system --type merge -p '{"spec":{"approved":true}}'
```

During the upgrade:

* OLM updates the Envoy Gateway and agent router CRDs. It checks that no
  existing custom resource becomes invalid.
* OLM creates the new deployments and cluster roles, then deletes the old
  ones. The bootstrap init container moves the owner references of the
  webhook configuration to the new cluster roles.
* The Envoy proxy pods restart when Envoy Gateway changes their deployment
  (for example, a new default proxy image).

Read the release notes of the operator first. They list the upstream versions
and the changes that need action.

## Update the upstream versions (maintainers)

1. Create a feature branch, for example `feature/eg-v1.9.4`.
2. Change `versions.env`:
   * `EG_VERSION` and/or `AR_VERSION`;
   * `OPERATOR_VERSION` (a new semantic version);
   * `REPLACES`: the name of the previous bundle, for example
     `envoy-operator.v0.1.0`.
3. Run `make bundle` and look at the diff of `bundle/`. Pay attention to:
   * new or removed CRDs, and removed CRD versions;
   * new RBAC rules;
   * new arguments of the controllers, and changes in the upstream Helm
     templates that the generator does not know about.
4. Read the upstream release notes. Check the Gateway API version that the
   release needs. OpenShift 4.22 has v1.4.1.
5. Check whether the agent router still needs the webhook bootstrap (see
   [openshift.md](openshift.md#the-agent-router-webhook)).
6. Run `make check`.
7. Push the branch. The CI runs the kind end-to-end test and pushes test
   images. Run the OpenShift end-to-end test with these images (see
   [development.md](development.md#test-on-openshift)), including an upgrade
   from the previous version.
8. Open a pull request.

The weekly workflow `upstream-check` opens an issue when a new upstream
release is available.
