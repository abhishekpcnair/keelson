#!/usr/bin/env bash
# Smoke test for istio, oauth2-proxy and dex, with no login:
#   1. an unauthenticated GET / reaches oauth2-proxy through Istio's ext_authz and gets either
#      a redirect to /oauth2/start, or oauth2-proxy's own sign-in page (401/403 with its sign-in
#      form). A refusal by Istio itself ("RBAC: access denied") fails: ext_authz never ran.
#   2. GET /oauth2/start redirects to Dex (/dex/auth).
#   3. Dex answers with its login page.
# Hop 1 is the only one that goes through ext_authz: both AuthorizationPolicies exclude /oauth2/*
# and /dex/*, so hops 2 and 3 only prove that oauth2-proxy and Dex answer behind the gateway.
# It also guards a gap in upstream's dex_login_test.py, which accepts any 401/403 on "/".
set -euo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

port_forward_gateway
base="http://localhost:$GATEWAY_PORT"
mkdir -p "$E2E_CACHE"
body="$E2E_CACHE/auth-redirect.body"

read -r code1 loc1 <<<"$(curl -s -o "$body" --max-time 15 -w '%{http_code} %{redirect_url}' "$base/")" || true
log "GET / -> ${code1:-none} ${loc1:-}"
log "  body (first 200 bytes): $(head -c 200 "$body" | tr '\n' ' ')"
case "${code1:-none}" in
  302)
    [[ "$loc1" == */oauth2/start* ]] || fail "GET / redirected to '$loc1', expected /oauth2/start" ;;
  401|403)
    # oauth2-proxy's sign-in page has a form that posts to /oauth2/start. Istio's own denial
    # is the plain text "RBAC: access denied", which means the request never reached oauth2-proxy.
    grep -q 'action="/oauth2/start"' "$body" \
      || fail "GET / was refused with $code1, but not by oauth2-proxy (no sign-in form in the body). Istio denied it before ext_authz reached oauth2-proxy; see #106" ;;
  *)
    fail "an unauthenticated GET / must get oauth2-proxy's sign-in page or a redirect to /oauth2/start (got '${code1:-none}')" ;;
esac

read -r code2 loc2 <<<"$(curl -s -o /dev/null --max-time 15 -w '%{http_code} %{redirect_url}' "$base/oauth2/start")" || true
log "GET /oauth2/start -> ${code2:-none} ${loc2:-}"
[[ "$code2" == 302 && "$loc2" == */dex/auth* ]] \
  || fail "/oauth2/start should redirect to /dex/auth (got '${code2:-none}' '${loc2:-}')"

code3="$(curl -s -o /dev/null --max-time 15 -w '%{http_code}' -L "$loc2")"
log "GET /dex/auth (following redirects) -> $code3"
[[ "$code3" == 200 ]] || fail "Dex login page should answer 200 (got $code3)"

log "auth-redirect: OK"
