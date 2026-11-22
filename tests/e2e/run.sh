#!/usr/bin/env bash
# E2E: install Keelson on the current kube context (which must already run ArgoCD,
# for example from `make kind-up`), wait until every Keelson Application is Synced
# and Healthy, then run each enabled module's smoke test.
#
# Usage: tests/e2e/run.sh <core|all> [extra helm args...]
# Environment:
#   E2E_TIMEOUT  how long to wait for Synced + Healthy (default 30m; s/m/h suffix)
#   KEEP=1       after success, keep a gateway port-forward on localhost:8080 open
#                (Ctrl-C to stop) so you can look around by hand
# On failure, diagnostics are written to .cache/e2e/diagnostics/.
set -euo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MODULES="${1:-core}"
shift || true
E2E_TIMEOUT="${E2E_TIMEOUT:-30m}"
RELEASE=keelson
CHART="$E2E_ROOT/charts/keelson"

# 2. Scenario: e2e installs exactly what the golden snapshot shows.
case "$MODULES" in
  core) SCENARIO="$E2E_ROOT/tests/golden/kind-core/values.yaml" ;;
  all)  fail "MODULES=all has no scenario yet; it maps to a broader golden scenario once one exists" ;;
  *)    fail "unknown MODULES '$MODULES' (use core or all)" ;;
esac

to_seconds() {
  local v="$1"
  case "$v" in
    *h) echo $(( ${v%h} * 3600 )) ;;
    *m) echo $(( ${v%m} * 60 )) ;;
    *s) echo "${v%s}" ;;
    *)  echo "$v" ;;
  esac
}
timeout_s="$(to_seconds "$E2E_TIMEOUT")"
[[ "$timeout_s" =~ ^[0-9]+$ ]] || fail "E2E_TIMEOUT '$E2E_TIMEOUT' is not a duration like 30m"

# 1. Prerequisites.
for bin in kubectl helm python3 curl; do
  command -v "$bin" >/dev/null || fail "missing '$bin' on PATH"
done
kubectl cluster-info >/dev/null 2>&1 || fail "no reachable cluster in the current kube context; run 'make kind-up' (#3)"

mkdir -p "$E2E_CACHE"
if [[ ! -x "$E2E_VENV/bin/python" ]]; then
  log "Creating $E2E_VENV"
  python3 -m venv "$E2E_VENV"
fi
"$E2E_VENV/bin/pip" install -q --disable-pip-version-check -r "$E2E_ROOT/tests/e2e/requirements.txt"

ARGOCD_NS="$(py - "$CHART/values.yaml" "$SCENARIO" <<'EOF'
import sys, yaml
ns = (yaml.safe_load(open(sys.argv[1])).get("argocd") or {}).get("namespace")
ns = ((yaml.safe_load(open(sys.argv[2])) or {}).get("argocd") or {}).get("namespace", ns)
print(ns)
EOF
)"
kubectl -n "$ARGOCD_NS" get deployment argocd-server >/dev/null 2>&1 \
  || fail "ArgoCD not found (no argocd-server in namespace '$ARGOCD_NS'); run 'make kind-up' (#3)"

# 6. Diagnostics on any failure from here on.
DIAG="$E2E_CACHE/diagnostics"
collect_diagnostics() {
  rm -rf "$DIAG"; mkdir -p "$DIAG"
  log "Collecting diagnostics into $DIAG"
  kubectl -n "$ARGOCD_NS" get applications -l app.kubernetes.io/part-of=keelson -o wide >"$DIAG/applications.txt" 2>&1 || true
  kubectl -n "$ARGOCD_NS" get applications -l app.kubernetes.io/part-of=keelson -o yaml >"$DIAG/applications.yaml" 2>&1 || true
  kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded -o wide >"$DIAG/pods-not-running.txt" 2>&1 || true
  kubectl get events -A --sort-by=.lastTimestamp >"$DIAG/events.txt" 2>&1 || true
  kubectl -n auth logs -l app=dex --all-containers --tail=500 >"$DIAG/dex.log" 2>&1 || true
  kubectl -n oauth2-proxy logs -l app.kubernetes.io/name=oauth2-proxy --all-containers --tail=500 >"$DIAG/oauth2-proxy.log" 2>&1 || true
  kubectl -n "$ARGOCD_NS" logs statefulset/argocd-application-controller --tail=500 >"$DIAG/argocd-application-controller.log" 2>&1 || true
  sed 's/^/  /' "$DIAG/applications.txt" >&2 || true
}
on_exit() {
  local rc=$?
  if (( rc != 0 )); then collect_diagnostics; fi
  exit "$rc"
}
trap on_exit EXIT

