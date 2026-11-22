#!/usr/bin/env bash
# Smoke test for the workspaces and workspace-kinds modules (#14).
#
# Needs a running Keelson install, kubectl on the cluster, and the istio-ingressgateway
# port-forwarded to localhost:8080 (upstream's workspaces_test.sh calls that address).
# Uses only upstream test content from .cache/upstream/<tag> (wrap, don't copy):
#   tests/workspace.test.kubeflow-user-example-com.yaml  a PVC + a jupyterlab Workspace
#   tests/workspaces_test.sh                             API authz: 200 for default-editor, 403 otherwise
#   common/user-namespace/base                           the test Profile, when the Profile CRD exists
#
# Environment: KEELSON_ARGOCD_NAMESPACE (argocd), KEELSON_WORKSPACE_TIMEOUT (900s),
#              KEELSON_SYNC_TIMEOUT (300s).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TAG="$(awk '/^upstream:/{u=1; next} /^[^[:space:]#]/{u=0} u && $1=="manifestsRef:"{gsub(/"/,"",$2); print $2; exit}' "$ROOT/charts/keelson/values.yaml")"
UP="$ROOT/.cache/upstream/$TAG"
PROFILE="kubeflow-user-example-com"
ARGOCD_NS="${KEELSON_ARGOCD_NAMESPACE:-argocd}"
WS_TIMEOUT="${KEELSON_WORKSPACE_TIMEOUT:-900}"
SYNC_TIMEOUT="${KEELSON_SYNC_TIMEOUT:-300}"
FIXTURE="$UP/tests/workspace.test.kubeflow-user-example-com.yaml"
WEBHOOK="workspaces-validating-webhook-configuration"

ok()   { echo "ok   $*"; }
fail() { echo "FAIL $*"; exit 1; }
[[ -f "$FIXTURE" ]] || fail "$FIXTURE not found; run 'make upstream-cache'"

app() { kubectl -n "$ARGOCD_NS" get application "$1" -o "jsonpath=$2"; }

# 1. The test profile namespace with a default-editor ServiceAccount bound to kubeflow-edit.
#    With the Profile CRD (dashboard module) use upstream's test Profile; the profile controller
#    makes the rest. Without it, make the same three objects the controller makes.
if ! kubectl get namespace "$PROFILE" >/dev/null 2>&1; then
  if kubectl get crd profiles.kubeflow.org >/dev/null 2>&1; then
    kubectl apply -k "$UP/common/user-namespace/base" >/dev/null || fail "could not apply upstream test Profile"
  else
    kubectl create namespace "$PROFILE" >/dev/null || fail "could not create namespace $PROFILE"
    kubectl label namespace "$PROFILE" app.kubernetes.io/part-of=kubeflow-profile >/dev/null
    kubectl -n "$PROFILE" create serviceaccount default-editor >/dev/null
    kubectl -n "$PROFILE" create rolebinding default-editor --clusterrole=kubeflow-edit \
      --serviceaccount="$PROFILE:default-editor" >/dev/null
  fi
fi
for _ in $(seq 60); do kubectl -n "$PROFILE" get serviceaccount default-editor >/dev/null 2>&1 && break; sleep 5; done
kubectl -n "$PROFILE" get serviceaccount default-editor >/dev/null 2>&1 \
  && ok "profile namespace $PROFILE with default-editor" || fail "no default-editor ServiceAccount in $PROFILE"

# 2. The jupyterlab WorkspaceKind from the workspace-kinds module.
kubectl get workspacekind jupyterlab >/dev/null 2>&1 && ok "WorkspaceKind jupyterlab installed" \
  || fail "WorkspaceKind jupyterlab missing (is workspaces.kinds empty?)"

# 3. Start a Workspace and wait for Running (the #2 health mapping uses the same field).
trap 'kubectl delete -f "$FIXTURE" --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT
kubectl apply -f "$FIXTURE" >/dev/null
start=$(date +%s); state=""
while (( $(date +%s) - start < WS_TIMEOUT )); do
  state="$(kubectl -n "$PROFILE" get workspace test -o jsonpath='{.status.state}' 2>/dev/null || true)"
  [[ "$state" == Running || "$state" == Error ]] && break
  sleep 10
done
[[ "$state" == Running ]] && ok "Workspace test is Running after $(( $(date +%s) - start ))s" \
  || fail "Workspace test state '${state:-<none>}' after ${WS_TIMEOUT}s: $(kubectl -n "$PROFILE" get workspace test -o jsonpath='{.status.stateMessage}' 2>/dev/null)"

# 4. Upstream's API authorization test.
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
