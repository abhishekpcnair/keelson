#!/usr/bin/env bash
# Smoke test for the dashboard module (#7), run by tests/e2e/run.sh after every Application
# is Synced and Healthy. Two steps:
#   1. upstream's own full Dex login (dex-login.sh runs tests/dex_login_test.py unchanged);
#   2. tests/e2e/dashboard.py: UI, env-info, and the webhook caBundle after a forced sync.
set -euo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ "$GATEWAY_PORT" == 8080 ]] || fail "dashboard.py and upstream's dex_login_test.py use localhost:8080; unset GATEWAY_PORT"

bash "$E2E_ROOT/tests/e2e/dex-login.sh"
sleep 3   # let the first port-forward release localhost:8080

port_forward_gateway
log "Running tests/e2e/dashboard.py"
py "$E2E_ROOT/tests/e2e/dashboard.py"
log "dashboard: OK"
