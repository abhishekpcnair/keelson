#!/usr/bin/env bash
# Delete the local Kind cluster created by hack/kind-up.sh. Safe to rerun.
set -euo pipefail
CLUSTER_NAME="${CLUSTER_NAME:-keelson}"
command -v kind >/dev/null || { echo "error: missing 'kind' on PATH" >&2; exit 1; }
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  kind delete cluster --name "$CLUSTER_NAME"
else
  echo "==> Kind cluster '$CLUSTER_NAME' does not exist; nothing to delete"
fi
