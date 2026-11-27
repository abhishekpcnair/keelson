#!/usr/bin/env bash
# E2E (#43): Dex opens an OIDC connector that Keelson configured.
# Run it after `make e2e` (helm install mode), on the same cluster. It upgrades the Keelson release with
# tests/e2e/scenarios/auth-oidc/values.yaml, waits for the Dex pods that run the new config, and
# checks the Dex log of those pods:
#   - there is a "config connector" line for the connector, and
#   - there is no "Failed to open connector" line.
# Dex starts even when a connector fails to open (continue_on_connector_failure is on in v2.46.1),
# so a Ready pod proves nothing. The log is the check.
# The issuer is the Kind API server, so no extra image is needed. Set AUTH_OIDC_ISSUER to try another
# issuer (a bad URL must fail step 5). You can run the script again: step 3 waits for the pods of the
# new config hash, so it never reads the log of an old pod.
# On failure it writes the Dex log, the Deployment, the Application and the events to
# .cache/e2e/diagnostics/auth-oidc/. At the end it deletes the test objects and upgrades the release
# back to the values it had before (any MODULES scope, with its --set overrides, #129).
set -euo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ARGOCD_NS="${ARGOCD_NS:-argocd}"
RELEASE=keelson
CHART="$E2E_ROOT/charts/keelson"
SCENARIO="$E2E_ROOT/tests/e2e/scenarios/auth-oidc/values.yaml"
ISSUER="${AUTH_OIDC_ISSUER:-https://kubernetes.default.svc}"
CONNECTOR_ID=kind-api
SECRET=dex-e2e-oidc
ANNOTATION='{.spec.template.metadata.annotations.keelson\.io/dex-config}'
BINDING=unauthenticated-oidc-viewer

for bin in kubectl helm openssl; do command -v "$bin" >/dev/null || fail "missing '$bin' on PATH"; done
kubectl -n "$ARGOCD_NS" get applications.argoproj.io dex >/dev/null 2>&1 \
  || fail "no 'dex' Application; run 'make e2e' first"

# Upstream's own binding (wrap, don't copy): the API server serves the issuer documents to
# unauthenticated callers only with it. Delete it at the end only when this script created it.
binding_file="$(upstream_dir)/common/oauth2-proxy/components/allow-unauthenticated-issuer-discovery/clusterrolebinding.unauthenticated-oidc-viewer.yaml"
[[ -f "$binding_file" ]] || fail "$binding_file not found; upstream may have moved it (check during /upstream-bump)"
created_binding=0
kubectl get clusterrolebinding "$BINDING" >/dev/null 2>&1 || created_binding=1

values="$(mktemp)"
diagnostics() {
  local d="$E2E_CACHE/diagnostics/auth-oidc"
  mkdir -p "$d"
  log "Writing diagnostics to $d"
  kubectl -n auth logs -l app=dex --all-containers --tail=500 >"$d/dex.log" 2>&1 || true
  kubectl -n auth get deployment dex -o yaml >"$d/dex-deployment.yaml" 2>&1 || true
  kubectl -n "$ARGOCD_NS" get applications.argoproj.io dex -o yaml >"$d/dex-application.yaml" 2>&1 || true
  kubectl -n auth get events --sort-by=.lastTimestamp >"$d/events.txt" 2>&1 || true
}
cleanup() {
  local rc=$?
  trap - EXIT
  if (( rc != 0 )); then diagnostics; fi
  log "Cleaning up"
  rm -f "$values"
  helm upgrade "$RELEASE" "$CHART" -n "$ARGOCD_NS" -f "$installed" >/dev/null 2>&1 || true
  # Wait until Dex runs the core config again (no keelson.io/dex-config annotation), so a rerun starts clean.
  for _ in $(seq 1 60); do
    [[ -z "$(kubectl -n auth get deployment dex -o jsonpath="$ANNOTATION" 2>/dev/null || true)" ]] && break
    sleep 5
  done
  if (( created_binding == 1 )); then kubectl delete clusterrolebinding "$BINDING" --ignore-not-found >/dev/null 2>&1 || true; fi
  kubectl -n auth delete secret "$SECRET" --ignore-not-found >/dev/null 2>&1 || true
  exit "$rc"
}
# The values of the installed release (the MODULES scenario plus run.sh's --set overrides, such as
# keelson.selfSource for MODULES=profiles). The upgrade adds the scenario on top; cleanup restores them.
installed="$E2E_CACHE/auth-oidc-installed-values.yaml"
mkdir -p "$E2E_CACHE"
helm get values "$RELEASE" -n "$ARGOCD_NS" -o yaml >"$installed" || fail "could not read the values of release $RELEASE"
trap cleanup EXIT

