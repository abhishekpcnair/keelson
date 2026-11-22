#!/usr/bin/env bash
# Smoke test for istio, oauth2-proxy and dex: an unauthenticated request to the
# gateway must redirect to oauth2-proxy (/oauth2/start), which must redirect to Dex (/dex/auth).
# This proves Istio ext-authz -> oauth2-proxy -> Dex is wired. It also guards a gap in
# upstream's dex_login_test.py, which passes without logging in when nothing redirects.
set -euo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

port_forward_gateway
base="http://localhost:$GATEWAY_PORT"

# hop <url>: print "<status> <absolute Location>" without following redirects.
hop() { curl -s -o /dev/null --max-time 15 -w '%{http_code} %{redirect_url}' "$1"; }

read -r code1 loc1 <<<"$(hop "$base/")" || true
log "GET / -> ${code1:-none} ${loc1:-}"
[[ "$code1" == 302 && "$loc1" == */oauth2/start* ]] \
  || fail "GET / should redirect to /oauth2/start (got '${code1:-none}' '${loc1:-}')"

read -r code2 loc2 <<<"$(hop "$loc1")" || true
log "GET /oauth2/start -> ${code2:-none} ${loc2:-}"
[[ "$code2" == 302 && "$loc2" == */dex/auth* ]] \
  || fail "/oauth2/start should redirect to /dex/auth (got '${code2:-none}' '${loc2:-}')"

code3="$(curl -s -o /dev/null --max-time 15 -w '%{http_code}' -L "$loc2")"
log "GET /dex/auth (following redirects) -> $code3"
[[ "$code3" == 200 ]] || fail "Dex login page should answer 200 (got $code3)"

log "auth-redirect: OK"