# 3. Install.
log "Installing Keelson ($MODULES: ${SCENARIO#"$E2E_ROOT"/}) into namespace '$ARGOCD_NS'"
helm upgrade --install "$RELEASE" "$CHART" -n "$ARGOCD_NS" -f "$SCENARIO" "$@" >/dev/null
expected="$(helm get manifest "$RELEASE" -n "$ARGOCD_NS" | grep -c '^kind: Application$' || true)"
(( expected > 0 )) || fail "the release rendered no Applications"

# 4. Wait for every Application to be Synced + Healthy.
log "Waiting up to $E2E_TIMEOUT for $expected Applications to be Synced and Healthy"
start=$SECONDS
while :; do
  status="$(kubectl -n "$ARGOCD_NS" get applications -l app.kubernetes.io/part-of=keelson -o json \
    | py -c '
import json, sys
items = json.load(sys.stdin)["items"]
not_ready = []
for a in sorted(items, key=lambda a: a["metadata"]["name"]):
    st = a.get("status", {})
    sync = st.get("sync", {}).get("status", "Unknown")
    health = st.get("health", {}).get("status", "Unknown")
    if (sync, health) != ("Synced", "Healthy"):
        not_ready.append(a["metadata"]["name"] + "=" + sync + "/" + health)
print(len(items), " ".join(not_ready))
')"
  read -r present not_ready <<<"$status" || true
  if (( present == expected )) && [[ -z "${not_ready:-}" ]]; then
    break
  fi
  elapsed=$(( SECONDS - start ))
  if (( elapsed >= timeout_s )); then
    fail "timed out after ${elapsed}s: $present/$expected Applications present; not ready: ${not_ready:-none}"
  fi
  log "[${elapsed}s] $present/$expected present; not ready: ${not_ready:-none}"
  sleep 30
done
log "All $expected Applications Synced and Healthy after $(( SECONDS - start ))s"

# 5. Smoke tests: the distinct smokeTest paths of the enabled modules, in wave order.
smoke_tests=()
while IFS= read -r t; do [[ -n "$t" ]] && smoke_tests+=("$t"); done < <(kubectl -n "$ARGOCD_NS" get applications -l app.kubernetes.io/part-of=keelson \
  -o jsonpath='{range .items[*]}{.metadata.labels.keelson\.io/module}{"\n"}{end}' \
  | py -c '
import sys, yaml, pathlib
root = pathlib.Path(sys.argv[1])
mods = []
for name in filter(None, (l.strip() for l in sys.stdin)):
    m = yaml.safe_load((root / "charts/keelson/modules" / f"{name}.yaml").read_text())
    mods.append((m.get("wave", 0), name, str(m.get("smokeTest", "none")).strip()))
seen = []
for _, _, t in sorted(mods):
    if t != "none" and t not in seen:
        seen.append(t)
print("\n".join(seen))
' "$E2E_ROOT")
if (( ${#smoke_tests[@]} == 0 )); then
  log "No smoke tests for the enabled modules; Healthy is the check"
fi
for t in ${smoke_tests[@]+"${smoke_tests[@]}"}; do
  [[ -f "$E2E_ROOT/$t" ]] || fail "smokeTest '$t' not found"
  log "Smoke test: $t"
  smoke_start=$SECONDS
  bash "$E2E_ROOT/$t" || fail "smoke test $t failed"
  log "Smoke test $t passed in $(( SECONDS - smoke_start ))s"
done

log "e2e ($MODULES): PASS in $(( SECONDS ))s"

if [[ "${KEEP:-0}" == 1 ]]; then
  trap - EXIT
  log "KEEP=1: forwarding the gateway to http://localhost:$GATEWAY_PORT (Ctrl-C to stop)"
  svc="$(kubectl get svc -n istio-system -l app=istio-ingressgateway -o jsonpath='{.items[0].metadata.name}')"
  exec kubectl port-forward -n istio-system "svc/$svc" "$GATEWAY_PORT:80"
fi
