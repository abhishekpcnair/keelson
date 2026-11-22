#!/usr/bin/env python3
"""Check each module's namespace lists against its pinned upstream kustomize output.

For every charts/keelson/modules/*.yaml with source.type kustomize, run
`kubectl kustomize` on .cache/upstream/<tag>/<path> (and on each platformPaths entry).
  found    = every metadata.namespace, plus the name of every kind: Namespace
  declared = namespace + namespaces
  N1 FAIL  a path writes to a namespace outside declared: the AppProject would block a sync.
  N1 WARN  declared - {namespace} has a namespace that no path of the module writes to.
  N0 FAIL  a module file is empty, not valid YAML, not a mapping, or has no name or source.path.

Usage:
  hack/check_namespaces.py [--chart charts/keelson] [--cache .cache/upstream]
The tag comes from upstream.manifestsRef in values.yaml. $KUBECTL overrides `kubectl`.
Exit 1 on any FAIL, 2 if the upstream cache is missing or kubectl cannot run.
"""
import argparse
import os
import pathlib
import subprocess
import sys

import yaml

KUBECTL = os.environ.get("KUBECTL", "kubectl")


class MissingTool(Exception):
    pass


def found_namespaces(path: pathlib.Path):
    try:
        r = subprocess.run([KUBECTL, "kustomize", str(path)], capture_output=True, text=True)
    except FileNotFoundError:
        raise MissingTool(f"'{KUBECTL}' not found on PATH; install kubectl (or set KUBECTL)") from None
    except OSError as e:
        raise MissingTool(f"'{KUBECTL}' cannot run: {e.strerror or e}") from None
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


def check_module(m: dict, upstream: pathlib.Path):
    """Return (fails, warns) message lists for one module."""
    fails, warns = [], []
    src = m.get("source") or {}
    if src.get("type") != "kustomize":
        return fails, warns
    declared = {m.get("namespace")} | set(m.get("namespaces") or [])
    declared.discard(None)
    found_any = set()
    for p in [src["path"], *(src.get("platformPaths") or {}).values()]:
        try:
            found = found_namespaces(upstream / p)
        except RuntimeError as e:
            fails.append(f"N1 {m['name']}: kubectl kustomize {p} failed: {e}")
            continue
        found_any |= found
        if missing := sorted(found - declared):
            fails.append(f"N1 {m['name']}: upstream {p} writes to {missing} but namespaces: doesn't list it")
    # Over all paths together, so a namespace used only by a platform path is not reported.
    if extra := sorted(declared - found_any - {m.get("namespace")}):
        warns.append(f"N1 {m['name']}: namespaces: lists {extra}, but no upstream path writes there")
    return fails, warns


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--chart", type=pathlib.Path, default=pathlib.Path("charts/keelson"))
    ap.add_argument("--cache", type=pathlib.Path, default=pathlib.Path(".cache/upstream"))
    a = ap.parse_args()
    tag = yaml.safe_load((a.chart / "values.yaml").read_text())["upstream"]["manifestsRef"]
    upstream = a.cache / tag
    if not upstream.is_dir():
        print(f"check_namespaces: {upstream} is missing; run make upstream-cache", file=sys.stderr)
        sys.exit(2)
    fails, modules = 0, 0
    for f in sorted((a.chart / "modules").glob("*.yaml")):
        try:
            m = yaml.safe_load(f.read_text()) or {}
        except yaml.YAMLError as e:
            print(f"FAIL N0 {f}: not valid YAML: {str(e).splitlines()[0]}")
            fails += 1
            continue
        if not isinstance(m, dict) or not isinstance(m.get("source", {}), dict):
            print(f"FAIL N0 {f}: not a mapping (the file and its source: must be maps)")
            fails += 1
            continue
        missing = [k for k, ok in (("name", m.get("name")), ("source.path", (m.get("source") or {}).get("path"))) if not ok]
        if missing:
            for k in missing:
                print(f"FAIL N0 {f}: missing required field {k}")
            fails += len(missing)
            continue
        try:
            mf, mw = check_module(m, upstream)
        except MissingTool as e:
            print(f"check_namespaces: {e}", file=sys.stderr)
            sys.exit(2)
        modules += 1
        for w in mw:
            print(f"WARN {w}")
        for e in mf:
            print(f"FAIL {e}")
        fails += len(mf)
    print(f"check_namespaces: {modules} modules checked at {tag}, {fails} problem(s)")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
