#!/usr/bin/env python3
"""Smoke test for the keelson-profiles module (issue #9).

Assumes a running Keelson install from the `profiles` golden values (profile
kubeflow-user-example-com, owner user@example.com, contributor bob@example.com),
the istio-ingressgateway port-forwarded to KEELSON_ENDPOINT (default
http://localhost:8080), and kubectl pointing at the cluster.

Dex login uses upstream's DexSessionManager from
.cache/upstream/<tag>/tests/dex_login_test.py (imported, not copied: CLAUDE.md rule 1).

Checks:
  1. The profile controller has created the namespace.
  2. The contributor may create pods there (RBAC); an unlisted user may not.
  3. As the owner, the dashboard lists the namespace with role owner, and lists
     the contributor (KFAM reads Keelson's RoleBinding).
  4. keelson-profiles is still Synced 60 s after a hard refresh: no fight with the
     profile controller or KFAM.
"""
import importlib.util
import os
import pathlib
import subprocess
import sys
import time

import requests
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
TAG = yaml.safe_load((ROOT / "charts/keelson/values.yaml").read_text())["upstream"]["manifestsRef"]
UPSTREAM_TESTS = ROOT / ".cache/upstream" / TAG / "tests"
ENDPOINT = os.environ.get("KEELSON_ENDPOINT", "http://localhost:8080")
OWNER = os.environ.get("KEELSON_DEX_USER", "user@example.com")          # upstream static test user (Kind only)
PASSWORD = os.environ.get("KEELSON_DEX_PASSWORD", "12341234")           # upstream default; not a Keelson secret
NAMESPACE = os.environ.get("KEELSON_PROFILE", "kubeflow-user-example-com")
CONTRIBUTOR = os.environ.get("KEELSON_CONTRIBUTOR", "bob@example.com")
ARGOCD_NS = os.environ.get("KEELSON_ARGOCD_NAMESPACE", "argocd")
WAIT_SECONDS = int(os.environ.get("KEELSON_PROFILE_TIMEOUT_SECONDS", "300"))


def load_upstream_dex():
    path = UPSTREAM_TESTS / "dex_login_test.py"
    if not path.exists():
        sys.exit(f"{path} not found; run 'make upstream-cache'")
    spec = importlib.util.spec_from_file_location("upstream_dex_login_test", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.DexSessionManager


def kubectl(*args, check=True):
    r = subprocess.run(["kubectl", *args], capture_output=True, text=True)
    if check and r.returncode:
        sys.exit(f"kubectl {' '.join(args)}: {r.stderr.strip()}")
    return r.stdout.strip()


def check(ok, msg):
    print(("ok   " if ok else "FAIL ") + msg)
    if not ok:
        sys.exit(1)


def wait_for_namespace():
    deadline = time.time() + WAIT_SECONDS
    while time.time() < deadline:
        if kubectl("get", "namespace", NAMESPACE, "-o", "name", check=False):
            return True
        time.sleep(5)
    return False


def can_i(user):
    return kubectl("auth", "can-i", "create", "pods", "-n", NAMESPACE, "--as", user, check=False) == "yes"


def app(jsonpath):
    return kubectl("-n", ARGOCD_NS, "get", "applications.argoproj.io", "keelson-profiles", "-o", f"jsonpath={jsonpath}")


def main():
    check(wait_for_namespace(), f"profile controller created namespace {NAMESPACE}")
    check(can_i(CONTRIBUTOR), f"{CONTRIBUTOR} may create pods in {NAMESPACE}")
    check(not can_i("nobody@example.com"), f"an unlisted user may not create pods in {NAMESPACE}")

    cookies = load_upstream_dex()(ENDPOINT, OWNER, PASSWORD).get_session_cookies()
    check(bool(cookies), "Dex login returned session cookies")
    headers = {"Cookie": cookies}
    r = requests.get(f"{ENDPOINT}/api/workgroup/env-info", headers=headers, timeout=15, allow_redirects=False)
    roles = {n.get("namespace"): n.get("role") for n in (r.json().get("namespaces") or [])} if r.ok else {}
    check(roles.get(NAMESPACE) == "owner", f"env-info lists {NAMESPACE} with role owner: {roles.get(NAMESPACE)!r}")
    r = requests.get(f"{ENDPOINT}/api/workgroup/get-contributors/{NAMESPACE}", headers=headers,
                     timeout=15, allow_redirects=False)
    check(r.ok and CONTRIBUTOR in r.text, f"dashboard lists contributor {CONTRIBUTOR}: {r.status_code}")

    kubectl("-n", ARGOCD_NS, "annotate", "applications.argoproj.io", "keelson-profiles",
            "argocd.argoproj.io/refresh=hard", "--overwrite")
    time.sleep(60)
    sync, health = app("{.status.sync.status}"), app("{.status.health.status}")
    check(sync == "Synced" and health == "Healthy", f"keelson-profiles after hard refresh + 60 s: {sync}/{health}")
    print('{"profiles-smoke": "passed"}')


if __name__ == "__main__":
    main()
