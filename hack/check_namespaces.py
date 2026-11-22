#!/usr/bin/env python3
"""Check each module's namespace lists against its pinned upstream kustomize output.

For every charts/keelson/modules/*.yaml with source.type kustomize, run
`kubectl kustomize` on .cache/upstream/<tag>/<path> (and on each platformPaths entry).
  found    = every metadata.namespace, plus the name of every kind: Namespace
  declared = namespace + namespaces
  N1 FAIL  found - declared is not empty: the AppProject would block a sync.
  N1 WARN  declared - found - {namespace} is not empty: the allowlist is wider than needed.

Usage:
  hack/check_namespaces.py [--chart charts/keelson] [--cache .cache/upstream]
The tag comes from upstream.manifestsRef in values.yaml. $KUBECTL overrides `kubectl`.
Exit 1 on any FAIL, 2 if the upstream cache is missing.
"""
import argparse
import os
import pathlib
import subprocess
import sys

import yaml

KUBECTL = os.environ.get("KUBECTL", "kubectl")


def found_namespaces(path: pathlib.Path):
    r = subprocess.run([KUBECTL, "kustomize", str(path)], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip())
    found = set()
    for doc in yaml.safe_load_all(r.stdout):
        if not isinstance(doc, dict):
            continue
        meta = doc.get("metadata") or {}
        if meta.get("namespace"):
            found.add(meta["namespace"])
        if doc.get("kind") == "Namespace" and meta.get("name"):
            found.add(meta["name"])
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--chart", type=pathlib.Path, default=pathlib.Path("charts/keelson"))
    ap.add_argument("--cache", type=pathlib.Path, default=pathlib.Path(".cache/upstream"))
    a = ap.parse_args()
    tag = yaml.safe_load((a.chart / "values.yaml").read_text())["upstream"]["manifestsRef"]
    upstream = a.cache / tag
    if not upstream.is_dir():
        print(f"check_namespaces: {upstream} is missing; run make upstream-cache")
        sys.exit(2)
    fails, checked = 0, 0
    for f in sorted((a.chart / "modules").glob("*.yaml")):
        m = yaml.safe_load(f.read_text())
        src = m.get("source") or {}
        if src.get("type") != "kustomize":
            continue
        declared = {m.get("namespace")} | set(m.get("namespaces") or [])
        declared.discard(None)
        paths = [src["path"], *(src.get("platformPaths") or {}).values()]
        for p in paths:
            checked += 1
            try:
                found = found_namespaces(upstream / p)
            except RuntimeError as e:
                print(f"FAIL N1 {m['name']}: kubectl kustomize {p} failed: {e}")
                fails += 1
                continue
            if missing := sorted(found - declared):
                print(f"FAIL N1 {m['name']}: upstream {p} writes to {missing} but namespaces: doesn't list it")
                fails += 1
            if extra := sorted(declared - found - {m.get("namespace")}):
                print(f"WARN N1 {m['name']}: namespaces: lists {extra}, but upstream {p} doesn't write there")
    print(f"check_namespaces: {checked} module paths checked at {tag}, {fails} problem(s)")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
