#!/usr/bin/env python3
"""Detect a newer kubeflow/manifests release than the one Keelson pins.

Prints the newest release tag and exits 0. With --github-output, also writes
`current`, `latest` and `newer=true|false` to $GITHUB_OUTPUT for the workflow.
Release tags look like 26.10.0 or 26.03.1. Release candidates are ignored.

With --tool-pins <file> (for example hack/kind-up.sh), it checks only the tool pins in
TOOL_PINS: one `pin NAME current=... latest=... newer=...` line each. With
--github-output it writes `pins_newer=true|false`, and a Markdown table to pins.md.
Only vX.Y.Z tags count (no -rc, -alpha, -beta). A pin that is not in the file gets a NOTE.
"""
import argparse
import os
import pathlib
import re
import subprocess

import yaml

TAG_RE = re.compile(r"^(\d{2})\.(\d{2})(?:\.(\d+))?$")
SEMVER_RE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
# Variable in the pins file -> upstream repo.
TOOL_PINS = {
    "ARGOCD_VERSION": "https://github.com/argoproj/argo-cd",
    "METRICS_SERVER_VERSION": "https://github.com/kubernetes-sigs/metrics-server",
}


def parse(tag):
    m = TAG_RE.match(tag)
    return tuple(int(x or 0) for x in m.groups()) if m else None


def remote_tags(repo):
    out = subprocess.run(["git", "ls-remote", "--tags", repo], check=True,
                         capture_output=True, text=True).stdout
    return {line.split("refs/tags/")[1].removesuffix("^{}")
            for line in out.splitlines() if "refs/tags/" in line}


def latest_tag(repo):
    releases = [t for t in remote_tags(repo) if parse(t)]
    return max(releases, key=parse)


def semver(tag):
    m = SEMVER_RE.match(tag)
    return tuple(int(x) for x in m.groups()) if m else None


def check_pins(pins_file):
    """Return (rows, any_newer). rows: (name, current, latest, newer); NOTE lines are printed."""
    text = pathlib.Path(pins_file).read_text()
    rows = []
    for name, repo in TOOL_PINS.items():
        m = re.search(rf'^{name}="(v[0-9.]+)"', text, re.M)
        if not m:
            print(f"NOTE pin {name} not found in {pins_file}; skipped")
            continue
        current = m.group(1)
        latest = max((t for t in remote_tags(repo) if semver(t)), key=semver)
        rows.append((name, current, latest, semver(latest) > semver(current)))
    return rows, any(r[3] for r in rows)


def pins_main(a):
    rows, any_newer = check_pins(a.tool_pins)
    for name, current, latest, newer in rows:
        print(f"pin {name} current={current} latest={latest} newer={str(newer).lower()}")
    if a.github_output and os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as fh:
            fh.write(f"pins_newer={str(any_newer).lower()}\n")
        lines = ["| Pin | Current | Latest |", "|---|---|---|"]
        lines += [f"| `{n}` | `{c}` | `{l}`{' (newer)' if new else ''} |" for n, c, l, new in rows]
        pathlib.Path("pins.md").write_text("\n".join(lines) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--values", default="charts/keelson/values.yaml")
    ap.add_argument("--github-output", action="store_true")
    ap.add_argument("--tool-pins", help="check the tool pins in this file instead (for example hack/kind-up.sh)")
    a = ap.parse_args()
    if a.tool_pins:
        pins_main(a)
        return
    values = yaml.safe_load(pathlib.Path(a.values).read_text())
    repo = values["upstream"]["manifestsRepo"]
    current = str(values["upstream"]["manifestsRef"])
    latest = latest_tag(repo)
    newer = parse(latest) > parse(current)
    print(f"current={current} latest={latest} newer={str(newer).lower()}")
    if a.github_output and os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as fh:
            fh.write(f"current={current}\nlatest={latest}\nnewer={str(newer).lower()}\n")


if __name__ == "__main__":
    main()
