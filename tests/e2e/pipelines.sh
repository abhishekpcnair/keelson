#!/usr/bin/env bash
# Smoke test for the pipelines module (issue #12).
#
# Runs upstream's own Pipelines tests from .cache/upstream/<tag>/tests, unchanged
# (CLAUDE.md rule 1: wrap, don't copy), with the kfp versions upstream CI pins at the tag.
#
# Assumes kubectl points at a Keelson install and the istio-ingressgateway is
# port-forwarded to localhost:8080, as upstream's tests (and tests/e2e/dashboard.py) expect.
#
# Checks:
#   1. A v2 pipeline runs to SUCCEEDED in the profile namespace.
#   2. A token from a namespace that is not a profile is rejected.
#   3. SeaweedFS namespace isolation holds (upstream swfs_namespace_isolation_test.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TAG="$(python3 -c "import yaml,sys;print(yaml.safe_load(open(sys.argv[1]))['upstream']['manifestsRef'])" "$ROOT/charts/keelson/values.yaml")"
UPSTREAM="$ROOT/.cache/upstream/$TAG"
KF_PROFILE="${KF_PROFILE:-kubeflow-user-example-com}"
KFP_VERSION="2.18.0"   # upstream .github/workflows/full_kubeflow_integration_test.yaml at 26.10.0
UNAUTH_NS="keelson-e2e-unauthorized"

[ -d "$UPSTREAM/tests" ] || { echo "$UPSTREAM/tests not found; run 'make upstream-cache'"; exit 1; }
kubectl get namespace "$KF_PROFILE" >/dev/null

VENV="$(mktemp -d)"
cleanup() {
  rm -rf "$VENV"
  kubectl delete namespace "$UNAUTH_NS" --ignore-not-found --wait=false >/dev/null
}
trap cleanup EXIT
python3 -m venv "$VENV"
"$VENV/bin/pip" install --quiet "kfp==$KFP_VERSION" "kfp-kubernetes==$KFP_VERSION"

echo "== 1. v2 pipeline run in $KF_PROFILE"
TOKEN="$(kubectl -n "$KF_PROFILE" create token default-editor)"
"$VENV/bin/python" "$UPSTREAM/tests/pipeline_v2_test.py" run_pipeline "$TOKEN" "$KF_PROFILE"

echo "== 2. unauthorized token is rejected"
kubectl create namespace "$UNAUTH_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$UNAUTH_NS" create serviceaccount test-unauthorized --dry-run=client -o yaml | kubectl apply -f - >/dev/null
UNAUTH_TOKEN="$(kubectl -n "$UNAUTH_NS" create token test-unauthorized)"
"$VENV/bin/python" "$UPSTREAM/tests/pipeline_v2_test.py" test_unauthorized_access "$UNAUTH_TOKEN" "$KF_PROFILE"

echo "== 3. SeaweedFS namespace isolation"
# The upstream script uses paths relative to the upstream repo root.
(cd "$UPSTREAM" && PATH="$VENV/bin:$PATH" ./tests/swfs_namespace_isolation_test.sh)

echo "pipelines smoke test: OK"
