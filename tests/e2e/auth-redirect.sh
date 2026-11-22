#!/usr/bin/env bash
# Smoke test for istio, oauth2-proxy and dex, with no login:
#   1. an unauthenticated GET / is refused (401 or 403) or redirected to /oauth2/start. It must not be served.
#   2. GET /oauth2/start redirects to Dex (/dex/auth).
#   3. Dex answers with its login page.
# This proves Istio -> oauth2-proxy -> Dex is wired. It also guards a gap in upstream's
# dex_login_test.py, which passes without logging in when "/" is served without authentication.
# Upstream's client does the same: a 401 or 403 on "/" is its cue to start at /oauth2/start.
set -euo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

port_forward_gateway
base="http://localhost:$GATEWAY_PORT"

# hop <url>: print "<status> <absolute Location>" without following redirects.
hop() { curl -s -o /dev/null --max-time 15 -w '%{http_code} %{redirect_url}' "$1"; }

read -r code1 loc1 <<<"$(hop "$base/")" || true
log "GET / -> ${code1:-none} ${loc1:-}"
case "${code1:-none}" in
  401|403) ;;
  302) [[ "$loc1" == */oauth2/start* ]] || fail "GET / redirected to '$loc1', expected /oauth2/start" ;;
  *) fail "an unauthenticated GET / must be refused (401/403) or redirected to /oauth2/start (got '${code1:-none}')" ;;
esac

read -r code2 loc2 <<<"$(hop "$base/oauth2/start")" || true
log "GET /oauth2/start -> ${code2:-none} ${loc2:-}"
[[ "$code2" == 302 && "$loc2" == */dex/auth* ]] \
  || fail "/oauth2/start should redirect to /dex/auth (got '${code2:-none}' '${loc2:-}')"

code3="$(curl -s -o /dev/null --max-time 15 -w '%{http_code}' -L "$loc2")"
log "GET /dex/auth (following redirects) -> $code3"
[[ "$code3" == 200 ]] || fail "Dex login page should answer 200 (got $code3)"

log "auth-redirect: OK"
