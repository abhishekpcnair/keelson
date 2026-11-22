#!/usr/bin/env bash
# Full Dex login through oauth2-proxy, using upstream's own test at the pinned tag
# (tests/dex_login_test.py), run unchanged from .cache/upstream/<tag>/ (wrap, don't copy).
# It needs something serving "/" behind the gateway, so it is the dashboard module's
# smokeTest (#7), not core's. Run auth-redirect.sh first: upstream's test passes
# without logging in when "/" doesn't redirect.
set -euo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_py="$(upstream_dir)/tests/dex_login_test.py"
[[ -f "$test_py" ]] || fail "$test_py not found; upstream may have moved it (check during /upstream-bump)"
[[ "$GATEWAY_PORT" == 8080 ]] || fail "upstream's dex_login_test.py hard-codes localhost:8080; unset GATEWAY_PORT"

port_forward_gateway
log "Running upstream $test_py"
py "$test_py"
log "dex-login: OK"
