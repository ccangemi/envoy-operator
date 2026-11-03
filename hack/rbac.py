"""Builds the ClusterRole of the operator from rendered Helm manifests.

Usage: python3 -I hack/rbac.py <manifests.json> <operator-rules.json>

<manifests.json> is a JSON array of the objects that the chart renders, for
all the value sets in hack/generate-rbac.sh. <operator-rules.json> is a JSON
array of the base rules of the operator (custom resource, Helm storage,
events). The result, a ClusterRole as JSON, goes to standard output.

The operator needs two kinds of permissions:
  * full control (create, delete, get, list, patch, update, watch) of every
    kind of object that the chart renders, because Helm creates, changes and
    deletes them, and the operator watches them;
  * every permission that the Roles and ClusterRoles of the chart grant.
    Kubernetes refuses to let a user create a role with permissions that the
    user does not have (privilege escalation prevention).
Only the Python standard library is used.
"""

import json
import sys

MANAGE = ["create", "delete", "get", "list", "patch", "update", "watch"]

# Plural resource names for kinds whose name is not "<kind in lower case>s".
IRREGULAR = {
    "Endpoints": "endpoints",
    "Ingress": "ingresses",
    "NetworkPolicy": "networkpolicies",
    "PodSecurityPolicy": "podsecuritypolicies",
    "ValidatingAdmissionPolicy": "validatingadmissionpolicies",
}


def plural(kind):
    if kind in IRREGULAR:
        return IRREGULAR[kind]
    lower = kind.lower()
    if lower.endswith("y"):
        return lower[:-1] + "ies"
    if lower.endswith("s"):
        return lower + "es"
    return lower + "s"


def group_of(api_version):
    return api_version.split("/")[0] if "/" in api_version else ""


def atoms(rule):
    """Splits a rule into (group, resource, names, verb) tuples."""
    if rule.get("nonResourceURLs"):
        raise SystemExit("ERROR: nonResourceURLs rules are not supported: %r" % rule)
    names = tuple(sorted(rule.get("resourceNames") or []))
    for group in rule.get("apiGroups") or [""]:
        for resource in rule.get("resources") or []:
            for verb in rule.get("verbs") or []:
                yield (group, resource, names, verb)


def main():
    manifests = json.load(open(sys.argv[1]))
    base_rules = json.load(open(sys.argv[2]))

    rules = list(base_rules)
    for obj in manifests:
        if not isinstance(obj, dict) or "kind" not in obj:
            continue
        kind = obj["kind"]
        if kind == "CustomResourceDefinition":
            raise SystemExit("ERROR: the chart renders a CRD (%s). CRDs belong to the bundle." % obj["metadata"]["name"])
        rules.append({"apiGroups": [group_of(obj["apiVersion"])], "resources": [plural(kind)], "verbs": MANAGE})
        if kind in ("Role", "ClusterRole"):
            rules.extend(obj.get("rules") or [])

    # (group, resource, names) -> verbs
    verbs = {}
    for rule in rules:
        for group, resource, names, verb in atoms(rule):
            verbs.setdefault((group, resource, names), set()).add(verb)

    # Merge the resources that have the same group, names and verbs.
    merged = {}
    for (group, resource, names), vs in verbs.items():
        vs = ("*",) if "*" in vs else tuple(sorted(vs))
        merged.setdefault((group, names, vs), set()).add(resource)

    out = []
    for (group, names, vs), resources in sorted(merged.items(), key=lambda i: (i[0][0], sorted(i[1]), i[0][1], i[0][2])):
        rule = {"apiGroups": [group], "resources": sorted(resources)}
        if names:
            rule["resourceNames"] = list(names)
        rule["verbs"] = list(vs)
        out.append(rule)

    json.dump({
        "apiVersion": "rbac.authorization.k8s.io/v1",
        "kind": "ClusterRole",
        "metadata": {"name": "manager-role"},
        "rules": out,
    }, sys.stdout, indent=2)


if __name__ == "__main__":
    main()
