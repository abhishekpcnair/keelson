#!/usr/bin/env python3
"""Print the Deployments whose running pods have no istio-proxy sidecar (issue #12).

Reads `kubectl get pods -o json` on stdin. Writes the Deployment names, space-separated and sorted.
A pod counts only if a ReplicaSet owns it, it is Running and not being deleted, and it does not opt
out of injection. Upstream opts out some pods in kubeflow on purpose with sidecar.istio.io/inject:
"false" (at 26.10.0: kubeflow-pipelines-profile-controller, metadata-envoy-deployment,
poddefaults-webhook-deployment). The sidecar may be a regular container or a native sidecar (an
init container).
"""
import json
import sys

OPT_OUT = "sidecar.istio.io/inject"


def deployments_without_sidecar(pods):
    names = set()
    for p in pods.get("items", []):
        owners = p["metadata"].get("ownerReferences") or [{}]
        if owners[0].get("kind") != "ReplicaSet" or p.get("status", {}).get("phase") != "Running":
            continue
        meta = p["metadata"]
        if meta.get("deletionTimestamp"):
            continue
        if "false" in ((meta.get("labels") or {}).get(OPT_OUT), (meta.get("annotations") or {}).get(OPT_OUT)):
            continue
        spec = p.get("spec", {})
        containers = [c["name"] for c in spec.get("containers", []) + spec.get("initContainers", [])]
        if "istio-proxy" not in containers:
            # A ReplicaSet is named <deployment>-<pod-template-hash>.
            names.add(owners[0]["name"].rsplit("-", 1)[0])
    return sorted(names)


if __name__ == "__main__":
    print(" ".join(deployments_without_sidecar(json.load(sys.stdin))))
