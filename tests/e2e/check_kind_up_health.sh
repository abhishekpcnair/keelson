#!/usr/bin/env bash
# Check that `make kind-up` applied hack/argocd/argocd-cm-health.yaml (#70):
# every resource.customizations.health.* key is in argocd-cm, and the field manager
# keelson-kind-up-health owns it (so a rerun of the ArgoCD install.yaml apply can't drop it).
# Needs kubectl on the kind-keelson context and jq.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FILE="$ROOT/hack/argocd/argocd-cm-health.yaml"
NS="${KEELSON_ARGOCD_NAMESPACE:-argocd}"
MANAGER="keelson-kind-up-health"

# The data keys, read from the file, so a new health check needs no change here.
keys=()
while IFS= read -r k; do keys+=("$k"); done < <(sed -nE 's/^  (resource\.customizations\.health\.[^:]+):.*/\1/p' "$FILE")
(( ${#keys[@]} > 0 )) || { echo "FAIL no resource.customizations.health.* keys in $FILE"; exit 1; }

cm="$(kubectl -n "$NS" get configmap argocd-cm -o json --show-managed-fields)"
fail=0
for k in "${keys[@]}"; do
  if ! jq -e --arg k "$k" '.data[$k] // empty | length > 0' <<<"$cm" >/dev/null; then
    echo "FAIL argocd-cm has no data key $k"; fail=1; continue
  fi
  owners="$(jq -r --arg k "$k" '[.metadata.managedFields[] | select(.fieldsV1["f:data"]["f:" + $k] != null) | .manager] | join(",")' <<<"$cm")"
  if [[ ",$owners," == *",$MANAGER,"* ]]; then
    echo "ok   $k (managers: $owners)"
  else
    echo "FAIL $k is not owned by $MANAGER (managers: ${owners:-<none>})"; fail=1
  fi
done
echo "check_kind_up_health: ${#keys[@]} key(s), $([[ $fail == 0 ]] && echo 'all passed' || echo 'FAILURES')"
exit $fail
