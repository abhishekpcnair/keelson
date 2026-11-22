#!/usr/bin/env python3
"""Detect a newer kubeflow/manifests release than the one Keelson pins.

Prints the newest release tag and exits 0. With --github-output, also writes
`current`, `latest` and `newer=true|false` to $GITHUB_OUTPUT for the workflow.
Release tags look like 26.10.0 or 26.03.1. Release candidates are ignored.
"""
import argparse
import os
import pathlib
import re
import subprocess

import yaml

TAG_RE = re.compile(r"^(\d{2})\.(\d{2})(?:\.(\d+))?$")


def parse(tag):
    m = TAG_RE.match(tag)
    return tuple(int(x or 0) for x in m.groups()) if m else None


def latest_tag(repo):
    out = subprocess.run(["git", "ls-remote", "--tags", repo], check=True,
                         capture_output=True, text=True).stdout
    tags = {line.split("refs/tags/")[1].removesuffix("^{}")
            for line in out.splitlines() if "refs/tags/" in line}
    releases = [t for t in tags if parse(t)]
    return max(releases, key=parse)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--values", default="charts/keelson/values.yaml")
    ap.add_argument("--github-output", action="store_true")
    a = ap.parse_args()
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
