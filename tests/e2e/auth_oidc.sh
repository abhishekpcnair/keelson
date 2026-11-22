#!/usr/bin/env bash
# E2E (#43): Dex opens an OIDC connector that Keelson configured.
# Run it after `make e2e MODULES=core`, on the same cluster. It upgrades the Keelson release with
# tests/e2e/scenarios/auth-oidc/values.yaml, waits for the Dex rollout, and checks the Dex log:
#   - there is a "config connector" line for the connector, and
#   - there is no "Failed to open connector" line.
# Dex starts even when a connector fails to open (continue_on_connector_failure is on in v2.46.1),
# so a Ready pod proves nothing. The log is the check.
# The issuer is the Kind API server, so no extra image is needed. Set AUTH_OIDC_ISSUER to try another
# issuer (a bad URL must fail step 5).
# At the end it deletes the test objects and upgrades the release back to the core values.
set -euo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ARGOCD_NS="${ARGOCD_NS:-argocd}"
RELEASE=keelson
CHART="$E2E_ROOT/charts/keelson"
CORE="$E2E_ROOT/tests/golden/kind-core/values.yaml"
SCENARIO="$E2E_ROOT/tests/e2e/scenarios/auth-oidc/values.yaml"
FIXTURE="$E2E_ROOT/tests/e2e/fixtures/oidc-issuer-discovery.yaml"
ISSUER="${AUTH_OIDC_ISSUER:-https://kubernetes.default.svc}"
CONNECTOR_ID=kind-api
SECRET=dex-e2e-oidc

for bin in kubectl helm openssl; do command -v "$bin" >/dev/null || fail "missing '$bin' on PATH"; done
kubectl -n "$ARGOCD_NS" get applications.argoproj.io dex >/dev/null 2>&1 \
  || fail "no 'dex' Application; run 'make e2e MODULES=core' first"

values="$(mktemp)"
cleanup() {
  local rc=$?
  log "Cleaning up"
  rm -f "$values"
  helm upgrade "$RELEASE" "$CHART" -n "$ARGOCD_NS" -f "$CORE" >/dev/null 2>&1 || true
  kubectl delete -f "$FIXTURE" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n auth delete secret "$SECRET" --ignore-not-found >/dev/null 2>&1 || true
  exit "$rc"
}
trap cleanup EXIT

# 1. The fixture and a throwaway Secret with random values.
log "1/5 Applying the issuer discovery binding and the throwaway Secret"
kubectl apply -f "$FIXTURE" >/dev/null
kubectl -n auth create secret generic "$SECRET" \
  --from-literal=clientID="keelson-e2e" \
  --from-literal=clientSecret="$(openssl rand -hex 16)" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# 2. Upgrade the release with the scenario.
log "2/5 Upgrading Keelson with the auth-oidc scenario (issuer $ISSUER)"
# Helm replaces a whole list, so --set cannot change one field of the connector. Use a copy of the file.
sed "s|^\( *issuer: \).*|\1$ISSUER|" "$SCENARIO" >"$values"
grep -q "issuer: $ISSUER" "$values" || fail "could not set the issuer in the scenario values"
helm upgrade "$RELEASE" "$CHART" -n "$ARGOCD_NS" -f "$CORE" -f "$values" >/dev/null

# 3. Wait for the new Dex rollout. The pod template gets the keelson.io/dex-config annotation
# with the Dex config hash, so a Dex that runs the new config has it.
log "3/5 Waiting for the Dex rollout with the connector config"
for _ in $(seq 1 60); do
  ann="$(kubectl -n auth get deployment dex -o jsonpath='{.spec.template.metadata.annotations.keelson\.io/dex-config}' 2>/dev/null || true)"
  [[ -n "$ann" ]] && break
  sleep 5
done
[[ -n "${ann:-}" ]] || fail "the dex Deployment has no keelson.io/dex-config annotation after 300s (did ArgoCD sync the dex Application?)"
kubectl -n auth rollout status deployment/dex --timeout=300s >/dev/null || fail "the dex rollout did not finish in 300s"

# 4. Dex opened the connector? Read the log of the new pods.
log "4/5 Checking the Dex log"
logs="$(kubectl -n auth logs -l app=dex --all-containers --tail=-1 2>&1)" || fail "could not read the dex logs"
grep -q "config connector.*connector_id=$CONNECTOR_ID" <<<"$logs" \
  || fail "the dex log has no 'config connector' line for '$CONNECTOR_ID'"

# 5. No failure to open it.
log "5/5 Checking that Dex opened the connector"
if grep -q "Failed to open connector" <<<"$logs"; then
  grep "Failed to open connector" <<<"$logs" | head -n 3 >&2
  fail "Dex failed to open the connector '$CONNECTOR_ID' (issuer $ISSUER)"
fi

log "auth-oidc: OK"