# 1. The binding and a throwaway Secret with random values.
log "1/5 Applying the issuer discovery binding and the throwaway Secret"
kubectl apply -f "$binding_file" >/dev/null
kubectl -n auth create secret generic "$SECRET" \
  --from-literal=clientID="keelson-e2e" \
  --from-literal=clientSecret="$(openssl rand -hex 16)" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# 2. Upgrade the release with the scenario.
log "2/5 Upgrading Keelson with the auth-oidc scenario (issuer $ISSUER)"
# Helm replaces a whole list, so --set cannot change one field of the connector. Use a copy of the file.
sed "s|^\( *issuer: \).*|\1$ISSUER|" "$SCENARIO" >"$values"
grep -q "issuer: $ISSUER" "$values" || fail "could not set the issuer in the scenario values"
helm upgrade "$RELEASE" "$CHART" -n "$ARGOCD_NS" -f "$installed" -f "$values" >/dev/null

# 3. Wait for the Dex pods that run the new config. The release manifest has the hash of the Dex config
# (the keelson.io/dex-config annotation of the pod template). Wait until the Deployment has this hash,
# the dex Application is Synced and Healthy, and the rollout is done.
expected="$(helm get manifest "$RELEASE" -n "$ARGOCD_NS" | grep -o 'keelson.io/dex-config: "[0-9a-f]*"' | head -n 1 | sed 's/.*"\(.*\)"/\1/')"
[[ -n "$expected" ]] || fail "the release manifest has no keelson.io/dex-config hash"
log "3/5 Waiting for Dex to run the config with hash ${expected:0:12}"
for _ in $(seq 1 60); do
  [[ "$(kubectl -n auth get deployment dex -o jsonpath="$ANNOTATION" 2>/dev/null || true)" == "$expected" ]] && break
  sleep 5
done
[[ "$(kubectl -n auth get deployment dex -o jsonpath="$ANNOTATION" 2>/dev/null || true)" == "$expected" ]] \
  || fail "the dex Deployment did not get the new config hash in 300s (did ArgoCD sync the dex Application?)"
for _ in $(seq 1 60); do
  state="$(kubectl -n "$ARGOCD_NS" get applications.argoproj.io dex -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)"
  [[ "$state" == "Synced/Healthy" ]] && break
  sleep 5
done
[[ "${state:-}" == "Synced/Healthy" ]] || fail "the dex Application is ${state:-unknown}, not Synced/Healthy, after 300s"
kubectl -n auth rollout status deployment/dex --timeout=300s >/dev/null || fail "the dex rollout did not finish in 300s"

# 4. Dex opened the connector? Read the log of the pods with the new hash only.
log "4/5 Checking the Dex log"
pods="$(kubectl -n auth get pods -l app=dex -o json | py -c '
import json, sys
want = sys.argv[1]
for p in json.load(sys.stdin)["items"]:
    ann = (p["metadata"].get("annotations") or {}).get("keelson.io/dex-config")
    if ann == want and not p["metadata"].get("deletionTimestamp"):
        print(p["metadata"]["name"])
' "$expected")"
[[ -n "$pods" ]] || fail "no dex pod has the config hash $expected"
logs=""
for p in $pods; do logs+="$(kubectl -n auth logs "$p" --all-containers --tail=-1 2>&1)"$'\n'; done
line="$(grep -m1 "config connector.*connector_id=$CONNECTOR_ID" <<<"$logs" || true)"
[[ -n "$line" ]] || fail "the dex log has no 'config connector' line for '$CONNECTOR_ID'"
log "  $line"

# 5. No failure to open it.
log "5/5 Checking that Dex opened the connector"
if grep -q "Failed to open connector" <<<"$logs"; then
  grep "Failed to open connector" <<<"$logs" | head -n 3 >&2
  fail "Dex failed to open the connector '$CONNECTOR_ID' (issuer $ISSUER)"
fi

log "auth-oidc: OK"
