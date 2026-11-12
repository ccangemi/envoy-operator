# Install with Red Hat Advanced Cluster Management

With Red Hat Advanced Cluster Management (ACM), a governance policy can
install the operator and create the `EnvoyGateway` resource on the managed
clusters. The `OperatorPolicy` kind manages the OperatorGroup and the
Subscription.

The Gateway resources (GatewayClass, Gateways, routes, the `nonroot-v2`
RoleBindings of the proxies) are application resources. Manage them
separately, for example with Argo CD.

## Example

```yaml
apiVersion: policy.open-cluster-management.io/v1
kind: Policy
metadata:
  name: policy-envoy-gateway
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
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: envoy-gateway-namespace
        spec:
          remediationAction: enforce
          severity: high
          object-templates:
            - complianceType: musthave
              objectDefinition:
                apiVersion: v1
                kind: Namespace
                metadata:
                  name: envoy-gateway-system
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1beta1
        kind: OperatorPolicy
        metadata:
          name: envoy-gateway-operator
        spec:
          remediationAction: enforce
          severity: high
          complianceType: musthave
          operatorGroup:
            name: envoy-gateway-operator
            namespace: envoy-gateway-system
            # OwnNamespace install mode.
            targetNamespaces:
              - envoy-gateway-system
          subscription:
            name: envoy-gateway-operator
            namespace: envoy-gateway-system
            channel: alpha
            source: community-operators
            sourceNamespace: openshift-marketplace
          # Approve only the versions that you have tested.
          upgradeApproval: Automatic
          versions:
            - envoy-gateway-operator.v0.1.1
    - extraDependencies:
        - apiVersion: policy.open-cluster-management.io/v1beta1
          kind: OperatorPolicy
          name: envoy-gateway-operator
          compliance: Compliant
      objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: envoy-gateway-instance
        spec:
          remediationAction: enforce
          severity: high
          object-templates:
            - complianceType: musthave
              objectDefinition:
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

Bind the policy to your clusters with a `Placement` and a `PlacementBinding`,
as for any other policy.

## Notes

* `versions` limits the ClusterServiceVersions that the policy approves. Add a
  new version to the list after you test it.
* Put your own labels on the Envoy Gateway objects with
  `gateway-helm.commonLabels` and `gateway-helm.deployment.pod.labels`.
* For The Agent Router, use the values of
  [samples/ocp/envoygateway-with-agent-router.yaml](../samples/ocp/envoygateway-with-agent-router.yaml)
  in the `EnvoyGateway` resource, and install the Agent Router operator with a
  second policy.
