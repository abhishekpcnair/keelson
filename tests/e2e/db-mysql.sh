#!/usr/bin/env bash
# Test-only external MySQL for MODULES=external-mysql (#39). run.sh calls it before the install.
#
# It runs upstream's own MySQL (applications/pipeline/upstream/third-party/mysql/base at the pinned
# tag: the same image and settings as bundled MySQL) in namespace e2e-db, outside the pipelines
# module, and makes the Secret kfp-db in kubeflow that the scenario's database.external.secretRef
# names. Upstream's MySQL has the user root with an empty password (MYSQL_ALLOW_EMPTY_PASSWORD),
# so the Secret holds no secret: test only.
#
# Usage: tests/e2e/db-mysql.sh          start the server and the Secret (before the install)
#        tests/e2e/db-mysql.sh check    after the install: bundled MySQL is gone, and KFP made its
#                                       databases on the external server
set -euo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NS=e2e-db
if [[ "${1:-}" == check ]]; then
  for o in deployment/mysql secret/mysql-secret service/mysql; do
    if kubectl -n kubeflow get "$o" >/dev/null 2>&1; then fail "bundled $o still exists in kubeflow"; fi
  done
  dbs="$(kubectl -n "$NS" exec deploy/mysql -- mysql -uroot -N -e 'SHOW DATABASES')" || fail "could not list databases on mysql.$NS"
  for db in mlpipeline cachedb kfp_metadata; do
    grep -qx "$db" <<<"$dbs" || fail "database $db is missing on mysql.$NS (found: $(tr '\n' ' ' <<<"$dbs"))"
  done
  log "external MySQL: bundled MySQL is gone; mlpipeline, cachedb and kfp_metadata are on mysql.$NS"
  exit 0
fi
UPSTREAM="$(upstream_dir)"
BASE="$UPSTREAM/applications/pipeline/upstream/third-party/mysql/base"
[[ -d "$BASE" ]] || fail "$BASE not found; run 'make upstream-cache'"

# Wrap upstream's base with a namespace override, in a temp dir (wrap, don't copy).
work="$(mktemp -d)"
on_exit "rm -rf '$work'"
cat >"$work/kustomization.yaml" <<KEOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: $NS
resources: ["$(realpath --relative-to="$work" "$BASE")"]   # kustomize rejects an absolute path
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
