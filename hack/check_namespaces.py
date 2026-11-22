#!/usr/bin/env python3
"""Check each module's namespace lists against its pinned upstream kustomize output.

For every charts/keelson/modules/*.yaml with source.type kustomize, run
`kustomize build` on .cache/upstream/<tag>/<path> (and on each platformPaths entry).
The kustomize binary must be the version upstream pins in tests/kustomize_install.sh, the same
as for `make kustomize-check`.
  found    = every metadata.namespace, plus the name of every kind: Namespace
  declared = namespace + namespaces
  N1 FAIL  a path writes to a namespace outside declared: the AppProject would block a sync.
  N1 WARN  declared - {namespace} has a namespace that no path of the module writes to.
  N0 FAIL  a module file is empty, not valid UTF-8 or YAML, not a mapping, or has no name or source.path.
Exit 1 on any FAIL. Exit 2 if the upstream cache is missing, or kustomize cannot run or is not the pinned version.

Usage:
  hack/check_namespaces.py [--chart charts/keelson] [--cache .cache/upstream]
The tag comes from upstream.manifestsRef in values.yaml. $KUSTOMIZE overrides `kustomize`.
"""
import argparse
import os
import pathlib
import subprocess
import sys

import yaml
from kustomize_check import VersionError, check_version

KUSTOMIZE = os.environ.get("KUSTOMIZE", "kustomize")


class MissingTool(Exception):
    pass


def found_namespaces(path: pathlib.Path):
    try:
        r = subprocess.run([KUSTOMIZE, "build", str(path)], capture_output=True, text=True)
    except FileNotFoundError:
        raise MissingTool(f"'{KUSTOMIZE}' not found on PATH; install the pinned kustomize (or set KUSTOMIZE)") from None
    except OSError as e:
        raise MissingTool(f"'{KUSTOMIZE}' cannot run: {e.strerror or e}") from None
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
            fails.append(f"N1 {m['name']}: kustomize build {p} failed: {e}")
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
    try:
        check_version(upstream)
    except VersionError as e:
        print(f"check_namespaces: {e}", file=sys.stderr)
        sys.exit(2)
    except OSError as e:
        what = f"'{KUSTOMIZE}' cannot run" if e.filename == KUSTOMIZE else f"cannot read {e.filename}"
        print(f"check_namespaces: {what}: {e.strerror or e}", file=sys.stderr)
        sys.exit(2)
    fails, modules = 0, 0
    for f in sorted((a.chart / "modules").glob("*.yaml")):
        try:
            m = yaml.safe_load(f.read_text()) or {}
        except UnicodeDecodeError:
            print(f"FAIL N0 {f}: not valid UTF-8")
            fails += 1
            continue
        except yaml.YAMLError as e:
            print(f"FAIL N0 {f}: not valid YAML: {str(e).splitlines()[0]}")
            fails += 1
            continue
        if not isinstance(m, dict) or not isinstance(m.get("source") or {}, dict):
            print(f"FAIL N0 {f}: not a mapping (the file and its source: must be maps)")
            fails += 1
            continue
        # A keelson component (ADR 0004) has no upstream path; its namespaces come from the AppProject (namespacesFrom).
        need_path = (m.get("source") or {}).get("type") != "keelson"
        missing = [k for k, ok in (("name", m.get("name")), ("source.path", (m.get("source") or {}).get("path") or not need_path)) if not ok]
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
