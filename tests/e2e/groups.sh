#!/usr/bin/env bash
# E2E (#66): profiles[].groups give a Keycloak group access to a profile namespace.
# Run it after `make e2e MODULES=profiles` (helm install mode), on the same cluster. It needs the
# keelson.selfSource override that run.sh sets for MODULES=profiles.
#   1. Start upstream's test Keycloak (idp-keycloak.sh). Upgrade the release with
#      tests/e2e/scenarios/groups/values.yaml: a Dex oidc connector to Keycloak, and a profile
#      keelson-e2e-groups with groups [kubeflow-users] and a different owner.
#   2. Wait for the group resources and the new Dex config.
#   3. RBAC: the group member may create pods; the same user without the group may not.
#   4. m2m: a service-account token to a workload in the namespace does not get 401.
#   5. groups.py: log in through Dex and Keycloak; Workspaces gives 200; the dashboard does not
#      list the namespace (the documented v0.1 caveat).
#   6. Comma caveat (#28): add a second group to the user, log in again, and record the Workspaces
#      status. The result is printed, not asserted: docs/configuration/profiles.md states it.
# At the end it deletes the test objects and upgrades the release back to the values it had before.
# The runner reaches kubeflow.example.com and Keycloak through port-forwards; groups.py resolves
# those names to 127.0.0.1 itself, so /etc/hosts is not changed.
set -euo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/e2e/idp-keycloak.sh
source "$(dirname "${BASH_SOURCE[0]}")/idp-keycloak.sh"

ARGOCD_NS="${ARGOCD_NS:-argocd}"
RELEASE=keelson
CHART="$E2E_ROOT/charts/keelson"
SCENARIO="$E2E_ROOT/tests/e2e/scenarios/groups/values.yaml"
NS=keelson-e2e-groups
GROUP=kubeflow-users
SECOND_GROUP=keelson-e2e-second
DEX_SECRET=dex-e2e-keycloak
M2M=keelson-e2e-m2m
DOMAIN="$(py -c 'import yaml,sys;print(yaml.safe_load(open(sys.argv[1]))["domain"])' "$SCENARIO")"

for bin in kubectl helm openssl curl; do command -v "$bin" >/dev/null || fail "missing '$bin' on PATH"; done
[[ "$GATEWAY_PORT" == 8080 ]] || fail "groups.py uses localhost:8080; unset GATEWAY_PORT"
kubectl -n "$ARGOCD_NS" get applications.argoproj.io keelson-profiles >/dev/null 2>&1 \
  || fail "no 'keelson-profiles' Application; run 'make e2e MODULES=profiles' first"

mkdir -p "$E2E_CACHE"
installed="$E2E_CACHE/groups-installed-values.yaml"
helm get values "$RELEASE" -n "$ARGOCD_NS" -o yaml >"$installed" || fail "could not read the values of release $RELEASE"
grep -q 'selfSource' "$installed" || fail "the release has no keelson.selfSource override; run 'make e2e MODULES=profiles' first"

diagnostics() {
  local d="$E2E_CACHE/diagnostics/groups"
  mkdir -p "$d"
  log "Writing diagnostics to $d"
  kubectl -n "$NS" get rolebindings,requestauthentications.security.istio.io,authorizationpolicies.security.istio.io -o yaml >"$d/namespace-auth.yaml" 2>&1 || true
  kubectl -n auth logs -l app=dex --all-containers --tail=500 >"$d/dex.log" 2>&1 || true
  kubectl -n "$KEYCLOAK_NS" logs deployment/keycloak --tail=500 >"$d/keycloak.log" 2>&1 || true
  kubectl -n "$NS" logs "deployment/$M2M" -c istio-proxy --tail=200 >"$d/m2m-istio-proxy.log" 2>&1 || true
  kubectl -n "$ARGOCD_NS" get applications.argoproj.io keelson-profiles dex -o yaml >"$d/applications.yaml" 2>&1 || true
}
cleanup() {
  local rc=$?
  trap - EXIT
  if (( rc != 0 )); then diagnostics; fi
  log "Cleaning up"
  kubectl -n "$NS" delete deployment,service "$M2M" --ignore-not-found >/dev/null 2>&1 || true
  helm upgrade "$RELEASE" "$CHART" -n "$ARGOCD_NS" -f "$installed" >/dev/null 2>&1 || true
  kubectl -n auth delete secret "$DEX_SECRET" --ignore-not-found >/dev/null 2>&1 || true
  keycloak_down
  if [[ -n "${E2E_PF_PID:-}" ]]; then kill "$E2E_PF_PID" 2>/dev/null || true; fi
  # The Profile has Prune=false, so the namespace stays. It is test-only: delete it.
  kubectl delete profile "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  exit "$rc"
}
trap cleanup EXIT

wait_for() {  # wait_for <seconds> <description> <command...>
  local secs="$1" what="$2"; shift 2
  local end=$(( SECONDS + secs ))
  until "$@" >/dev/null 2>&1; do
    (( SECONDS < end )) || fail "$what: not true after ${secs}s"
    sleep 5
  done
}
app_ok() { [[ "$(kubectl -n "$ARGOCD_NS" get applications.argoproj.io "$1" -o jsonpath='{.status.sync.status}/{.status.health.status}')" == Synced/Healthy ]]; }

