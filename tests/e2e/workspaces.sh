#!/usr/bin/env bash
# Smoke test for the workspaces and workspace-kinds modules (#14).
#
# Run by tests/e2e/run.sh. Needs a running Keelson install and kubectl on the cluster. Step 4 forwards
# the istio-ingressgateway to localhost:8080 itself (upstream's workspaces_test.sh calls that address).
# Uses only upstream test content from .cache/upstream/<tag> (wrap, don't copy):
#   tests/workspace.test.kubeflow-user-example-com.yaml  a PVC + a jupyterlab Workspace
#   tests/workspaces_test.sh                             API authz: 200 for default-editor, 403 otherwise
#   common/user-namespace/base                           the test Profile, when the Profile CRD exists
#
# Environment: KEELSON_ARGOCD_NAMESPACE (argocd), KEELSON_WORKSPACE_TIMEOUT (900s),
#              KEELSON_WORKSPACE_ERROR_GRACE (180s), KEELSON_SYNC_TIMEOUT (300s).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TAG="$(awk '/^upstream:/{u=1; next} /^[^[:space:]#]/{u=0} u && $1=="manifestsRef:"{gsub(/"/,"",$2); print $2; exit}' "$ROOT/charts/keelson/values.yaml")"
UP="$ROOT/.cache/upstream/$TAG"
PROFILE="kubeflow-user-example-com"
ARGOCD_NS="${KEELSON_ARGOCD_NAMESPACE:-argocd}"
WS_TIMEOUT="${KEELSON_WORKSPACE_TIMEOUT:-900}"
ERR_GRACE="${KEELSON_WORKSPACE_ERROR_GRACE:-180}"
SYNC_TIMEOUT="${KEELSON_SYNC_TIMEOUT:-300}"
FIXTURE="$UP/tests/workspace.test.kubeflow-user-example-com.yaml"
WEBHOOK="workspaces-validating-webhook-configuration"

# shellcheck source=tests/e2e/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"   # port_forward_gateway

ok()   { echo "ok   $*"; }
fail() { echo "FAIL $*"; exit 1; }
[[ -f "$FIXTURE" ]] || fail "$FIXTURE not found; run 'make upstream-cache'"

app() { kubectl -n "$ARGOCD_NS" get application "$1" -o "jsonpath=$2"; }

# On a Workspace failure, print what decides the result into the job log: the namespace labels (sidecar
# injection), the Istio policies, the Pod's probes (Istio rewrites them), its events and its logs.
dump_ws_diag() {
  echo "--- diagnostics for namespace $PROFILE"
  echo "namespace labels:"; kubectl get namespace "$PROFILE" --show-labels 2>&1 | sed 's/^/  /' || true
  echo "AuthorizationPolicies and PeerAuthentications:"
  kubectl -n "$PROFILE" get authorizationpolicies.security.istio.io,peerauthentications.security.istio.io 2>&1 | sed 's/^/  /' || true
  echo "workspace:"; kubectl -n "$PROFILE" get workspace test -o jsonpath='{.status}' 2>&1 | sed 's/^/  /' || true; echo
  echo "pods:"; kubectl -n "$PROFILE" get pods -o wide 2>&1 | sed 's/^/  /' || true
  echo "readiness probes per container (after Istio's rewrite):"
  kubectl -n "$PROFILE" get pods -o jsonpath='{range .items[*].spec.containers[*]}{.name}{"\t"}{.readinessProbe}{"\n"}{end}' 2>&1 | sed 's/^/  /' || true
  echo "pod events:"; kubectl -n "$PROFILE" get events --sort-by=.lastTimestamp 2>&1 | tail -15 | sed 's/^/  /' || true
  pod="$(kubectl -n "$PROFILE" get pods -o name 2>/dev/null | head -n1)"
  if [[ -n "$pod" ]]; then
    echo "logs of $pod (last 25 lines per container):"
    kubectl -n "$PROFILE" logs "$pod" --all-containers --tail=25 2>&1 | sed 's/^/  /' || true
  fi
  echo "--- end diagnostics"
}

# 1. The test profile namespace with a default-editor ServiceAccount bound to kubeflow-edit.
#    With the Profile CRD (dashboard module) use upstream's test Profile; the profile controller
#    makes the rest. Without it, make the same three objects the controller makes.
if ! kubectl get namespace "$PROFILE" >/dev/null 2>&1; then
  if kubectl get crd profiles.kubeflow.org >/dev/null 2>&1; then
    kubectl apply -k "$UP/common/user-namespace/base" >/dev/null || fail "could not apply upstream test Profile"
  else
    kubectl create namespace "$PROFILE" >/dev/null || fail "could not create namespace $PROFILE"
    kubectl label namespace "$PROFILE" app.kubernetes.io/part-of=kubeflow-profile >/dev/null \
      || fail "could not label namespace $PROFILE"
    kubectl -n "$PROFILE" create serviceaccount default-editor >/dev/null \
      || fail "could not create ServiceAccount default-editor in $PROFILE"
    kubectl -n "$PROFILE" create rolebinding default-editor --clusterrole=kubeflow-edit \
      --serviceaccount="$PROFILE:default-editor" >/dev/null \
      || fail "could not create RoleBinding default-editor in $PROFILE"
  fi
