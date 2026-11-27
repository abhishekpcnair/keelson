#!/usr/bin/env python3
"""Login checks for tests/e2e/groups.sh (#66). Run by that script; it sets the environment.

Logs in like a browser: Kubeflow (oauth2-proxy) -> Dex -> the Keycloak connector -> Keycloak's
login form -> back to Kubeflow. The runner reaches both hosts through port-forwards: the
gateway on localhost:8080 and Keycloak on 127.0.0.1:$KEELSON_GROUPS_KEYCLOAK_PORT. Instead of
changing /etc/hosts, this process resolves the two host names to 127.0.0.1 itself, so the URLs,
the Host headers and the cookies stay as the cluster sees them.

  check         Workspaces API for the namespace gives 200 (the user is only in the group), and
                the dashboard does not list the namespace (the documented v0.1 caveat).
  record-comma  The user is in two groups now. Log in again and print the Workspaces status for
                the comma-joined groups header caveat (#28). It is recorded, not asserted.
"""
import html
import json
import os
import re
import socket
import sys
from urllib.parse import urljoin

import requests

NAMESPACE = os.environ["KEELSON_GROUPS_NAMESPACE"]
DOMAIN = os.environ["KEELSON_GROUPS_DOMAIN"]
CONNECTOR = os.environ["KEELSON_GROUPS_CONNECTOR"]
USER = os.environ["KEELSON_GROUPS_USER"]
PASSWORD = os.environ["KEELSON_GROUPS_PASSWORD"]   # upstream realm.json test value
EMAIL = os.environ["KEELSON_GROUPS_EMAIL"]
KC_HOST = os.environ["KEELSON_GROUPS_KEYCLOAK_HOST"]
KC_PORT = int(os.environ["KEELSON_GROUPS_KEYCLOAK_PORT"])
GATEWAY_PORT = int(os.environ.get("GATEWAY_PORT", "8080"))
TIMEOUT = 15

# host name -> {port in the URL: local port}
ROUTES = {DOMAIN: {80: GATEWAY_PORT}, KC_HOST: {8081: KC_PORT}}
_getaddrinfo = socket.getaddrinfo


def _local_getaddrinfo(host, port, *args, **kwargs):
    route = ROUTES.get(host)
    if route is not None:
        return _getaddrinfo("127.0.0.1", route.get(int(port), port), *args, **kwargs)
    return _getaddrinfo(host, port, *args, **kwargs)


socket.getaddrinfo = _local_getaddrinfo


def fail(msg):
    print(f"FAIL {msg}", flush=True)
    sys.exit(1)


def login():
    """A logged-in session, or fail with the step that broke."""
    s = requests.Session()
    base = f"http://{DOMAIN}"
    r = s.get(f"{base}/", timeout=TIMEOUT)
    # Dex shows one link per connector when there are several; with one it redirects straight on.
    if KC_HOST not in r.url:
        m = re.search(r'href="([^"]*/auth/' + re.escape(CONNECTOR) + r'[^"]*)"', r.text)
        if not m:
            fail(f"no link to the Dex connector '{CONNECTOR}' at {r.url} ({r.status_code})")
        r = s.get(urljoin(r.url, html.unescape(m.group(1))), timeout=TIMEOUT)
    if KC_HOST not in r.url:
        fail(f"Dex did not send the browser to Keycloak; ended at {r.url} ({r.status_code})")
    m = re.search(r'<form[^>]*id="kc-form-login"[^>]*action="([^"]+)"', r.text) or \
        re.search(r'<form[^>]*action="([^"]+)"[^>]*id="kc-form-login"', r.text)
    if not m:
        fail(f"no Keycloak login form at {r.url} ({r.status_code})")
    r = s.post(html.unescape(m.group(1)), data={"username": USER, "password": PASSWORD}, timeout=TIMEOUT)
    if r.status_code != 200 or KC_HOST in r.url or "/dex/" in r.url:
        fail(f"login did not get back to Kubeflow; ended at {r.url} ({r.status_code})")
    if not any(c.name.startswith("oauth2_proxy") for c in s.cookies):
        fail("no oauth2-proxy session cookie after the login")
    print(f"ok   logged in as {USER} through Dex connector '{CONNECTOR}'", flush=True)
    return s


def workspaces_status(s):
    r = s.get(f"http://{DOMAIN}/workspaces/api/v1/workspaces/{NAMESPACE}", timeout=TIMEOUT, allow_redirects=False)
    return r.status_code, r.text[:200]


def check():
    s = login()
    code, body = workspaces_status(s)
    if code != 200:
        fail(f"GET /workspaces/api/v1/workspaces/{NAMESPACE} -> {code}: {body!r}")
    print(f"ok   Workspaces lists {NAMESPACE} for a group member (200)", flush=True)
    r = s.get(f"http://{DOMAIN}/api/workgroup/env-info", timeout=TIMEOUT, allow_redirects=False)
    if r.status_code != 200:
        fail(f"GET /api/workgroup/env-info -> {r.status_code}: {r.text[:200]!r}")
    info = r.json()
    if info.get("user") != EMAIL:
        fail(f"env-info user is {info.get('user')!r}, not {EMAIL!r}")
    listed = [n.get("namespace") for n in info.get("namespaces", [])]
    if NAMESPACE in listed:
        fail(f"the dashboard lists {NAMESPACE}; docs/configuration/profiles.md says it does not. Update the docs")
    print(f"ok   the dashboard does not list {NAMESPACE} (documented caveat); it lists {listed}", flush=True)


def record_comma():
    s = login()
    code, body = workspaces_status(s)
    result = "works" if code == 200 else "fails"
    print(json.dumps({"comma-caveat": result, "workspaces-status": code, "body": body}), flush=True)
    print(f"::notice title=groups comma caveat (#28)::Workspaces with two groups: {code} ({result})", flush=True)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "check":
        check()
    elif cmd == "record-comma":
        record_comma()
    else:
        sys.exit("usage: groups.py check|record-comma")
