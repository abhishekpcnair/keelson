#!/usr/bin/env bash
# Smoke test for profile namespace Pod Security and labels (issue #11).
#
# Pod Security comes from upstream: the dashboard module's kubeflow-pss overlay labels
# every profile namespace pod-security.kubernetes.io/enforce=baseline, and Kubernetes
# Pod Security Admission enforces it. Keelson adds no policy; this test proves the result.
#
# Usage: tests/e2e/pss.sh [profile-namespace] [label=value ...]
#   Defaults: kubeflow-user-example-com, and keelson.io/e2e=true (the kind-core scenario).
# Checks:
#   1. The namespace has pod-security.kubernetes.io/enforce=baseline.
#   2. A privileged pod is rejected (server-side dry run).
#   3. A plain pod is admitted (server-side dry run).
#   4. Each expected profileNamespaceLabels label is on the namespace.
set -euo pipefail

NS="${1:-kubeflow-user-example-com}"
shift || true
EXPECT=("$@")
[ ${#EXPECT[@]} -gt 0 ] || EXPECT=("keelson.io/e2e=true")
IMAGE="busybox:1.37"   # never pulled: every pod below is a server-side dry run

label() { kubectl get namespace "$NS" -o jsonpath="{.metadata.labels['${1//./\\.}']}"; }
fail() { echo "FAIL $*"; exit 1; }

echo "== 1. Pod Security label on $NS"
[ "$(label pod-security.kubernetes.io/enforce)" = baseline ] || fail "enforce label is '$(label pod-security.kubernetes.io/enforce)', want baseline"

echo "== 2. privileged pod is rejected"
if out=$(kubectl -n "$NS" run pss-privileged --image="$IMAGE" --restart=Never --dry-run=server \
    --overrides='{"spec":{"containers":[{"name":"pss-privileged","image":"'"$IMAGE"'","securityContext":{"privileged":true}}]}}' 2>&1); then
  fail "privileged pod was admitted: $out"
fi
grep -q "violates PodSecurity" <<<"$out" || fail "rejected, but not by Pod Security: $out"

echo "== 3. plain pod is admitted"
kubectl -n "$NS" run pss-plain --image="$IMAGE" --restart=Never --dry-run=server >/dev/null

echo "== 4. profileNamespaceLabels"
for kv in "${EXPECT[@]}"; do
  [ "$(label "${kv%%=*}")" = "${kv#*=}" ] || fail "label ${kv%%=*} is '$(label "${kv%%=*}")', want '${kv#*=}'"
done

echo "pss smoke test: OK"
