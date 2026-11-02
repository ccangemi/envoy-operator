# envoy-operator

A community OLM operator. It installs Envoy Gateway and The Agent Router on OpenShift, on top of the Gateway API that OpenShift already provides. It packages the upstream controllers and adds no controller of its own.

## Language

### Components

**Envoy Gateway**:
The upstream control plane that turns Gateways and routes into running Envoy proxies.
_Avoid_: EG (except in `versions.env` and branch names)

**Envoy proxy**:
The data-plane pod that Envoy Gateway runs for each Gateway, in the namespace of the Gateway. "Envoy proxy pods" is fine for the plural.
_Avoid_: Envoy (alone), gateway pod (it suggests the Envoy Gateway pod)

**The Agent Router**:
The upstream controller that adds AI and MCP routing on top of Envoy Gateway. In prose, "the agent router".
_Avoid_: AI Gateway, AR (except in `versions.env` and `ar-bootstrap`). Exception: "formerly Envoy AI Gateway", to give the former name.

**External processor**:
The sidecar that the agent router injects into every Envoy proxy to handle AI traffic.
_Avoid_: extproc (except in image, container and flag names)

### Packaging

**Operator**:
The OLM package `envoy-operator`. It is one bundle that installs both upstream controllers. It is not a controller and has no custom resource of its own.
_Avoid_: controller (for the operator itself)

**Bundle**:
The generated OLM bundle in `bundle/`. It holds the CSV, the owned CRDs and the supporting objects for one operator version.
_Avoid_: operator image

**Bill of materials**:
The set of versions that defines one release: operator, upstream components, bootstrap image and OpenShift range.
_Avoid_: version file

**Upstream charts**:
The Helm charts that Envoy Gateway and the agent router publish. The generator builds the bundle from them.
_Avoid_: upstream manifests

**Generator**:
The step that turns the upstream charts and the bill of materials into the bundle. It applies the OpenShift adaptations.
_Avoid_: build script

**Bundle gate**:
The offline rules that every bundle must satisfy to be safe on OpenShift. It is not the same as lint or OLM bundle validation.
_Avoid_: safety gate

**Bootstrap**:
The init container that creates the objects OLM cannot create, at every pod start. They are the pod mutator webhook and the MCP session encryption seed.
_Avoid_: init script

**certgen**:
The init container that creates the xDS TLS certificates between Envoy Gateway and the Envoy proxies. It replaces the upstream Helm hook Job.

**Community catalog**:
The OpenShift community operator catalog. It is the only place where the operator is published.
_Avoid_: OperatorHub, marketplace. Exceptions: "OperatorHub" as the name of the console menu, and the namespace `openshift-marketplace`.

### Ownership and boundaries

**Gateway API CRDs**:
The `gateway.networking.k8s.io` CRDs. The OpenShift Ingress Operator owns them. The operator never ships, changes or removes them.

**Owned CRDs**:
The Envoy Gateway (`gateway.envoyproxy.io`) and agent router (`aigateway.envoyproxy.io`) CRDs. The operator owns them, and OLM installs and upgrades them.

**InferencePool CRDs**:
The Gateway API Inference Extension CRDs. The operator never ships them. With OpenShift AI, KServe owns them. Without OpenShift AI, the user installs them.

**Operator namespace**:
`envoy-gateway-system`, the only namespace where the operator works. Both controllers run there.
_Avoid_: install namespace, control-plane namespace

**Gateway namespace**:
A namespace where a user creates a Gateway. The Envoy proxy of that Gateway runs there too.
_Avoid_: tenant namespace, application namespace

**Pod mutator webhook**:
The mutating webhook with a fixed name. Through it, the agent router injects the external processor into the Envoy proxies.
_Avoid_: OLM webhook

**Gateway resources**:
The GatewayClasses of Envoy Gateway (`gateway.envoyproxy.io/gatewayclass-controller`), with their Gateways and routes, including `AIGatewayRoute`. Users create them. The operator never does. OpenShift's own GatewayClasses are not Gateway resources: always name them explicitly.
_Avoid_: application resources, gateway config

**Controllers**:
Envoy Gateway and the agent router as running workloads in the operator namespace. "The controllers are down" is about them, not about the operator.
_Avoid_: the operator (for the running workloads)
