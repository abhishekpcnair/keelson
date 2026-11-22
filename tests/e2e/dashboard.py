#!/usr/bin/env python3
"""Smoke test for the dashboard module (issue #7).

Assumes a running Keelson install with the istio-ingressgateway port-forwarded to
KEELSON_ENDPOINT (default http://localhost:8080), as upstream's tests do, and kubectl
pointing at the cluster.

Dex login uses upstream's DexSessionManager from
.cache/upstream/<tag>/tests/dex_login_test.py (imported, not copied: CLAUDE.md rule 1).

Checks:
  1. GET / returns 200 HTML (the dashboard, reached through oauth2-proxy).
  2. GET /api/workgroup/env-info returns JSON whose `user` is the Dex user, which proves
     the kubeflow-userid header path through Istio.
  3. The PodDefault webhook caBundle is non-empty, and still non-empty after a hard
     refresh of the `dashboard` Application and a wait; the Application stays Synced.
"""
import importlib.util
import json
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
DEX_USER = os.environ.get("KEELSON_DEX_USER", "user@example.com")      # upstream static test user (Kind only)
DEX_PASSWORD = os.environ.get("KEELSON_DEX_PASSWORD", "12341234")      # upstream default; not a Keelson secret
ARGOCD_NS = os.environ.get("KEELSON_ARGOCD_NAMESPACE", "argocd")
WEBHOOK = "poddefaults-webhook-mutating-webhook-configuration"
SETTLE_SECONDS = int(os.environ.get("KEELSON_SETTLE_SECONDS", "60"))


def load_upstream_dex():
    path = UPSTREAM_TESTS / "dex_login_test.py"
    if not path.exists():
        sys.exit(f"{path} not found; run 'make upstream-cache'")
    spec = importlib.util.spec_from_file_location("upstream_dex_login_test", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.DexSessionManager


def kubectl(*args):
    return subprocess.run(["kubectl", *args], check=True, capture_output=True, text=True).stdout.strip()


def ca_bundles():
    out = kubectl("get", "mutatingwebhookconfiguration", WEBHOOK,
                  "-o", "jsonpath={range .webhooks[*]}{.clientConfig.caBundle}{'\\n'}{end}")
    return out.splitlines()


def check(ok, msg):
    print(("ok   " if ok else "FAIL ") + msg)
    if not ok:
        sys.exit(1)


def main():
    cookies = load_upstream_dex()(ENDPOINT, DEX_USER, DEX_PASSWORD).get_session_cookies()
    headers = {"Cookie": cookies}

    r = requests.get(f"{ENDPOINT}/", headers=headers, timeout=15)
    check(r.status_code == 200 and "text/html" in r.headers.get("content-type", ""),
          f"GET / -> {r.status_code} {r.headers.get('content-type', '')}")

    r = requests.get(f"{ENDPOINT}/api/workgroup/env-info", headers=headers, timeout=15)
    user = r.json().get("user") if r.ok else None
    check(user == DEX_USER, f"GET /api/workgroup/env-info -> {r.status_code}, user={user!r}")

    bundles = ca_bundles()
    check(bool(bundles) and all(bundles), "webhook caBundle injected by cert-manager")
    kubectl("-n", ARGOCD_NS, "annotate", "application", "dashboard",
            "argocd.argoproj.io/refresh=hard", "--overwrite")
    time.sleep(SETTLE_SECONDS)
    bundles = ca_bundles()
    check(bool(bundles) and all(bundles), f"caBundle still set {SETTLE_SECONDS}s after a hard refresh")
    sync = kubectl("-n", ARGOCD_NS, "get", "application", "dashboard", "-o", "jsonpath={.status.sync.status}")
    check(sync == "Synced", f"dashboard Application sync status: {sync}")
    print(json.dumps({"dashboard-smoke": "passed"}))


if __name__ == "__main__":
    main()
