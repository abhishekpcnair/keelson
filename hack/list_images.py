#!/usr/bin/env python3
"""List the container images a Keelson release references.

Renders the chart with its default modules, builds every Application's upstream path
(with the Application's inline patches) from .cache/upstream/<tag>, and collects the
`image:` field of every container. Writes:
  <out>/images.txt   sorted, unique, one image per line
  <out>/images.json  {module: [images]}

Backstop for hard rule 2 (no forked images): the build WITH Keelson's patches may not
contain an image that the build WITHOUT them lacks. R5 already stops patches from
setting images; this checks the built result.

Scope: `image:` fields in container specs of the built manifests. Images that a controller
reads from its own ConfigMap or env at run time are not listed. Full per-image SBOMs
come with 0.1.0 final (#61).

Usage:
  hack/list_images.py --out dist [--values FILE] [--cache .cache/upstream]
The kustomize binary ($KUSTOMIZE, default `kustomize`) must match upstream's pin
(see hack/kustomize_check.py).
"""
import argparse
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile

import yaml

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import kustomize_check as kc  # noqa: E402


def images_in(manifests: str) -> set:
    """Every string `image` value under a containers or initContainers list."""
    found = set()

    def walk(node):
        if isinstance(node, dict):
            for key in ("containers", "initContainers", "ephemeralContainers"):
                for c in node.get(key) or []:
                    if isinstance(c, dict) and isinstance(c.get("image"), str):
                        found.add(c["image"])
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)

    for doc in yaml.safe_load_all(manifests):
        walk(doc)
    return found


def rendered_applications(chart: str, values):
    cmd = ["helm", "template", "keelson", chart] + (["-f", str(values)] if values else [])
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"list_images: helm template failed: {r.stderr.strip()}")
    for doc in yaml.safe_load_all(r.stdout):
        if isinstance(doc, dict) and doc.get("kind") == "Application":
            yield doc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=pathlib.Path, required=True)
    ap.add_argument("--chart", default="charts/keelson")
    ap.add_argument("--values", type=pathlib.Path)
    ap.add_argument("--cache", type=pathlib.Path, default=pathlib.Path(".cache/upstream"))
    a = ap.parse_args()

    by_module, errors, trees = {}, [], {}
    with tempfile.TemporaryDirectory() as tmp:
        for app in rendered_applications(a.chart, a.values):
            name = app["metadata"]["name"]
            src = app["spec"]["source"]
            tag = str(src["targetRevision"])
            if tag not in trees:
                upstream = a.cache / tag
                if not upstream.is_dir():
                    sys.exit(f"list_images: {upstream} missing; run 'make upstream-cache TAG={tag}'")
                kc.check_version(upstream)
                trees[tag] = pathlib.Path(tmp) / tag
                shutil.copytree(upstream, trees[tag], ignore=shutil.ignore_patterns(".git"))
            patches = (src.get("kustomize") or {}).get("patches") or []
            rc, base = kc.build(trees[tag], src["path"], [])
            if rc:
                errors.append(f"{name}: build fails: {base.strip()}")
                continue
            rc, patched = kc.build(trees[tag], src["path"], patches) if patches else (0, base)
            if rc:
                errors.append(f"{name}: build with patches fails: {patched.strip()}")
                continue
            ours, upstream_images = images_in(patched), images_in(base)
            for image in sorted(ours - upstream_images):
                errors.append(f"{name}: image '{image}' is not in the upstream build (rule 2: no forked images)")
            by_module[name] = sorted(ours)

    for e in errors:
        print(f"FAIL {e}", file=sys.stderr)
    if errors:
        sys.exit(1)
    unique = sorted({i for imgs in by_module.values() for i in imgs})
    a.out.mkdir(parents=True, exist_ok=True)
    (a.out / "images.txt").write_text("".join(f"{i}\n" for i in unique))
    (a.out / "images.json").write_text(json.dumps(dict(sorted(by_module.items())), indent=2) + "\n")
    print(f"list_images: {len(unique)} unique image(s) from {len(by_module)} module(s), 0 not from upstream")


if __name__ == "__main__":
    main()
