#!/usr/bin/env bash
# E2E: install ArgoCD on the current kube context, install Keelson, wait for Healthy, run smoke tests.
# Implemented in backlog issue #4. Until then this script only checks the prerequisites.
set -euo pipefail
MODULES="${1:-core}"
for bin in kubectl helm; do command -v "$bin" >/dev/null || { echo "missing $bin"; exit 1; }; done
kubectl cluster-info >/dev/null
echo "e2e (${MODULES}): not implemented yet; see docs/backlog.md issue #4"
