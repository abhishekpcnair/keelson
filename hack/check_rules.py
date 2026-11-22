#!/usr/bin/env python3
"""Machine-check Keelson's hard rules (CLAUDE.md) on rendered chart output and patch files.

Usage:
  hack/check_rules.py --rendered <file-or-dir> [--patches <dir>] [--allow-repo URL ...]

Checks:
  R1  Every ArgoCD Application source points to an allowed repo.
  R2  No floating revisions (HEAD, master, main, latest, empty) in Applications.
  R3  Every Application has an argocd.argoproj.io/sync-wave annotation.
  R4  Every patch file and inline kustomize patch starts with purpose/upstream/
      remove-when header lines.
  R5  No image references outside the upstream images pulled by Kubeflow
      (Keelson must not set images; any `image:` key in inline patches fails).
Exit code 1 if any rule fails.
"""
import argparse
import pathlib
import sys

import yaml

FLOATING = {"", "head", "master", "main", "latest"}
DEFAULT_ALLOWED = ["https://github.com/kubeflow/manifests"]
HEADER_KEYS = ("# purpose:", "# upstream:", "# remove-when:")


def load_docs(path: pathlib.Path):
    files = sorted(path.rglob("*.yaml")) if path.is_dir() else [path]
    for f in files:
        for doc in yaml.safe_load_all(f.read_text()):
            if isinstance(doc, dict):
                yield f, doc


def walk(obj):
    if isinstance(obj, dict):
        for k, v in obj.items():
            yield k, v
            yield from walk(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from walk(v)


def check_app(f, app, allowed, errors):
    name = app.get("metadata", {}).get("name", "<unnamed>")
    where = f"{f}:{name}"
    ann = app.get("metadata", {}).get("annotations") or {}
    if "argocd.argoproj.io/sync-wave" not in ann:
        errors.append(f"R3 {where}: missing sync-wave annotation")
    spec = app.get("spec", {})
    sources = spec.get("sources") or ([spec["source"]] if "source" in spec else [])
    if not sources:
        errors.append(f"R1 {where}: no source")
    for s in sources:
        repo = (s.get("repoURL") or "").rstrip("/")
        if not any(repo == a.rstrip("/") for a in allowed):
            errors.append(f"R1 {where}: repo not allowed: {repo or '<empty>'}")
        rev = str(s.get("targetRevision", "")).strip()
        if rev.lower() in FLOATING:
            errors.append(f"R2 {where}: floating targetRevision '{rev}'")
        for i, p in enumerate((s.get("kustomize") or {}).get("patches") or []):
            check_header(f"{where}:patches[{i}]", str((p or {}).get("patch", "")), errors)
        for k, v in walk(s.get("kustomize", {})):
            if k == "patch" and isinstance(v, str) and "image:" in v:
                errors.append(f"R5 {where}: inline patch sets an image")
            if k == "images":
                errors.append(f"R5 {where}: kustomize.images override is not allowed")


def check_header(where, text, errors):
    head = text.splitlines()[:6]
    for key in HEADER_KEYS:
        if not any(line.strip().lower().startswith(key) for line in head):
            errors.append(f"R4 {where}: missing header line '{key}'")


def check_patches(pdir: pathlib.Path, errors):
    for f in sorted(pdir.rglob("*.yaml")):
        check_header(f, f.read_text(), errors)
        if "image:" in f.read_text():
            errors.append(f"R5 {f}: patch sets an image")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rendered", type=pathlib.Path)
    ap.add_argument("--patches", type=pathlib.Path)
    ap.add_argument("--allow-repo", action="append", default=[])
    a = ap.parse_args()
    allowed = DEFAULT_ALLOWED + a.allow_repo
    errors, apps = [], 0
    if a.rendered and a.rendered.exists():
        for f, doc in load_docs(a.rendered):
            if doc.get("kind") == "Application" and str(doc.get("apiVersion", "")).startswith("argoproj.io/"):
                apps += 1
                check_app(f, doc, allowed, errors)
    if a.patches and a.patches.exists():
        check_patches(a.patches, errors)
    for e in errors:
        print(f"FAIL {e}")
    print(f"check_rules: {apps} Applications checked, {len(errors)} problem(s)")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
