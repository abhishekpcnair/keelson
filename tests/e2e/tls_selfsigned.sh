#!/usr/bin/env bash
# E2E (#23): tls.issuer selfsigned serves `domain` over HTTPS with a Keelson-issued certificate.
# Run it after `make e2e` (helm install mode), on the same cluster. It upgrades the Keelson release
# with tests/e2e/scenarios/tls-selfsigned/values.yaml (domain kubeflow.test) and checks:
#   1. the keelson-tls Application is Synced and Healthy, and the Certificate keelson-tls is Ready;
#   2. `curl -k --resolve kubeflow.test:<port>:127.0.0.1 https://kubeflow.test:<port>/` gets
#      oauth2-proxy's sign-in page (or a redirect to /oauth2/start);
#   3. the certificate the gateway serves has the SAN DNS:kubeflow.test (openssl s_client).
# Kind has no load balancer IP, so the gateway's port 443 is port-forwarded to localhost.
# keelson-tls is a component Application (ADR 0004): it pulls the chart under test from the
# in-cluster registry. The script pushes the chart there unless the installed release already
# sets keelson.selfSource (MODULES=profiles).
# On failure it writes the Application, the Certificate, cert-manager's log and the events to
# .cache/e2e/diagnostics/tls-selfsigned/. At the end it upgrades the release back to the values it
# had before, and deletes the Certificate and the Secret (ArgoCD keeps them: no finalizer).
set -euo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ARGOCD_NS="${ARGOCD_NS:-argocd}"
RELEASE=keelson
CHART="$E2E_ROOT/charts/keelson"
SCENARIO="$E2E_ROOT/tests/e2e/scenarios/tls-selfsigned/values.yaml"
DOMAIN=kubeflow.test
TLS_PORT="${TLS_PORT:-8443}"
# shellcheck source=tests/e2e/lib/root-app.sh
source "$E2E_ROOT/tests/e2e/lib/root-app.sh"

for bin in kubectl helm curl openssl; do command -v "$bin" >/dev/null || fail "missing '$bin' on PATH"; done
kubectl -n "$ARGOCD_NS" get applications.argoproj.io kubeflow-istio-resources >/dev/null 2>&1 \
  || fail "no 'kubeflow-istio-resources' Application; run 'make e2e' first"

installed="$E2E_CACHE/tls-selfsigned-installed-values.yaml"
mkdir -p "$E2E_CACHE"
helm get values "$RELEASE" -n "$ARGOCD_NS" -o yaml >"$installed" || fail "could not read the values of release $RELEASE"

app_state() {
  kubectl -n "$ARGOCD_NS" get applications.argoproj.io "$1" -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true
}
diagnostics() {
  local d="$E2E_CACHE/diagnostics/tls-selfsigned"
  mkdir -p "$d"
  log "Writing diagnostics to $d"
  kubectl -n "$ARGOCD_NS" get applications.argoproj.io keelson-tls -o yaml >"$d/keelson-tls-application.yaml" 2>&1 || true
  kubectl -n "$ARGOCD_NS" get applications.argoproj.io kubeflow-istio-resources -o yaml >"$d/kubeflow-istio-resources-application.yaml" 2>&1 || true
  kubectl -n istio-system get certificates.cert-manager.io,certificaterequests.cert-manager.io -o yaml >"$d/certificates.yaml" 2>&1 || true
  kubectl -n istio-system get gateways.networking.istio.io kubeflow-gateway -o yaml >"$d/gateway.yaml" 2>&1 || true
  kubectl -n cert-manager logs -l app.kubernetes.io/component=controller --tail=300 >"$d/cert-manager.log" 2>&1 || true
  kubectl -n istio-system logs -l app=istio-ingressgateway --all-containers --tail=200 >"$d/istio-ingressgateway.log" 2>&1 || true
  kubectl -n istio-system get events --sort-by=.lastTimestamp >"$d/events.txt" 2>&1 || true
}
cleanup() {
  local rc=$?
  trap - EXIT
  if (( rc != 0 )); then diagnostics; fi
  log "Cleaning up"
  if [[ -n "${pf:-}" ]]; then kill "$pf" 2>/dev/null || true; fi
  if [[ -n "${E2E_REG_PF:-}" ]]; then kill "$E2E_REG_PF" 2>/dev/null || true; fi
  if [[ -n "${body:-}" ]]; then rm -f "$body"; fi
  helm upgrade "$RELEASE" "$CHART" -n "$ARGOCD_NS" -f "$installed" >/dev/null 2>&1 || true
  # The keelson-tls Application goes away without a cascade, so delete what it made.
  for _ in $(seq 1 60); do
    kubectl -n "$ARGOCD_NS" get applications.argoproj.io keelson-tls >/dev/null 2>&1 || break
    sleep 5
  done
  kubectl -n istio-system delete certificates.cert-manager.io keelson-tls --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n istio-system delete secret keelson-tls --ignore-not-found >/dev/null 2>&1 || true
  exit "$rc"
}
trap cleanup EXIT

