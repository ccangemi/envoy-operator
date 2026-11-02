#!/usr/bin/env python3
"""Bootstrap for the agent router controller.

It runs as an init container in the controller pod, before the controller
starts. It uses only the Python standard library and talks to the Kubernetes
API directly, so the image needs no other tools.

Why it exists: the agent router controller (v1.2) stops at startup when the
MutatingWebhookConfiguration "envoy-ai-gateway-gateway-pod-mutator.<namespace>"
does not exist. The Helm chart creates it, but OLM cannot create an object
with a fixed name: OLM-managed webhooks get a generated name. So this script
creates the webhook configuration, and the OpenShift service CA injects and
rotates its CA bundle.

The script also creates the secret with the MCP session encryption seed. A
static secret in the bundle would be the same, public value on every cluster.

The script is idempotent: it runs again every time the pod starts.

Environment:
  POD_NAMESPACE       the namespace of the pod (downward API)
  EXPECTED_NAMESPACE  the only namespace where the operator works
  CSV_NAME            the name of the ClusterServiceVersion. The generator
                      sets it, because OLM injects OPERATOR_CONDITION_NAME
                      only into the main containers.
"""

import base64
import json
import os
import secrets
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
WEBHOOK_SERVICE = os.environ.get("WEBHOOK_SERVICE", "ai-gateway-controller")
MCP_SEED_SECRET = os.environ.get("MCP_SEED_SECRET", "ai-gateway-controller-mcp-session-encryption")
FIELD_MANAGER = "envoy-operator-bootstrap"


def log(message):
    print(f"[ar-bootstrap] {message}", flush=True)


class Api:
    """A minimal Kubernetes API client with the service account token."""

    def __init__(self):
        host = os.environ["KUBERNETES_SERVICE_HOST"]
        port = os.environ.get("KUBERNETES_SERVICE_PORT", "443")
        if ":" in host:  # IPv6
            host = f"[{host}]"
        self.base = f"https://{host}:{port}"
        with open(f"{SA_DIR}/token", encoding="utf-8") as f:
            self.token = f.read().strip()
        self.context = ssl.create_default_context(cafile=f"{SA_DIR}/ca.crt")

    def request(self, method, path, body=None, content_type="application/json", query=None):
        """Returns (status, decoded JSON body). Raises on network errors."""
        url = self.base + path
        if query:
            url += "?" + urllib.parse.urlencode(query)
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", f"Bearer {self.token}")
        req.add_header("Accept", "application/json")
        if data is not None:
            req.add_header("Content-Type", content_type)
        try:
            with urllib.request.urlopen(req, context=self.context, timeout=30) as resp:
                return resp.status, json.loads(resp.read() or b"{}")
        except urllib.error.HTTPError as err:
            try:
                payload = json.loads(err.read() or b"{}")
            except ValueError:
                payload = {}
            return err.code, payload


def fail(message):
    log(f"ERROR: {message}")
    sys.exit(1)


def check(status, payload, action):
    if status >= 300:
        fail(f"{action}: HTTP {status}: {payload.get('message', payload)}")


def ensure_namespace(namespace, expected):
    # The webhook name, the RBAC rules and the Envoy Gateway extension manager
    # address all contain the namespace, so the operator works only in the
    # namespace it was built for.
    if namespace != expected:
        log(f"ERROR: the operator runs in namespace '{namespace}', but it supports only '{expected}'.")
        fail(f"uninstall it and install it again in namespace '{expected}'.")


def ensure_seed_secret(api, namespace):
    path = f"/api/v1/namespaces/{namespace}/secrets"
    status, payload = api.request("GET", f"{path}/{MCP_SEED_SECRET}")
    if status == 200:
        log(f"secret {MCP_SEED_SECRET} exists")
        return
    if status != 404:
        check(status, payload, f"read secret {MCP_SEED_SECRET}")
    seed = base64.b64encode(secrets.token_bytes(48)).decode()
    body = {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": {
            "name": MCP_SEED_SECRET,
            "labels": {"app.kubernetes.io/name": "ai-gateway-controller", "app.kubernetes.io/part-of": "envoy-operator"},
        },
        "type": "Opaque",
        "data": {"seed": base64.b64encode(seed.encode()).decode()},
    }
    status, payload = api.request("POST", path, body)
    if status == 409:
        log(f"secret {MCP_SEED_SECRET} exists")  # another replica created it
        return
    check(status, payload, f"create secret {MCP_SEED_SECRET}")
    log(f"created secret {MCP_SEED_SECRET}")


