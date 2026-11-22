#!/usr/bin/env python3
"""Machine-check Keelson's hard rules (CLAUDE.md) on rendered chart output, patch files and the git index.

Usage:
  hack/check_rules.py --rendered <file-or-dir> [--patches <dir>] [--repo <dir>] [--templates <dir>] [--allow-repo URL ...]

Checks:
  R1  Every ArgoCD Application source points to an allowed repo.
  R2  No floating revisions (HEAD, master, main, latest, empty) in Applications.
  R3  Every Application has an argocd.argoproj.io/sync-wave annotation.
  R4  Every patch file and inline kustomize patch starts with purpose/upstream/
      remove-when header lines. A strict JSON patch file can't hold # lines,
      so a *.json file in --patches always fails R4. Use YAML.
  R5  No image references outside the upstream images pulled by Kubeflow.
      Keelson must not set images: a YAML, JSON or JSON6902 patch fails if it
      has an `image` key at any depth or a JSON6902 path ending in /image.
      Same rule as keelson.checkPatchImage in the chart.
  R6  No tracked symlinks in the git repo given by --repo (a symlinked .cache
      once leaked a local path). Skipped with a note if git is not installed;
      fails if --repo is not a git repository.
  T1  In --templates *.tpl, a `keelson.<name>:` doc comment comes directly
      before its own `define "keelson.<name>"` (CLAUDE.md lesson, #80).
Exit code 1 if any rule fails.
"""
import argparse
import pathlib
import re
import subprocess
import sys

import yaml

FLOATING = {"", "head", "master", "main", "latest"}
DEFAULT_ALLOWED = ["https://github.com/kubeflow/manifests"]
HEADER_KEYS = ("# purpose:", "# upstream:", "# remove-when:")
# Raw-text check. Same regex as keelson.checkPatchImage in _engine.tpl.
IMAGE_RE = re.compile(r"""(^|[^A-Za-z0-9_])["']?image["']?\s*:|/image($|[^A-Za-z0-9_])""", re.M)


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


def dicts(obj):
    """Every dict in obj, at any depth (including obj itself)."""
    if isinstance(obj, dict):
        yield obj
        for v in obj.values():
            yield from dicts(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from dicts(v)


def patch_sets_image(text: str) -> bool:
    """True if a YAML, JSON or JSON6902 patch sets or changes an image."""
    # Like keelson.checkPatchImage: always check the raw text, then the parsed structure.
    if IMAGE_RE.search(text):
        return True
    try:
        docs = list(yaml.safe_load_all(text))
    except yaml.YAMLError:
        return False
    for d in (d for doc in docs for d in dicts(doc)):
        if "image" in d:
            return True
        if "op" in d and str(d.get("path", "")).rstrip("/").endswith("/image"):
            return True
    return False


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
            if k == "patch" and isinstance(v, str) and patch_sets_image(v):
                errors.append(f"R5 {where}: inline patch sets an image")
            if k == "images":
                errors.append(f"R5 {where}: kustomize.images override is not allowed")


def check_header(where, text, errors):
    head = text.splitlines()[:6]
    for key in HEADER_KEYS:
        if not any(line.strip().lower().startswith(key) for line in head):
            errors.append(f"R4 {where}: missing header line '{key}'")


def check_patches(pdir: pathlib.Path, errors):
    for f in sorted([*pdir.rglob("*.yaml"), *pdir.rglob("*.json")]):
        text = f.read_text()
        check_header(f, text, errors)
        if patch_sets_image(text):
            errors.append(f"R5 {f}: patch sets an image")


def check_symlinks(repo: pathlib.Path, errors):
    try:
        out = subprocess.run(
            ["git", "-C", str(repo), "ls-files", "-s", "-z"],
            capture_output=True, text=True, check=True,
        ).stdout
    except OSError:
        print("NOTE R6 skipped: git is not installed")
        return
    except subprocess.CalledProcessError as e:
        errors.append(f"R6 {repo}: git ls-files failed: {(e.stderr or '').strip()}")
        return
    for entry in filter(None, out.split("\0")):
        meta, _, path = entry.partition("\t")
        if meta.split()[0] == "120000":
            errors.append(f"R6 {path}: tracked symlink")


DOC_RE = re.compile(r"^\s*(keelson\.[A-Za-z0-9_.]+):")


def check_templates(tdir: pathlib.Path, errors):
    for f in sorted(tdir.glob("*.tpl")):
        lines = f.read_text().splitlines()
        i = 0
        while i < len(lines):
            m = re.match(r"^\{\{-?\s*/\*(.*)$", lines[i])
            if not m:
                i += 1
                continue
            start, end = i, i
            while "*/" not in lines[end] and end + 1 < len(lines):
                end += 1
            # The doc text is the rest of the opening line, or the next line.
            first = m.group(1) if m.group(1).strip() else (lines[start + 1] if start + 1 < len(lines) else "")
            doc = DOC_RE.match(first.split("*/")[0])
            i = end + 1
            if not doc:
                continue
            name = doc.group(1)
            nxt = next((j for j in range(end + 1, len(lines)) if lines[j].strip()), None)
            want = re.compile(r'^\{\{-?\s*define\s+"' + re.escape(name) + r'"\s*-?\}\}')
            if nxt is None or not want.match(lines[nxt]):
                errors.append(f"T1 {f}:{start + 1}: doc comment for {name} is not directly above its define")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rendered", type=pathlib.Path)
    ap.add_argument("--patches", type=pathlib.Path)
    ap.add_argument("--repo", type=pathlib.Path)
    ap.add_argument("--templates", type=pathlib.Path)
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
    if a.repo:
        check_symlinks(a.repo, errors)
    if a.templates:
        check_templates(a.templates, errors)
    for e in errors:
        print(f"FAIL {e}")
    print(f"check_rules: {apps} Applications checked, {len(errors)} problem(s)")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
