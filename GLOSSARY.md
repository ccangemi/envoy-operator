# envoy-operator

A community OLM operator that installs Envoy Gateway and The Agent Router on OpenShift, on top of the Gateway API that OpenShift already provides. It packages the upstream controllers; it adds no controller of its own.

## Language

### Components

**Envoy Gateway**:
The upstream control plane that turns Gateways and routes into running Envoy proxies.
_Avoid_: EG (outside `versions.env`), gateway controller

**Envoy proxy**:
The data-plane pod that Envoy Gateway runs for each Gateway, in the Gateway's own namespace.
_Avoid_: Envoy, proxy pod, gateway pod

**The Agent Router**:
The upstream controller that adds AI and MCP routing on top of Envoy Gateway. In prose, "the agent router".
_Avoid_: Envoy AI Gateway, AI Gateway, AR (outside `versions.env`)

**External processor**:
The sidecar that the agent router injects into every Envoy proxy to handle AI traffic.
_Avoid_: extproc (except as the image name)

### Packaging

**Operator**:
The OLM package `envoy-operator`: one bundle that installs both upstream controllers. It is not a controller and has no custom resource of its own.
_Avoid_: controller (for the operator itself)

**Bundle**:
The generated OLM bundle in `bundle/`: the CSV, the owned CRDs and the supporting objects for one operator version.
_Avoid_: manifests, operator image

**Bill of materials**:
The set of versions (operator, upstream components, bootstrap image, OpenShift range) that defines one release.
_Avoid_: version file, config

**Upstream charts**:
The Helm charts published by Envoy Gateway and the agent router, from which the generator builds the bundle.
_Avoid_: upstream manifests

**Generator**:
The step that turns the upstream charts and the bill of materials into the bundle, applying the OpenShift adaptations.
_Avoid_: build script

**Bundle gate**:
The offline set of rules that every bundle must satisfy to be safe on OpenShift.
_Avoid_: safety gate, validation, lint

**Bootstrap**:
The init container that creates, at every start, the objects OLM cannot create: the pod mutator webhook and the MCP session encryption seed.
_Avoid_: ar-bootstrap (except as the container name), init script

**certgen**:
The init container that creates the xDS TLS certificates between Envoy Gateway and the Envoy proxies, replacing the upstream Helm hook Job.

**Community catalog**:
The OpenShift community operator catalog, the only place where the operator is published.
_Avoid_: OperatorHub, marketplace

### Ownership and boundaries

**Gateway API CRDs**:
The `gateway.networking.k8s.io` CRDs. OpenShift's Ingress Operator owns them; the operator never ships, changes or removes them.

**Owned CRDs**:
The Envoy Gateway (`gateway.envoyproxy.io`) and agent router (`aigateway.envoyproxy.io`) CRDs, which the operator owns and OLM installs and upgrades.

**InferencePool CRDs**:
The Gateway API Inference Extension CRDs. OpenShift AI owns them; the operator does not ship them.

**Operator namespace**:
`envoy-gateway-system`, the only namespace where the operator works. Both controllers run there.
_Avoid_: install namespace, control-plane namespace

**Gateway namespace**:
A namespace where a user creates a Gateway; its Envoy proxy runs there too.
_Avoid_: tenant namespace, application namespace

**Pod mutator webhook**:
The mutating webhook, with a fixed name, through which the agent router injects the external processor into Envoy proxies.
_Avoid_: OLM webhook, admission webhook

**Gateway resources**:
The GatewayClasses handled by Envoy Gateway (`gateway.envoyproxy.io/gatewayclass-controller`), with their Gateways and routes (including `AIGatewayRoute`). Users create them; the operator never does. OpenShift's own GatewayClasses are not Gateway resources: always name them explicitly.
_Avoid_: application resources, gateway config

**Controllers**:
Envoy Gateway and the agent router as running workloads in the operator namespace. "The controllers are down" is about them, not about the operator.
_Avoid_: the operator (for the running workloads)
