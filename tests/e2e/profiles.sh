#!/usr/bin/env bash
# Smoke test for the keelson-profiles module (#9), run by tests/e2e/run.sh after every
# Application is Synced and Healthy. Forwards the gateway to localhost:8080, then runs
# tests/e2e/profiles.py.
set -euo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ "$GATEWAY_PORT" == 8080 ]] || fail "profiles.py and upstream's dex_login_test.py use localhost:8080; unset GATEWAY_PORT"

port_forward_gateway
log "Running tests/e2e/profiles.py"
py "$E2E_ROOT/tests/e2e/profiles.py"
log "profiles: OK"
