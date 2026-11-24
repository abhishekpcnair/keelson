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
     the kubeflow-userid header path through Istio. A `403 RBAC: access denied` right after the
     login is retried (5 tries, 5 s apart, never silent; #139). Any other status fails at once.
  3. Every PodDefault webhook has a non-empty caBundle, and still has one after a forced
     sync of the `dashboard` Application (a sync re-applies the upstream caBundle: "", so this
     is what proves RespectIgnoreDifferences works); the Application stays Synced.
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
SYNC_TIMEOUT_SECONDS = int(os.environ.get("KEELSON_SYNC_TIMEOUT_SECONDS", "300"))
ENV_INFO_TRIES = 5
ENV_INFO_WAIT_SECONDS = 5
GATEWAY_DENY_BODY = "RBAC: access denied"


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
    """caBundle of every webhook, from -o json so an empty value on any webhook shows up."""
    cfg = json.loads(kubectl("get", "mutatingwebhookconfiguration", WEBHOOK, "-o", "json"))
    return [w.get("clientConfig", {}).get("caBundle", "") for w in cfg.get("webhooks", [])]


def app(jsonpath):
    return kubectl("-n", ARGOCD_NS, "get", "application", "dashboard", "-o", f"jsonpath={jsonpath}")


SMOKE_USER = "keelson-dashboard-smoke"


def force_sync():
    """Start a sync of the dashboard Application and wait until that sync has finished.

    Wait first until no operation runs (ArgoCD refuses a new operation while one is in progress).
    Then find our own operation by initiatedBy.username and a new start time.
    """
    deadline = time.time() + SYNC_TIMEOUT_SECONDS
    while app("{.status.operationState.phase}") == "Running" and time.time() < deadline:
        time.sleep(5)
    if app("{.status.operationState.phase}") == "Running":
        return "Blocked: an earlier ArgoCD operation was still running after the timeout"
    before = app("{.status.operationState.startedAt}")
    kubectl("-n", ARGOCD_NS, "patch", "application", "dashboard", "--type", "merge", "-p",
            json.dumps({"operation": {"initiatedBy": {"username": SMOKE_USER},
                                      "sync": {"revision": app("{.spec.source.targetRevision}")}}}))
    while time.time() < deadline:
        user = app("{.status.operationState.operation.initiatedBy.username}")
        phase, started = app("{.status.operationState.phase}"), app("{.status.operationState.startedAt}")
        # A new start time too: an operation left by an earlier smoke run has our username already.
        if user == SMOKE_USER and started != before and phase in ("Succeeded", "Failed", "Error"):
            return phase
        time.sleep(5)
    return "Timeout"


def check(ok, msg):
    print(("ok   " if ok else "FAIL ") + msg)
    if not ok:
        sys.exit(1)


def get_json(r):
    try:
        return r.json()
    except ValueError:
        return {}


def get_env_info(get, sleep=time.sleep, tries=ENV_INFO_TRIES, wait=ENV_INFO_WAIT_SECONDS):
    """GET env-info once, retrying only a gateway `403 RBAC: access denied` (#139).

    `get` is a no-argument callable that returns a requests-like response. Returns
    (response, number of tries). Every retry prints a WARN line, and a retry that
    ended in 200 also writes a GitHub annotation, so a flake is never silent.
    Any other status, and a 403 with another body, is returned at once.
    """
    statuses = []
    for n in range(1, tries + 1):
        r = get()
        statuses.append(r.status_code)
        if r.status_code != 403 or r.text.strip() != GATEWAY_DENY_BODY:
            break
        if n < tries:
            print(f"WARN env-info try {n}/{tries}: 403 {GATEWAY_DENY_BODY}", flush=True)
            sleep(wait)
    else:
        h = r.headers
        print(f"env-info statuses: {statuses}; last: server={h.get('server')!r} "
              f"www-authenticate={h.get('www-authenticate')!r} content-type={h.get('content-type')!r}", flush=True)
        return r, tries
    if r.status_code != 200:
        h = r.headers
        print(f"env-info {r.status_code}: content-type={h.get('content-type')!r} "
              f"www-authenticate={h.get('www-authenticate')!r} server={h.get('server')!r} "
              f"body={r.text[:200]!r}", flush=True)
    elif n > 1:
        print(f"WARN env-info needed {n} tries", flush=True)
        print(f"::warning title=dashboard env-info needed {n} tries::see #139", flush=True)
    return r, n


def main():
    cookies = load_upstream_dex()(ENDPOINT, DEX_USER, DEX_PASSWORD).get_session_cookies()
    check(bool(cookies), "Dex login returned session cookies")
    headers = {"Cookie": cookies}

    # allow_redirects=False: a redirect to the Dex login page would otherwise look like a 200.
    r = requests.get(f"{ENDPOINT}/", headers=headers, timeout=15, allow_redirects=False)
    check(r.status_code == 200 and "text/html" in r.headers.get("content-type", ""),
          f"GET / -> {r.status_code} {r.headers.get('content-type', '')}")

    r, env_tries = get_env_info(
        lambda: requests.get(f"{ENDPOINT}/api/workgroup/env-info", headers=headers, timeout=15, allow_redirects=False))
    user = get_json(r).get("user") if r.status_code == 200 else None
    check(user == DEX_USER, f"GET /api/workgroup/env-info -> {r.status_code}, user={user!r}")

    bundles = ca_bundles()
    check(bool(bundles) and all(bundles), f"caBundle injected by cert-manager on all {len(bundles)} webhook(s)")
    phase = force_sync()
    check(phase == "Succeeded", f"forced sync of the dashboard Application: {phase}")
    bundles = ca_bundles()
    check(bool(bundles) and all(bundles), "caBundle still set on every webhook after the forced sync")
    sync = app("{.status.sync.status}")
    check(sync == "Synced", f"dashboard Application sync status: {sync}")
    print(json.dumps({"dashboard-smoke": "passed", "env-info-tries": env_tries}))


if __name__ == "__main__":
    main()