fi
for _ in $(seq 60); do kubectl -n "$PROFILE" get serviceaccount default-editor >/dev/null 2>&1 && break; sleep 5; done
kubectl -n "$PROFILE" get serviceaccount default-editor >/dev/null 2>&1 \
  && ok "profile namespace $PROFILE with default-editor" \
  || fail "no default-editor ServiceAccount in $PROFILE after 300s. If the namespace is left over from an earlier run, delete it: kubectl delete namespace $PROFILE"

# 2. The jupyterlab WorkspaceKind from the workspace-kinds module.
kubectl get workspacekind jupyterlab >/dev/null 2>&1 && ok "WorkspaceKind jupyterlab installed" \
  || fail "WorkspaceKind jupyterlab missing (is workspaces.kinds empty?)"

# 3. Start a Workspace and wait for Running (the #2 health mapping uses the same field).
trap 'kubectl delete -f "$FIXTURE" --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT
kubectl apply -f "$FIXTURE" >/dev/null
# The controller sets state Error on any Warning event of the Workspace Pod. A normal start has one:
# the readiness probe fails (HTTP 500) until the server is up. So Error is final only if it lasts
# longer than ERR_GRACE seconds (the state flips back to Running when the probe passes).
start=$(date +%s); state=""; last="-"; err_since=0
while (( $(date +%s) - start < WS_TIMEOUT )); do
  state="$(kubectl -n "$PROFILE" get workspace test -o jsonpath='{.status.state}' 2>/dev/null || true)"
  now=$(date +%s)
  if [[ "$state" != "$last" ]]; then log "Workspace test state: ${state:-<none>} (after $(( now - start ))s)"; last="$state"; fi
  [[ "$state" == Running ]] && break
  if [[ "$state" == Error ]]; then
    (( err_since == 0 )) && err_since=$now
    (( now - err_since >= ERR_GRACE )) && break
  else
    err_since=0
  fi
  sleep 10
done
elapsed=$(( $(date +%s) - start ))
[[ "$state" == Running ]] || dump_ws_diag
[[ "$state" == Running ]] && ok "Workspace test is Running after ${elapsed}s" \
  || fail "Workspace test state '${state:-<none>}' after ${elapsed}s (timeout ${WS_TIMEOUT}s, Error grace ${ERR_GRACE}s): $(kubectl -n "$PROFILE" get workspace test -o jsonpath='{.status.stateMessage}' 2>/dev/null)"

# 4. Upstream's API authorization test. It calls localhost:8080, so forward the gateway first.
[[ "$GATEWAY_PORT" == 8080 ]] || fail "upstream's workspaces_test.sh uses localhost:8080; unset GATEWAY_PORT"
port_forward_gateway
# port_forward_gateway replaced our EXIT trap: stop the forward and delete the test Workspace.
trap 'kill "$E2E_PF_PID" 2>/dev/null || true; kubectl delete -f "$FIXTURE" --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT
bash "$UP/tests/workspaces_test.sh" "$PROFILE" >/dev/null 2>&1 && ok "workspaces API: 200 for default-editor, 403 otherwise" \
  || fail "upstream workspaces_test.sh failed (rerun it by hand for curl output)"

# 5. No caBundle fight: force a sync, then the webhook still has a CA and the app stays Synced.
before="$(app workspaces '{.status.operationState.startedAt}')"
rev="$(app workspaces '{.spec.source.targetRevision}')"
kubectl -n "$ARGOCD_NS" patch application workspaces --type merge \
  -p "{\"operation\":{\"initiatedBy\":{\"username\":\"keelson-workspaces-smoke\"},\"sync\":{\"revision\":\"$rev\"}}}" >/dev/null
start=$(date +%s); phase=""
while (( $(date +%s) - start < SYNC_TIMEOUT )); do
  started="$(app workspaces '{.status.operationState.startedAt}')"; phase="$(app workspaces '{.status.operationState.phase}')"
  [[ -n "$started" && "$started" != "$before" && "$phase" =~ ^(Succeeded|Failed|Error)$ ]] && break
  sleep 5
done
[[ "$phase" == Succeeded ]] && ok "forced sync of workspaces: Succeeded" || fail "forced sync of workspaces: ${phase:-Timeout}"
empty="$(kubectl get validatingwebhookconfiguration "$WEBHOOK" -o json \
  | python3 -c 'import json,sys; print(sum(1 for w in json.load(sys.stdin)["webhooks"] if not w["clientConfig"].get("caBundle")))')"
[[ "$empty" == 0 ]] && ok "every workspaces webhook has a caBundle after the sync" || fail "$empty webhook(s) without caBundle"
sync="$(app workspaces '{.status.sync.status}')"
[[ "$sync" == Synced ]] && ok "workspaces Application is Synced" || fail "workspaces Application sync status: $sync"

echo '{"workspaces-smoke": "passed"}'