# 1. Upgrade the release with the scenario. The component Application needs the chart under test.
self_source=()
if [[ -z "$(py -c '
import sys, yaml
v = yaml.safe_load(open(sys.argv[1])) or {}
print(((v.get("keelson") or {}).get("selfSource") or {}).get("repoURL", ""))
' "$installed")" ]]; then
  log "1/4 Pushing the chart under test to the e2e registry (keelson-tls is a component Application)"
  e2e_registry_push
  self_source=(--set "keelson.selfSource.repoURL=$E2E_REG_REPO" --set "keelson.selfSource.targetRevision=$E2E_CHART_VERSION")
else
  log "1/4 The installed release already sets keelson.selfSource"
fi
log "1/4 Upgrading Keelson with the tls-selfsigned scenario (domain $DOMAIN)"
helm upgrade "$RELEASE" "$CHART" -n "$ARGOCD_NS" -f "$installed" -f "$SCENARIO" ${self_source[@]+"${self_source[@]}"} >/dev/null

# 2. keelson-tls and the Gateway synced, and the Certificate Ready.
log "2/4 Waiting for keelson-tls and kubeflow-istio-resources to be Synced and Healthy"
for app in keelson-tls kubeflow-istio-resources oauth2-proxy; do
  for _ in $(seq 1 120); do
    state="$(app_state "$app")"
    [[ "$state" == "Synced/Healthy" ]] && break
    sleep 5
  done
  [[ "$state" == "Synced/Healthy" ]] || fail "the $app Application is ${state:-unknown}, not Synced/Healthy, after 600s"
done
kubectl -n istio-system wait certificates.cert-manager.io/keelson-tls --for=condition=Ready --timeout=300s >/dev/null \
  || fail "the Certificate keelson-tls is not Ready after 300s"
log "  Certificate keelson-tls is Ready"

# 3. HTTPS on the gateway: oauth2-proxy answers an unauthenticated GET /.
svc="$(kubectl get svc -n istio-system -l app=istio-ingressgateway -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$svc" ]] || fail "no istio-ingressgateway Service in istio-system"
kubectl port-forward -n istio-system "svc/$svc" "$TLS_PORT:443" >"$E2E_CACHE/tls-port-forward.log" 2>&1 &
pf=$!
body="$(mktemp)"
log "3/4 GET https://$DOMAIN:$TLS_PORT/ (curl -k --resolve $DOMAIN:$TLS_PORT:127.0.0.1)"
code="" loc=""
# The gateway picks up the new Secret a few seconds after the Certificate is Ready: retry the TLS handshake.
for _ in $(seq 1 30); do
  kill -0 "$pf" 2>/dev/null || fail "port-forward exited: $(cat "$E2E_CACHE/tls-port-forward.log")"
  if read -r code loc <<<"$(curl -sk -o "$body" --max-time 15 -w '%{http_code} %{redirect_url}' \
      --resolve "$DOMAIN:$TLS_PORT:127.0.0.1" "https://$DOMAIN:$TLS_PORT/")" && [[ "$code" != 000 ]]; then
    break
  fi
  sleep 2
done
log "  GET / -> ${code:-none} ${loc:-}"
case "${code:-none}" in
  302) [[ "$loc" == */oauth2/start* ]] || fail "GET / redirected to '$loc', expected /oauth2/start" ;;
  401|403) grep -q 'action="/oauth2/start"' "$body" \
    || fail "GET / over HTTPS was refused with $code, but not by oauth2-proxy (no sign-in form)" ;;
  *) fail "an unauthenticated GET / over HTTPS must get oauth2-proxy's sign-in page or a redirect to /oauth2/start (got '${code:-none}')" ;;
esac

# 4. The served certificate is the one Keelson issued for the domain.
log "4/4 Checking the SAN of the served certificate"
san="$(openssl s_client -connect "127.0.0.1:$TLS_PORT" -servername "$DOMAIN" </dev/null 2>/dev/null \
  | openssl x509 -noout -ext subjectAltName 2>/dev/null || true)"
log "  ${san//$'\n'/ }"
grep -q "DNS:$DOMAIN" <<<"$san" || fail "the gateway's certificate has no SAN DNS:$DOMAIN"

log "tls-selfsigned: OK"
