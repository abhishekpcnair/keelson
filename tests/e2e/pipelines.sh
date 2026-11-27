#!/usr/bin/env bash
# Smoke test for the pipelines module (issue #12), run by tests/e2e/run.sh after every
# Application is Synced and Healthy.
#
# Runs upstream's own Pipelines tests from .cache/upstream/<tag>/tests, unchanged
# (CLAUDE.md rule 1: wrap, don't copy), with the kfp versions upstream CI pins at the tag.
#
# Two things it sets up, because the kind-core install has neither:
#   - A profile namespace. It applies upstream's own example Profile (common/user-namespace/base),
#     as upstream CI does, when the namespace is missing. It keeps the Profile: workspaces.sh and
#     pss.sh run later on the same cluster and use the same namespace.
#   - The gateway on localhost:8080, which upstream's pipeline_v2_test.py uses.
#
# Checks:
#   1. A v2 pipeline runs to SUCCEEDED in the profile namespace.
#   2. A token from a namespace that is not a profile is rejected.
#   3. SeaweedFS namespace isolation holds (upstream swfs_namespace_isolation_test.sh).
set -euo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ "$GATEWAY_PORT" == 8080 ]] || fail "upstream's pipeline_v2_test.py uses localhost:8080; unset GATEWAY_PORT"

UPSTREAM="$(upstream_dir)"
KF_PROFILE=kubeflow-user-example-com   # the name in upstream's common/user-namespace/base
# Upstream .github/workflows/full_kubeflow_integration_test.yaml at 26.10.0. Check it at each upstream bump.
# The venv uses the runner's python3; kfp 2.18 supports it (upstream pins Python 3.12 only for the v1 SDK).
KFP_VERSION="2.18.0"
UNAUTH_NS="keelson-e2e-unauthorized"

[ -d "$UPSTREAM/tests" ] || fail "$UPSTREAM/tests not found; run 'make upstream-cache'"

port_forward_gateway
VENV="$(mktemp -d)"
cleanup() {
  local rc="$E2E_EXIT_RC"
  if [[ "$rc" != 0 ]]; then
    # Diagnostics for a failed run: is the backend reachable from the gateway (#12)?
    {
      echo "---- pipelines.sh failed (rc=$rc): kubeflow pods, endpoints, sidecars"
      kubectl -n kubeflow get pods -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[*].ready,CONTAINERS:.spec.containers[*].name' 2>&1 | grep -E 'NAME|ml-pipeline|metadata|seaweed|mysql' || true
      kubectl -n kubeflow get endpoints ml-pipeline-ui ml-pipeline 2>&1 || true
      kubectl -n kubeflow get virtualservice,destinationrule,peerauthentication,authorizationpolicy 2>&1 | head -30 || true
      kubectl -n kubeflow logs deploy/ml-pipeline-ui -c istio-proxy --tail=30 2>&1 || true
      kubectl -n istio-system logs -l app=istio-ingressgateway --tail=30 2>&1 | grep -i -E 'pipeline|503|UF|URX' || true
    } >&2
  fi
  rm -rf "$VENV"
  kubectl delete namespace "$UNAUTH_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
on_exit cleanup

# wait_for <seconds> <what> <command...>: retry the command until it succeeds.
wait_for() {
  local limit="$1" what="$2" deadline
  shift 2
  deadline=$((SECONDS + limit))
  until "$@" >/dev/null 2>&1; do
    (( SECONDS < deadline )) || fail "timed out after ${limit}s waiting for $what"
    sleep 3
  done
}

if kubectl get namespace "$KF_PROFILE" >/dev/null 2>&1; then
  log "namespace $KF_PROFILE already exists; using it"
else
  log "creating the example profile from upstream's common/user-namespace/base"
  kubectl apply -k "$UPSTREAM/common/user-namespace/base" >/dev/null
fi
wait_for 180 "ServiceAccount default-editor in $KF_PROFILE" \
  kubectl -n "$KF_PROFILE" get serviceaccount default-editor
log "0. the KFP profile controller made mlpipeline-minio-artifact in $KF_PROFILE"
wait_for 180 "Secret mlpipeline-minio-artifact in $KF_PROFILE (the KFP profile controller creates it)" \
  kubectl -n "$KF_PROFILE" get secret mlpipeline-minio-artifact
# No manual Pod Security label here (upstream's kubeflow_profile_install.sh adds one): the dashboard
# module's kubeflow-pss overlay sets it, and pss.sh checks that it does.

# A PR run installs with helm, so there are no sync waves: pipelines pods can start before istiod's
# injector is ready and then have no sidecar. Upstream's DestinationRules require mesh mTLS, so the
# gateway gets "TLS_error WRONG_VERSION_NUMBER" (503) from such a pod. A plain `helm install` by a user
# has the same race (docs/modules/pipelines.md, "Istio sidecar"). The root Application install
# (main, nightly) orders the waves, so there a pod without a sidecar is a failure, not a restart.
deploys_without_sidecar() {
  kubectl -n kubeflow get pods -o json | python3 "$(dirname "${BASH_SOURCE[0]}")/lib/no_sidecar.py"
}
restart_without_sidecar() {
  local deploys
  deploys="$(deploys_without_sidecar)"
  [[ -n "$deploys" ]] || return 0
  [[ -n "${E2E_INSTALL:-}" ]] || fail "E2E_INSTALL is not set (run.sh exports it; set helm or root-app when you run this script alone)"
  if [[ "$E2E_INSTALL" != helm ]]; then
    fail "Deployments in kubeflow have no istio-proxy sidecar although the sync waves order the install: $deploys"
  fi
  log "restarting Deployments with no istio-proxy sidecar (helm install, no wave order): $deploys"
  for d in $deploys; do kubectl -n kubeflow rollout restart "deployment/$d" >/dev/null; done
  for d in $deploys; do kubectl -n kubeflow rollout status "deployment/$d" --timeout=300s >/dev/null; done
  deploys="$(deploys_without_sidecar)"
  [[ -z "$deploys" ]] || fail "still no istio-proxy sidecar after the restart: $deploys"
}
restart_without_sidecar

python3 -m venv "$VENV"
"$VENV/bin/pip" install --quiet "kfp==$KFP_VERSION" "kfp-kubernetes==$KFP_VERSION"

log "1. v2 pipeline run in $KF_PROFILE"
TOKEN="$(kubectl -n "$KF_PROFILE" create token default-editor)"
"$VENV/bin/python" "$UPSTREAM/tests/pipeline_v2_test.py" run_pipeline "$TOKEN" "$KF_PROFILE"

log "2. unauthorized token is rejected"
kubectl create namespace "$UNAUTH_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$UNAUTH_NS" create serviceaccount test-unauthorized --dry-run=client -o yaml | kubectl apply -f - >/dev/null
UNAUTH_TOKEN="$(kubectl -n "$UNAUTH_NS" create token test-unauthorized)"
"$VENV/bin/python" "$UPSTREAM/tests/pipeline_v2_test.py" test_unauthorized_access "$UNAUTH_TOKEN" "$KF_PROFILE"

log "3. SeaweedFS namespace isolation"
# The upstream script makes its own profiles and port-forward, and uses paths relative to the upstream repo root.
(cd "$UPSTREAM" && PATH="$VENV/bin:$PATH" ./tests/swfs_namespace_isolation_test.sh)

log "pipelines: OK"
