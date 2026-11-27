#!/usr/bin/env bash
# Test-only external MySQL for MODULES=external-mysql (#39). run.sh calls it before the install.
#
# It runs upstream's own MySQL (applications/pipeline/upstream/third-party/mysql/base at the pinned
# tag: the same image and settings as bundled MySQL) in namespace e2e-db, outside the pipelines
# module, and makes the Secret kfp-db in kubeflow that the scenario's database.external.secretRef
# names. Upstream's MySQL has the user root with an empty password (MYSQL_ALLOW_EMPTY_PASSWORD),
# so the Secret holds no secret: test only.
set -euo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UPSTREAM="$(upstream_dir)"
NS=e2e-db
BASE="$UPSTREAM/applications/pipeline/upstream/third-party/mysql/base"
[[ -d "$BASE" ]] || fail "$BASE not found; run 'make upstream-cache'"

# Wrap upstream's base with a namespace override, in a temp dir (wrap, don't copy).
work="$(mktemp -d)"
on_exit "rm -rf '$work'"
cat >"$work/kustomization.yaml" <<KEOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: $NS
resources: ["$BASE"]
KEOF
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -k "$work" >/dev/null || fail "could not apply upstream MySQL into $NS"
kubectl -n "$NS" rollout status deployment/mysql --timeout=300s >/dev/null || fail "MySQL in $NS did not roll out"
log "MySQL from upstream's third-party/mysql/base is running in $NS"

# The Secret lives in kubeflow. The kubeflow-namespace module adopts the namespace later.
kubectl create namespace kubeflow --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n kubeflow create secret generic kfp-db --from-literal=username=root --from-literal=password= \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
log "Secret kubeflow/kfp-db points at root on mysql.$NS"
