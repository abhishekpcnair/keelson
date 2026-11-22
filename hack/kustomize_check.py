#!/usr/bin/env python3
"""Build every patched module offline, the way ArgoCD does.

For each rendered Application with inline `spec.source.kustomize.patches`, add the
patches to the upstream path's kustomization (from .cache/upstream/<tag>) and run
`kustomize build`. Fails when a patch does not apply, or applies but changes
nothing (for example, a target that matches no resource).

Usage:
  hack/kustomize_check.py --rendered <file-or-dir> [--cache .cache/upstream]
The kustomize binary ($KUSTOMIZE, default `kustomize`) must match the version
upstream pins in tests/kustomize_install.sh at the tag.
"""
import argparse
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

import yaml

KUSTOMIZE = os.environ.get("KUSTOMIZE", "kustomize")
KFILES = ("kustomization.yaml", "kustomization.yml", "Kustomization")
# Modules that wrap an upstream path with extra objects and delete the rest:
# after all patches, only these kinds may remain (#14). Catches new upstream objects at bump time.
ONLY_KINDS = {"workspace-kinds": {"WorkspaceKind"}}
# The values.schema.json enum for workspaces.kinds must name exactly the WorkspaceKinds upstream ships.
SCHEMA = pathlib.Path(__file__).resolve().parents[1] / "charts/keelson/values.schema.json"


TEMPLATE = SCHEMA.parent / "templates/_translate_workspaceKinds.tpl"


def schema_kinds():
    import json
    return set(json.loads(SCHEMA.read_text())["properties"]["workspaces"]["properties"]["kinds"]["items"]["enum"])


def template_kinds():
    """Names in the keelson.workspaceKinds.all define (Helm can't read the schema, so it keeps a copy)."""
    m = re.search(r'define "keelson\.workspaceKinds\.all" -}}\n(.*?)\{\{- end', TEMPLATE.read_text(), re.S)
    return {line.strip()[2:] for line in m.group(1).splitlines() if line.strip().startswith("- ")} if m else set()


def patched_apps(rendered: pathlib.Path):
    files = sorted(rendered.glob("*.yaml")) if rendered.is_dir() else [rendered]
    for f in files:
        for doc in yaml.safe_load_all(f.read_text()):
            if not isinstance(doc, dict) or doc.get("kind") != "Application":
                continue
            src = doc.get("spec", {}).get("source", {})
            patches = (src.get("kustomize") or {}).get("patches") or []
            if patches:
                yield f"{f.name}:{doc['metadata']['name']}", src, patches


def build(tree: pathlib.Path, path: str, patches):
    d = tree / path
    kfile = next((d / k for k in KFILES if (d / k).exists()), None)
    if kfile is None:
        return 1, f"no kustomization file in {path}"
    original = kfile.read_text()
    try:
        k = yaml.safe_load(original)
        k["patches"] = (k.get("patches") or []) + patches
        kfile.write_text(yaml.safe_dump(k, sort_keys=False))
        r = subprocess.run([KUSTOMIZE, "build", str(d)], capture_output=True, text=True)
        return r.returncode, r.stdout if r.returncode == 0 else r.stderr
    finally:
        kfile.write_text(original)


def check_version(upstream: pathlib.Path):
    m = re.search(r'KUSTOMIZE_VERSION="(v[0-9.]+)"', (upstream / "tests/kustomize_install.sh").read_text())
    if not m:
        sys.exit(f"kustomize_check: no KUSTOMIZE_VERSION in {upstream}/tests/kustomize_install.sh")
    want = m.group(1)
    got = subprocess.run([KUSTOMIZE, "version"], capture_output=True, text=True).stdout.strip()
    if got != want:
        sys.exit(f"kustomize_check: {KUSTOMIZE} is {got or 'missing'}, upstream pins {want}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rendered", type=pathlib.Path, required=True)
    ap.add_argument("--cache", type=pathlib.Path, default=pathlib.Path(".cache/upstream"))
    a = ap.parse_args()
    errors, checked, trees = [], 0, {}
    with tempfile.TemporaryDirectory() as tmp:
        for where, src, patches in patched_apps(a.rendered):
            tag = str(src["targetRevision"])
            if tag not in trees:
                upstream = a.cache / tag
                if not upstream.is_dir():
                    sys.exit(f"kustomize_check: {upstream} missing; run 'make upstream-cache TAG={tag}'")
                check_version(upstream)
                trees[tag] = pathlib.Path(tmp) / tag
                shutil.copytree(upstream, trees[tag], ignore=shutil.ignore_patterns(".git"))
            tree = trees[tag]
            rc, base = build(tree, src["path"], [])
            if rc:
                errors.append(f"{where}: unpatched build fails: {base.strip()}")
                continue
            if where.split(":")[-1] == "workspace-kinds":
                shipped = {d["metadata"]["name"] for d in yaml.safe_load_all(base)
                           if isinstance(d, dict) and d.get("kind") == "WorkspaceKind"}
                if shipped != schema_kinds():
                    errors.append(f"{where}: upstream ships WorkspaceKinds {sorted(shipped)}, "
                                  f"values.schema.json lists {sorted(schema_kinds())}")
                if template_kinds() != schema_kinds():
                    errors.append(f"{where}: {TEMPLATE.name} lists {sorted(template_kinds())}, "
                                  f"values.schema.json lists {sorted(schema_kinds())}")
            for i, p in enumerate(patches):
                rc, out = build(tree, src["path"], [p])
                if rc:
                    errors.append(f"{where}:patches[{i}]: does not apply: {out.strip()}")
                elif out == base:
                    errors.append(f"{where}:patches[{i}]: applies but changes nothing")
            rc, out = build(tree, src["path"], patches)
            if rc:
                errors.append(f"{where}: patches together fail: {out.strip()}")
            elif (allowed := ONLY_KINDS.get(where.split(":")[-1])) is not None:
                left = sorted({f"{d.get('kind')}/{d.get('metadata', {}).get('name')}"
                               for d in yaml.safe_load_all(out) if isinstance(d, dict) and d.get("kind") not in allowed})
                if left:
                    errors.append(f"{where}: only {sorted(allowed)} may remain after patches, found {left}")
            checked += 1
    for e in errors:
        print(f"FAIL {e}")
    print(f"kustomize_check: {checked} patched Application(s) built, {len(errors)} problem(s)")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
