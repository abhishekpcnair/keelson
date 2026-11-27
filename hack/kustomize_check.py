#!/usr/bin/env python3
"""Build every patched module offline, the way ArgoCD does.

For each rendered Application with inline `spec.source.kustomize.patches` or with
`spec.ignoreDifferences`, add the
patches to the upstream path's kustomization (from .cache/upstream/<tag>) and run
`kustomize build`. Fails when a patch does not apply, or applies but changes
nothing (for example, a target that matches no resource).

ignoreDifferences guard: each entry must name a resource (group, kind, name) in the
unpatched upstream build. An upstream rename then fails here instead of silently
disabling the rule. A `/rules` entry on a ClusterRole also needs `aggregationRule`.

Dex drift guard: when a patch replaces the Dex config.yaml, every key except
DEX_MANAGED (and staticPasswords, when kept) must equal upstream's at the tag, so an upstream
bump that changes them fails here instead of being silently overwritten.

Also checks every restated upstream file (charts/keelson/restated/, see
RESTATED) against the upstream file at upstream.manifestsRef. Drift fails.

External MySQL guard (#39): with database.mode external, the patched pipelines build must have
no bundled MySQL object and no reference to upstream's mysql-secret.

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


def checked_apps(rendered: pathlib.Path):
    files = sorted(rendered.glob("*.yaml")) if rendered.is_dir() else [rendered]
    for f in files:
        for doc in yaml.safe_load_all(f.read_text()):
            if not isinstance(doc, dict) or doc.get("kind") != "Application":
                continue
            src = doc.get("spec", {}).get("source", {})
            patches = (src.get("kustomize") or {}).get("patches") or []
            ignore = doc.get("spec", {}).get("ignoreDifferences") or []
            # Only kustomize paths can be built. A Helm chart source has no `path`.
            if (patches or ignore) and src.get("path"):
                yield f"{f.name}:{doc['metadata']['name']}", src, patches, ignore


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


def check_ignore_differences(where, built: str, entries, errors, path=None):
    """Each ignoreDifferences entry must name a resource in the built upstream overlay.

    Without this check, an upstream rename makes the rule do nothing and the drift
    returns silently. A `/rules` entry on a ClusterRole is for aggregated roles only,
    so each matched role must still have `aggregationRule`.
    """
    docs = [d for d in yaml.safe_load_all(built) if isinstance(d, dict) and d.get("metadata")]
    where_in = f", which is not in {path}" if path else ", which is not in the built overlay"
    for i, e in enumerate(entries):
        group, kind, name, ns = e.get("group", ""), e.get("kind"), e.get("name"), e.get("namespace")
        found = []
        for d in docs:
            api = str(d.get("apiVersion", ""))
            dgroup = api.split("/")[0] if "/" in api else ""
            if dgroup != group or d.get("kind") != kind:
                continue
            if name is not None and d["metadata"].get("name") != name:
                continue
            # kustomize may leave the namespace unset; ArgoCD fills in the destination one.
            if ns is not None and d["metadata"].get("namespace") not in (None, ns):
                continue
            found.append(d)
        label = f"{group + '/' if group else ''}{kind}" + (f" {name}" if name is not None else "")
        if not found:
            errors.append(f"{where}: ignoreDifferences[{i}] names {label}{where_in}")
        elif kind == "ClusterRole" and "/rules" in (e.get("jsonPointers") or []):
            fixed = [d["metadata"].get("name") for d in found if not d.get("aggregationRule")]
            if fixed:
                errors.append(f"{where}: ignoreDifferences[{i}] ignores /rules, but {', '.join(map(str, fixed))} has no aggregationRule")


class VersionError(Exception):
    """The kustomize version check failed. The message has no prefix; each caller adds its own."""


BUNDLED_DB = {"Deployment/mysql", "Service/mysql", "ServiceAccount/mysql", "PersistentVolumeClaim/mysql-pv-claim",
              "Secret/mysql-secret", "AuthorizationPolicy/mysql", "DestinationRule/ml-pipeline-mysql"}


def external_db(patches):
    """True when the patches include the database.mode external delete patch for bundled MySQL (#39).

    Keyed on the delete patch, not on pipeline-install-config: other translations (#38) may patch
    that ConfigMap while bundled MySQL stays."""
    return any("mysql-secret" in str((p.get("target") or {}).get("name", "")) and "$patch: delete" in p.get("patch", "")
               for p in patches)


def _ids(text: str):
    return {f"{d.get('kind')}/{(d.get('metadata') or {}).get('name')}"
            for d in yaml.safe_load_all(text) if isinstance(d, dict)}


def check_external_db(where, base: str, patched: str, errors):
    """External MySQL guard (#39): exactly the bundled MySQL objects are gone, and nothing reads
    upstream's mysql-secret.

    A new upstream consumer of mysql-secret, or a new bundled object, at a bump fails here."""
    removed = _ids(base) - _ids(patched)
    if removed != BUNDLED_DB:
        errors.append(f"{where}: database.mode external must remove exactly {sorted(BUNDLED_DB)}; "
                      f"missing {sorted(BUNDLED_DB - removed)}, unexpected {sorted(removed - BUNDLED_DB)}")
    for d in yaml.safe_load_all(patched):
        if isinstance(d, dict) and d.get("kind") != "Secret" and "mysql-secret" in yaml.safe_dump(d):
            errors.append(f"{where}: {d.get('kind')}/{(d.get('metadata') or {}).get('name')} still reads mysql-secret "
                          f"after the database.mode external patches")
    left = sorted(f"{d.get('kind')}/{(d.get('metadata') or {}).get('name')}" for d in yaml.safe_load_all(patched)
                  if isinstance(d, dict) and f"{d.get('kind')}/{(d.get('metadata') or {}).get('name')}" in BUNDLED_DB)
    if left:
        errors.append(f"{where}: database.mode external leaves bundled MySQL objects: {left}")


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
        for where, src, patches, ignore in checked_apps(a.rendered):
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
            if where.split(":")[-1] == "workspace-kinds":
                shipped = {d["metadata"]["name"] for d in yaml.safe_load_all(base)
                           if isinstance(d, dict) and d.get("kind") == "WorkspaceKind"}
                if shipped != schema_kinds():
                    errors.append(f"{where}: upstream ships WorkspaceKinds {sorted(shipped)}, "
                                  f"values.schema.json lists {sorted(schema_kinds())}")
                if template_kinds() != schema_kinds():
                    errors.append(f"{where}: {TEMPLATE.name} lists {sorted(template_kinds())}, "
                                  f"values.schema.json lists {sorted(schema_kinds())}")
            check_ignore_differences(where, base, ignore, errors, src["path"])
            if not patches:
                checked += 1
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
            elif (allowed := ONLY_KINDS.get(where.split(":")[-1])) is not None:
                left = sorted({f"{d.get('kind')}/{d.get('metadata', {}).get('name')}"
                               for d in yaml.safe_load_all(out) if isinstance(d, dict) and d.get("kind") not in allowed})
                if left:
                    errors.append(f"{where}: only {sorted(allowed)} may remain after patches, found {left}")
            else:
                check_dex_config(where, base, out, errors)
                if where.split(":")[-1] == "pipelines" and external_db(patches):
                    check_external_db(where, base, out, errors)
            checked += 1
    for e in errors:
        print(f"FAIL {e}")
    print(f"kustomize_check: {checked} Application(s) built, {len(errors)} problem(s)")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
