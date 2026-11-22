#!/usr/bin/env bash
# Shared helpers for the e2e harness. Source this file; don't run it.
# shellcheck disable=SC2034  # variables are used by the scripts that source this file

E2E_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
E2E_CACHE="$E2E_ROOT/.cache/e2e"
E2E_VENV="$E2E_CACHE/venv"
GATEWAY_PORT="${GATEWAY_PORT:-8080}"

log()  { printf '==> %s\n' "$*"; }
fail() { printf 'e2e: FAIL: %s\n' "$*" >&2; exit 1; }

# Python with PyYAML and requests, from the harness venv when run.sh created it.
py() {
  if [[ -x "$E2E_VENV/bin/python" ]]; then "$E2E_VENV/bin/python" "$@"; else python3 "$@"; fi
}

# .cache/upstream/<manifestsRef>, read from the chart values the same way the Makefile reads it.
upstream_dir() {
  local tag
  tag="$(py -c "import yaml,sys;print(yaml.safe_load(open(sys.argv[1]))['upstream']['manifestsRef'])" \
    "$E2E_ROOT/charts/keelson/values.yaml")" || fail "could not read upstream.manifestsRef"
  [[ -d "$E2E_ROOT/.cache/upstream/$tag" ]] || fail ".cache/upstream/$tag missing; run 'make upstream-cache'"
  printf '%s\n' "$E2E_ROOT/.cache/upstream/$tag"
}

# Forward the Istio ingress gateway to localhost:$GATEWAY_PORT, as upstream's
# tests/port_forward_gateway.sh does. The forward is stopped when the calling shell exits.
port_forward_gateway() {
  local svc i
  svc="$(kubectl get svc -n istio-system -l app=istio-ingressgateway -o jsonpath='{.items[0].metadata.name}')" \
    || fail "no istio-ingressgateway Service in istio-system"
  [[ -n "$svc" ]] || fail "no istio-ingressgateway Service in istio-system"
  mkdir -p "$E2E_CACHE"
  kubectl port-forward -n istio-system "svc/$svc" "$GATEWAY_PORT:80" >"$E2E_CACHE/port-forward.log" 2>&1 &
  E2E_PF_PID=$!
  trap 'kill "$E2E_PF_PID" 2>/dev/null || true' EXIT
  for i in $(seq 1 30); do
    if curl -s -o /dev/null "http://localhost:$GATEWAY_PORT/"; then return 0; fi
    kill -0 "$E2E_PF_PID" 2>/dev/null || fail "port-forward exited: $(cat "$E2E_CACHE/port-forward.log")"
    sleep 2
  done
  fail "gateway did not answer on localhost:$GATEWAY_PORT after 60s"
}
