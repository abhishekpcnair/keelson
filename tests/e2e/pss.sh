#!/usr/bin/env bash
# Smoke test for profile namespace Pod Security and labels (issue #11).
#
# Pod Security comes from upstream: the dashboard module's kubeflow-pss overlay labels
# every profile namespace pod-security.kubernetes.io/enforce=baseline, and Kubernetes
# Pod Security Admission enforces it. Keelson adds no policy; this test proves the result.
#
# CI runs it as a step after `make e2e MODULES=core`, on the same cluster. It makes upstream's test
# Profile when the namespace is missing (the same one tests/e2e/workspaces.sh uses), then waits for
# the profile controller to label it.
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
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TAG="$(awk '/^upstream:/{u=1; next} /^[^[:space:]#]/{u=0} u && $1=="manifestsRef:"{gsub(/"/,"",$2); print $2; exit}' "$ROOT/charts/keelson/values.yaml")"
UP="$ROOT/.cache/upstream/$TAG"
IMAGE="busybox:1.37"   # never pulled: every pod below is a server-side dry run

label() { kubectl get namespace "$NS" -o jsonpath="{.metadata.labels['${1//./\\.}']}"; }
fail() { echo "FAIL $*"; exit 1; }

echo "== 0. profile namespace $NS"
if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
  [ "$NS" = kubeflow-user-example-com ] || fail "namespace $NS does not exist"
  kubectl apply -k "$UP/common/user-namespace/base" >/dev/null || fail "could not apply upstream test Profile from $UP"
fi
# The profile controller sets the labels after it makes the namespace. Wait up to 300s for all of them.
for _ in $(seq 60); do
  ready=1
  [ "$(label pod-security.kubernetes.io/enforce)" = baseline ] || ready=0
  for kv in "${EXPECT[@]}"; do [ "$(label "${kv%%=*}")" = "${kv#*=}" ] || ready=0; done
  [ "$ready" = 1 ] && break
  sleep 5
done

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
