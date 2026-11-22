#!/usr/bin/env python3
"""Build every patched module offline, the way ArgoCD does.

For each rendered Application with inline `spec.source.kustomize.patches`, add the
patches to the upstream path's kustomization (from .cache/upstream/<tag>) and run
`kustomize build`. Fails when a patch does not apply, or applies but changes
nothing (for example, a target that matches no resource).

Dex drift guard: when a patch replaces the Dex config.yaml, every key except
DEX_MANAGED (and staticPasswords, when kept) must equal upstream's at the tag, so an upstream
bump that changes them fails here instead of being silently overwritten.

Also checks every restated upstream file (charts/keelson/restated/, see
RESTATED) against the upstream file at upstream.manifestsRef. Drift fails.

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
DEX_MANAGED = {"connectors", "enablePasswordDB", "staticPasswords"}  # keys Keelson may change

# Chart data file → the upstream file it restates. Both must parse to the same YAML.
RESTATED = {
    "restated/profile-namespace-labels.yaml":
        "applications/dashboard/upstream/profile-controller/overlays/kubeflow-pss/namespace-labels-kubeflow-pss.yaml",
}


def check_restated(chart: pathlib.Path, upstream: pathlib.Path):
    """Errors for each restated file that differs from upstream at the pinned tag."""
    errors = []
    for ours, theirs in RESTATED.items():
        want = upstream / theirs
        if not want.is_file():
            errors.append(f"{chart / ours}: upstream file {theirs} is missing at {upstream.name}")
            continue
        a = yaml.safe_load((chart / ours).read_text())
        b = yaml.safe_load(want.read_text())
        if a != b:
            diff = sorted(set((a or {}).items()) ^ set((b or {}).items()))
            errors.append(f"{chart / ours}: drift from upstream {theirs} at {upstream.name}: {diff}")
    return errors


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


def dex_config(manifests: str):
    for doc in yaml.safe_load_all(manifests):
        if isinstance(doc, dict) and doc.get("kind") == "ConfigMap" and doc["metadata"].get("name") == "dex":
            return yaml.safe_load(doc["data"]["config.yaml"])
    return None


def check_dex_config(where, base: str, patched: str, errors):
    up, ours = dex_config(base), dex_config(patched)
    if up is None or ours is None or up == ours:
        return
    managed = DEX_MANAGED - ({"staticPasswords"} if "staticPasswords" in ours else set())
    for k in sorted((set(up) | set(ours)) - managed):
        if ours.get(k) != up.get(k):
            errors.append(f"{where}: Dex config key '{k}' differs from upstream (update keelson.dex.upstreamConfig)")


class VersionError(Exception):
    """The kustomize version check failed. The message has no prefix; each caller adds its own."""


def check_version(upstream: pathlib.Path):
    m = re.search(r'KUSTOMIZE_VERSION="(v[0-9.]+)"', (upstream / "tests/kustomize_install.sh").read_text())
    if not m:
        raise VersionError(f"no KUSTOMIZE_VERSION in {upstream}/tests/kustomize_install.sh")
    want = m.group(1)
    got = subprocess.run([KUSTOMIZE, "version"], capture_output=True, text=True).stdout.strip()
    if got != want:
        raise VersionError(f"{KUSTOMIZE} is {got or 'missing'}, upstream pins {want}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rendered", type=pathlib.Path, required=True)
    ap.add_argument("--cache", type=pathlib.Path, default=pathlib.Path(".cache/upstream"))
    ap.add_argument("--chart", type=pathlib.Path, default=pathlib.Path("charts/keelson"))
    a = ap.parse_args()
    errors, checked, trees = [], 0, {}
    tag = str(yaml.safe_load((a.chart / "values.yaml").read_text())["upstream"]["manifestsRef"])
    if not (a.cache / tag).is_dir():
        sys.exit(f"kustomize_check: {a.cache / tag} missing; run 'make upstream-cache TAG={tag}'")
    errors += check_restated(a.chart, a.cache / tag)
    with tempfile.TemporaryDirectory() as tmp:
        for where, src, patches in patched_apps(a.rendered):
            tag = str(src["targetRevision"])
            if tag not in trees:
                upstream = a.cache / tag
                if not upstream.is_dir():
                    sys.exit(f"kustomize_check: {upstream} missing; run 'make upstream-cache TAG={tag}'")
                try:
                    check_version(upstream)
                except VersionError as e:
                    sys.exit(f"kustomize_check: {e}")
                trees[tag] = pathlib.Path(tmp) / tag
                shutil.copytree(upstream, trees[tag], ignore=shutil.ignore_patterns(".git"))
            tree = trees[tag]
            rc, base = build(tree, src["path"], [])
            if rc:
                errors.append(f"{where}: unpatched build fails: {base.strip()}")
                continue
            for i, p in enumerate(patches):
                rc, out = build(tree, src["path"], [p])
                if rc:
                    errors.append(f"{where}:patches[{i}]: does not apply: {out.strip()}")
                elif out == base:
                    errors.append(f"{where}:patches[{i}]: applies but changes nothing")
            rc, out = build(tree, src["path"], patches)
            if rc:
                errors.append(f"{where}: patches together fail: {out.strip()}")
            else:
                check_dex_config(where, base, out, errors)
            checked += 1
    for e in errors:
        print(f"FAIL {e}")
    print(f"kustomize_check: {checked} patched Application(s) built, {len(errors)} problem(s)")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
