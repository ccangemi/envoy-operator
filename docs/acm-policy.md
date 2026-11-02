# Install with Red Hat Advanced Cluster Management

With Red Hat Advanced Cluster Management (ACM), a governance policy can
install the operator on the managed clusters. The `OperatorPolicy` kind
manages the namespace, the OperatorGroup and the Subscription for you.

The policy does not manage the Gateway resources (GatewayClass, Gateways,
routes). Users create them, so manage them separately, for example with
Argo CD.

## Example

```yaml
apiVersion: policy.open-cluster-management.io/v1
kind: Policy
metadata:
  name: policy-envoy-operator
  namespace: policies
  annotations:
    policy.open-cluster-management.io/standards: NIST SP 800-53
    policy.open-cluster-management.io/categories: CM Configuration Management
    policy.open-cluster-management.io/controls: CM-2 Baseline Configuration
spec:
  disabled: false
  remediationAction: enforce
  policy-templates:
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1beta1
        kind: OperatorPolicy
        metadata:
          name: envoy-operator
        spec:
          remediationAction: enforce
          severity: high
          complianceType: musthave
          operatorGroup:
            name: envoy-operator
            namespace: envoy-gateway-system
            # No targetNamespaces: "All namespaces" install mode.
          subscription:
            name: envoy-operator
            namespace: envoy-gateway-system
            channel: alpha
            source: community-operators
            sourceNamespace: openshift-marketplace
          # Approve only the versions that you have tested.
          upgradeApproval: Automatic
          versions:
            - envoy-operator.v0.1.0
```

Bind the policy to your clusters with a `Placement` and a `PlacementBinding`,
as for any other policy.

## Notes

* The namespace must be `envoy-gateway-system`. The operator does not start
  in another namespace.
* `versions` limits the ClusterServiceVersions that the policy approves. Add
  a new version to the list after you test it.
* The policy does not create the `nonroot-v2` RoleBindings for the Envoy
  proxies. They depend on the Gateways, so create them together with the
  Gateways (see [install.md](install.md#1-allow-the-envoy-proxy-to-run-scc)).