# 1. Keycloak, the Dex client Secret, and the upgrade.
log "1/6 Starting Keycloak and upgrading Keelson with the groups scenario"
keycloak_up "http://$DOMAIN/dex/callback"
kubectl -n auth create secret generic "$DEX_SECRET" \
  --from-literal=clientID="$KEYCLOAK_CLIENT_ID" --from-literal=clientSecret="$KEYCLOAK_CLIENT_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
helm upgrade "$RELEASE" "$CHART" -n "$ARGOCD_NS" -f "$installed" -f "$SCENARIO" >/dev/null

# 2. The group resources exist and Dex runs the new config.
log "2/6 Waiting for the namespace $NS, its group resources and the Dex config"
wait_for 600 "namespace $NS" kubectl get namespace "$NS"
wait_for 300 "RequestAuthentication keelson-groups" kubectl -n "$NS" get requestauthentications.security.istio.io keelson-groups
wait_for 300 "AuthorizationPolicy keelson-groups" kubectl -n "$NS" get authorizationpolicies.security.istio.io keelson-groups
wait_for 300 "keelson-profiles Synced/Healthy" app_ok keelson-profiles
wait_for 300 "dex Synced/Healthy" app_ok dex
kubectl -n auth rollout status deployment/dex --timeout=300s >/dev/null || fail "the dex rollout did not finish in 300s"
kubectl -n oauth2-proxy rollout status deployment/oauth2-proxy --timeout=300s >/dev/null || fail "the oauth2-proxy rollout did not finish in 300s"

# 3. RBAC through the group RoleBinding only.
log "3/6 RBAC: $KEYCLOAK_EMAIL in group $GROUP"
[[ "$(kubectl auth can-i create pods -n "$NS" --as "$KEYCLOAK_EMAIL" --as-group "$GROUP" 2>/dev/null || true)" == yes ]] \
  || fail "kubectl auth can-i create pods --as $KEYCLOAK_EMAIL --as-group $GROUP -n $NS is not yes"
[[ "$(kubectl auth can-i create pods -n "$NS" --as "$KEYCLOAK_EMAIL" 2>/dev/null || true)" == no ]] \
  || fail "$KEYCLOAK_EMAIL may create pods in $NS without the group; the check above proves nothing"
log "  can-i create pods: yes with the group, no without it"

# 4. m2m: a service-account token to a workload in the namespace. The workload is the e2e registry
# image (upstream registry, pinned by digest in tests/e2e/registry.yaml). The client is the same pod,
# so the request goes out through its sidecar and in through the workload's sidecar.
log "4/6 m2m: a service-account token to a workload in $NS"
image="$(py -c '
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d and d.get("kind") == "Deployment":
        print(d["spec"]["template"]["spec"]["containers"][0]["image"])' "$E2E_ROOT/tests/e2e/registry.yaml")"
[[ "$image" == *@sha256:* ]] || fail "the registry image in tests/e2e/registry.yaml is not pinned by digest"
kubectl -n "$NS" create deployment "$M2M" --image="$image" --port=5000 --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NS" expose deployment "$M2M" --port=5000 --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NS" rollout status "deployment/$M2M" --timeout=300s >/dev/null || fail "deployment $M2M did not become ready"
[[ "$(kubectl -n "$NS" get pods -l "app=$M2M" -o jsonpath='{.items[0].spec.containers[*].name}')" == *istio-proxy* ]] \
  || fail "the $M2M pod has no istio-proxy sidecar, so the RequestAuthentication is not tested"
token="$(kubectl -n "$NS" create token default --duration=10m)"
url="http://$M2M.$NS.svc.cluster.local:5000/v2/"
status() {  # status <authorization header value>: the HTTP status the workload's sidecar returns
  kubectl -n "$NS" exec "deployment/$M2M" -c registry -- \
    wget -S -q -O /dev/null --header "Authorization: $1" "$url" 2>&1 | grep -o 'HTTP/[0-9.]* [0-9]*' | tail -n 1 | awk '{print $2}'
}
bad="$(status 'Bearer not-a-jwt' || true)"
[[ "$bad" == 401 ]] || fail "a malformed token got '${bad:-no answer}', not 401: the namespace RequestAuthentication does not apply"
good="$(status "Bearer $token" || true)"
[[ -n "$good" && "$good" != 401 ]] || fail "a service-account token got '${good:-no answer}': its issuer is missing from the RequestAuthentication"
log "  malformed token: 401; service-account token: $good"

# 5 and 6. Browser login through Dex and Keycloak.
port_forward_gateway
export KEELSON_GROUPS_NAMESPACE="$NS" KEELSON_GROUPS_DOMAIN="$DOMAIN" KEELSON_GROUPS_CONNECTOR=keycloak \
  KEELSON_GROUPS_USER="$KEYCLOAK_USER" KEELSON_GROUPS_PASSWORD="$KEYCLOAK_PASSWORD" \
  KEELSON_GROUPS_EMAIL="$KEYCLOAK_EMAIL" KEELSON_GROUPS_KEYCLOAK_HOST="$KEYCLOAK_HOST" \
  KEELSON_GROUPS_KEYCLOAK_PORT="$KEYCLOAK_PORT"
log "5/6 Login through Dex and Keycloak: Workspaces and the dashboard"
py "$E2E_ROOT/tests/e2e/groups.py" check
log "6/6 Comma caveat (#28): $KEYCLOAK_USER in $GROUP and $SECOND_GROUP"
keycloak_add_group "$SECOND_GROUP"
py "$E2E_ROOT/tests/e2e/groups.py" record-comma

log "groups: OK"