def owner_references(api, csv_name, webhook_name):
    """The owners of the webhook configuration.

    A cluster-scoped object cannot have a namespaced owner, so the owners are
    the cluster roles that OLM creates for this operator. OLM deletes them when
    you uninstall the operator, and then Kubernetes deletes the webhook
    configuration too.

    During an upgrade OLM creates new cluster roles before it deletes the old
    ones, and the new pod starts in between. So the script keeps the owners
    that still exist and adds the current ones.
    """
    owners = {}
    if csv_name:
        selector = f"olm.owner={csv_name},olm.owner.kind=ClusterServiceVersion"
        status, payload = api.request(
            "GET", "/apis/rbac.authorization.k8s.io/v1/clusterroles", query={"labelSelector": selector}
        )
        check(status, payload, "list the operator cluster roles")
        for item in payload.get("items", []):
            owners[item["metadata"]["uid"]] = item["metadata"]["name"]
    else:
        log("WARNING: CSV_NAME is not set; the webhook configuration has no owner")

    status, payload = api.request(
        "GET", f"/apis/admissionregistration.k8s.io/v1/mutatingwebhookconfigurations/{webhook_name}"
    )
    if status == 200:
        for ref in payload["metadata"].get("ownerReferences", []):
            if ref.get("kind") != "ClusterRole" or ref["uid"] in owners:
                continue
            status, role = api.request("GET", f"/apis/rbac.authorization.k8s.io/v1/clusterroles/{ref['name']}")
            if status == 200 and role["metadata"]["uid"] == ref["uid"]:
                owners[ref["uid"]] = ref["name"]
    elif status != 404:  # 404: the first start, not an error
        check(status, payload, f"read webhook configuration {webhook_name}")

    return [
        {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRole", "name": name, "uid": uid}
        for uid, name in sorted(owners.items(), key=lambda item: item[1])
    ]


def apply_webhook(api, namespace, webhook_name, owners):
    # Server-side apply with our own field manager: it does not touch the
    # caBundle field, which the service CA operator and the controller manage.
    metadata = {
        "name": webhook_name,
        "labels": {
            "app.kubernetes.io/name": "ai-gateway-controller",
            "app.kubernetes.io/part-of": "envoy-operator",
            "app.kubernetes.io/managed-by": FIELD_MANAGER,
        },
        "annotations": {"service.beta.openshift.io/inject-cabundle": "true"},
    }
    if owners:
        metadata["ownerReferences"] = owners
    body = {
        "apiVersion": "admissionregistration.k8s.io/v1",
        "kind": "MutatingWebhookConfiguration",
        "metadata": metadata,
        "webhooks": [
            {
                "name": f"{WEBHOOK_SERVICE}.{namespace}.svc.cluster.local",
                "clientConfig": {
                    "service": {"name": WEBHOOK_SERVICE, "namespace": namespace, "port": 9443, "path": "/mutate"}
                },
                "rules": [{"apiGroups": [""], "apiVersions": ["v1"], "operations": ["CREATE"], "resources": ["pods"]}],
                "objectSelector": {"matchLabels": {"app.kubernetes.io/managed-by": "envoy-gateway"}},
                "sideEffects": "None",
                "admissionReviewVersions": ["v1"],
                "timeoutSeconds": 10,
                "failurePolicy": "Fail",
            }
        ],
    }
    status, payload = api.request(
        "PATCH",
        f"/apis/admissionregistration.k8s.io/v1/mutatingwebhookconfigurations/{webhook_name}",
        body,
        content_type="application/apply-patch+yaml",
        query={"fieldManager": FIELD_MANAGER, "force": "true"},
    )
    check(status, payload, f"apply webhook configuration {webhook_name}")
    log(f"webhook configuration {webhook_name} is ready ({len(owners)} owner(s))")


def main():
    namespace = os.environ.get("POD_NAMESPACE", "")
    expected = os.environ.get("EXPECTED_NAMESPACE", "")
    if not namespace or not expected:
        fail("POD_NAMESPACE and EXPECTED_NAMESPACE must be set")
    ensure_namespace(namespace, expected)

    api = Api()
    ensure_seed_secret(api, namespace)
    webhook_name = f"envoy-ai-gateway-gateway-pod-mutator.{namespace}"
    owners = owner_references(api, os.environ.get("CSV_NAME", ""), webhook_name)
    apply_webhook(api, namespace, webhook_name, owners)


if __name__ == "__main__":
    try:
        main()
    except (OSError, KeyError, ValueError) as err:
        fail(f"{type(err).__name__}: {err}")
