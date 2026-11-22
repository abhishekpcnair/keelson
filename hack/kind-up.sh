#!/usr/bin/env bash
# Create a local Kind cluster that matches upstream Kubeflow's CI shape, then
# install a pinned ArgoCD. For Kind, dev and CI only (ADR 0003). Safe to rerun.
#
# The Kind cluster config (1 control-plane, 2 workers, kubeadm
# service-account-issuer patch) is adapted from kubeflow/manifests
# tests/install_KinD_create_KinD_cluster_install_kustomize.sh (Apache-2.0).
# See NOTICE. The node image is read from that file at the pinned tag, not copied.
#
# Environment:
#   UPSTREAM_TAG     kubeflow/manifests tag (default: upstream.manifestsRef in values.yaml)
#   KIND_NODE_IMAGE  override the node image (tag@sha256:digest)
#   KIND_EXPERIMENTAL_PROVIDER  set to "podman" to use Podman instead of Docker
#   CLUSTER_NAME     default: keelson
set -euo pipefail

ARGOCD_VERSION="v3.6.2"
CLUSTER_NAME="${CLUSTER_NAME:-keelson}"
CONTEXT="kind-${CLUSTER_NAME}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_SCRIPT_REL="tests/install_KinD_create_KinD_cluster_install_kustomize.sh"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# 1. Prerequisites. We never download binaries or use sudo.
provider="${KIND_EXPERIMENTAL_PROVIDER:-docker}"
for bin in kind kubectl "$provider"; do
  command -v "$bin" >/dev/null || die "missing '$bin' on PATH; install it and rerun"
done
"$provider" info >/dev/null 2>&1 || die "'$provider' is installed but not running"

if [[ "$(uname -s)" == "Linux" ]]; then
  # Values from the upstream README prerequisites.
  inst="$(sysctl -n fs.inotify.max_user_instances 2>/dev/null || echo 0)"
  watches="$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo 0)"
  if (( inst < 2280 || watches < 1255360 )); then
    log "warning: inotify limits are low (instances=$inst, watches=$watches). Upstream recommends:"
    log "  sudo sysctl fs.inotify.max_user_instances=2280"
    log "  sudo sysctl fs.inotify.max_user_watches=1255360"
  fi
fi

# 2. Cluster.
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  log "Kind cluster '$CLUSTER_NAME' already exists; skipping create"
else
  # 3. Node image, read from the pinned upstream test script.
  if [[ -z "${KIND_NODE_IMAGE:-}" ]]; then
    tag="${UPSTREAM_TAG:-$(sed -nE 's/^[[:space:]]*manifestsRef:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/p' "$ROOT/charts/keelson/values.yaml" | head -n1)}"
    [[ -n "$tag" ]] || die "could not read upstream.manifestsRef from charts/keelson/values.yaml"
    upstream_script="$ROOT/.cache/upstream/$tag/$UPSTREAM_SCRIPT_REL"
    [[ -f "$upstream_script" ]] || die "$upstream_script not found. Run 'make upstream-cache', or set KIND_NODE_IMAGE=kindest/node:<tag>@sha256:<digest>"
    KIND_NODE_IMAGE="$(sed -nE 's/^KIND_NODE_IMAGE="\$\{KIND_NODE_IMAGE:-([^}]+)\}".*/\1/p' "$upstream_script" | head -n1)"
    [[ "$KIND_NODE_IMAGE" == *@sha256:* ]] || die "no pinned KIND_NODE_IMAGE line found in $upstream_script; upstream may have changed the file. Set KIND_NODE_IMAGE=kindest/node:<tag>@sha256:<digest>"
  fi
  log "Creating Kind cluster '$CLUSTER_NAME' with $KIND_NODE_IMAGE"
  kind create cluster --name "$CLUSTER_NAME" --wait 120s --config - <<EOF
apiVersion: kind.x-k8s.io/v1alpha4
kind: Cluster
# Projected service account tokens, needed by the m2m-dex-and-kind oauth2-proxy overlay.
kubeadmConfigPatches:
  - |
    apiVersion: kubeadm.k8s.io/v1beta4
    kind: ClusterConfiguration
    metadata:
      name: config
    apiServer:
      extraArgs:
        - name: service-account-issuer
          value: https://kubernetes.default.svc
        - name: service-account-signing-key-file
          value: /etc/kubernetes/pki/sa.key
nodes:
- role: control-plane
  image: ${KIND_NODE_IMAGE}
- role: worker
  image: ${KIND_NODE_IMAGE}
- role: worker
  image: ${KIND_NODE_IMAGE}
EOF
fi

k() { kubectl --context "$CONTEXT" "$@"; }

# 4. ArgoCD, pinned. Server-side apply because the CRDs exceed the client-side annotation limit.
log "Installing ArgoCD $ARGOCD_VERSION"
k create namespace argocd --dry-run=client -o yaml | k apply -f - >/dev/null
k apply --server-side --force-conflicts -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" >/dev/null
for r in $(k -n argocd get deployment,statefulset -o name); do
  k -n argocd rollout status "$r" --timeout=600s
done

# 5. Health customisations from #2, if present.
health="$ROOT/hack/argocd/argocd-cm-health.yaml"
if [[ -f "$health" ]]; then
  log "Applying $health"
  k apply --server-side --force-conflicts -n argocd -f "$health"
else
  log "No hack/argocd/argocd-cm-health.yaml yet (issue #2); skipping health customisations"
fi

# 6. Next steps.
cat <<EOF

Kind cluster '$CLUSTER_NAME' is ready with ArgoCD $ARGOCD_VERSION.
  kubectl context:  $CONTEXT
  install Keelson:  helm install keelson charts/keelson --kube-context $CONTEXT
  e2e smoke tests:  make e2e MODULES=core
  delete cluster:   make kind-down
EOF
