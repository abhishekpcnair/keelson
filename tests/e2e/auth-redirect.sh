#!/usr/bin/env bash
# Smoke test for istio, oauth2-proxy and dex, with no login:
#   1. an unauthenticated GET on a routed, protected path reaches oauth2-proxy through Istio's
#      ext_authz and gets either a redirect to /oauth2/start, or oauth2-proxy's own sign-in page
#      (401/403 with its sign-in form). A refusal by Istio itself ("RBAC: access denied") fails:
#      ext_authz never ran.
#   2. GET /oauth2/start redirects to Dex (/dex/auth).
#   3. Dex answers with its login page.
#   4. An unauthenticated GET / is not served (fail-closed).
# Core has no workload at "/" and Envoy skips ext_authz for a request that matches no route (#106).
# So hop 1 uses a test-only route, /keelson-e2e/ (tests/e2e/fixtures/protected-route.yaml), applied
# here and deleted at the end. The route goes to Dex, which cannot return oauth2-proxy's sign-in
# form, so the form in hop 1 proves that ext_authz answered. Hops 2 and 3 only prove that oauth2-proxy and Dex answer behind the
# gateway: both AuthorizationPolicies exclude /oauth2/* and /dex/*.
# It also guards a gap in upstream's dex_login_test.py, which accepts any 401/403 on "/".
set -euo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fixture="$E2E_ROOT/tests/e2e/fixtures/protected-route.yaml"
kubectl apply -f "$fixture" >/dev/null || fail "could not apply $fixture"
port_forward_gateway
# port_forward_gateway set an EXIT trap that stops the forward. Keep that, and delete the route too.
trap 'kubectl delete -f "$fixture" --ignore-not-found >/dev/null 2>&1 || true; kill "$E2E_PF_PID" 2>/dev/null || true' EXIT

base="http://localhost:$GATEWAY_PORT"
protected="$base/keelson-e2e/"
body="$E2E_CACHE/auth-redirect.body"
mkdir -p "$E2E_CACHE"

# istiod pushes the new route to the gateway in a few seconds. Until then the path has no route, and
# the gateway answers "RBAC: access denied". Retry only for that answer.
deadline=$((SECONDS + ${AUTH_REDIRECT_WAIT:-60}))
while :; do
  read -r code1 loc1 <<<"$(curl -s -o "$body" --max-time 15 -w '%{http_code} %{redirect_url}' "$protected")" || true
  log "GET /keelson-e2e/ -> ${code1:-none} ${loc1:-} (after ${SECONDS}s)"
  if ! grep -q 'RBAC: access denied' "$body" || (( SECONDS >= deadline )); then break; fi
  sleep 3
done
log "  body (first 200 bytes): $(head -c 200 "$body" | tr '\n' ' ')"
case "${code1:-none}" in
  302)
    [[ "$loc1" == */oauth2/start* ]] || fail "GET /keelson-e2e/ redirected to '$loc1', expected /oauth2/start" ;;
  401|403)
    # oauth2-proxy's sign-in page has a form that posts to /oauth2/start. Istio's own denial
    # is the plain text "RBAC: access denied", which means the request never reached oauth2-proxy.
    grep -q 'action="/oauth2/start"' "$body" \
      || fail "GET /keelson-e2e/ was refused with $code1, but not by oauth2-proxy (no sign-in form in the body). Istio denied it before ext_authz reached oauth2-proxy; see #106" ;;
  *)
    fail "an unauthenticated GET /keelson-e2e/ must get oauth2-proxy's sign-in page or a redirect to /oauth2/start (got '${code1:-none}')" ;;
esac

read -r code2 loc2 <<<"$(curl -s -o /dev/null --max-time 15 -w '%{http_code} %{redirect_url}' "$base/oauth2/start?rd=/keelson-e2e/")" || true
log "GET /oauth2/start -> ${code2:-none} ${loc2:-}"
[[ "$code2" == 302 && "$loc2" == */dex/auth* ]] \
  || fail "/oauth2/start should redirect to /dex/auth (got '${code2:-none}' '${loc2:-}')"

code3="$(curl -s -o /dev/null --max-time 15 -w '%{http_code}' -L "$loc2")"
log "GET /dex/auth (following redirects) -> $code3"
[[ "$code3" == 200 ]] || fail "Dex login page should answer 200 (got $code3)"

# Fail-closed: with no workload at "/", the gateway denies (403 RBAC). With the dashboard, ext_authz
# shows the sign-in page (403) or redirects (302). Only these answers are fine. Any other answer
# (200, 404, 5xx) means "/" was served, or the gateway failed, so the check fails.
code4="$(curl -s -o /dev/null --max-time 15 -w '%{http_code}' "$base/")"
log "GET / -> $code4"
case "$code4" in
  302|401|403) ;;
  *) fail "an unauthenticated GET / must be refused (302, 401 or 403), got $code4" ;;
esac

log "auth-redirect: OK"
