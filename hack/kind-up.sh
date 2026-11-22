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

# Pins from the upstream test script at the pinned tag.
# The tag comes from upstream.manifestsRef in values.yaml (the same key the Makefile reads).
tag="${UPSTREAM_TAG:-$(awk '/^upstream:/{u=1; next} /^[^[:space:]#]/{u=0} u && $1=="manifestsRef:"{gsub(/"/,"",$2); print $2; exit}' "$ROOT/charts/keelson/values.yaml")}"
upstream_script="$ROOT/.cache/upstream/$tag/$UPSTREAM_SCRIPT_REL"
want_kind=""
if [[ -n "$tag" && -f "$upstream_script" ]]; then
  want_kind="$(sed -nE 's/^KIND_VERSION="(v[0-9.]+)".*/\1/p' "$upstream_script" | head -n1)"
  if [[ -z "${KIND_NODE_IMAGE:-}" ]]; then
    KIND_NODE_IMAGE="$(sed -nE 's/^KIND_NODE_IMAGE="\$\{KIND_NODE_IMAGE:-([^}]+)\}".*/\1/p' "$upstream_script" | head -n1)"
  fi
fi

# Older kind releases generate kubeadm configs that newer node images reject (kubeadm v1beta3 vs v1beta4).
# If the upstream cache is missing (for example, with a KIND_NODE_IMAGE override), there is no
# upstream KIND_VERSION to compare against, so this check is skipped.
if [[ -n "$want_kind" ]]; then
  have_kind="$(kind version | sed -nE 's/^kind (v[0-9]+\.[0-9]+\.[0-9]+).*/\1/p')"
  [[ -n "$have_kind" ]] || die "could not parse 'kind version' output; kind $want_kind or newer is required"
  if [[ "$(printf '%s\n' "$want_kind" "$have_kind" | sort -V | head -n1)" != "$want_kind" ]]; then
    die "kind $have_kind is older than upstream's $want_kind; upgrade kind and rerun"
  fi
fi

k() { kubectl --context "$CONTEXT" "$@"; }

# 2. Cluster.
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  log "Kind cluster '$CLUSTER_NAME' already exists; skipping create"
  k get --raw /readyz >/dev/null 2>&1 \
    || die "cluster '$CLUSTER_NAME' exists but its API server is unreachable (containers stopped?). Start it, or run 'make kind-down && make kind-up'."
  # Check that the existing cluster still matches what this script would create.
  want_k8s="$(sed -nE 's/^[^:]+:(v[0-9]+\.[0-9]+\.[0-9]+).*/\1/p' <<<"${KIND_NODE_IMAGE:-}")"
  have_k8s="$({ k version -o json 2>/dev/null || true; } | sed -nE 's/.*"gitVersion": *"(v[0-9]+\.[0-9]+\.[0-9]+)[^"]*".*/\1/p' | tail -n1)"
  if [[ -z "$want_k8s" ]]; then
    log "warning: expected node image unknown (no upstream cache); not checking the existing cluster's version"
  elif [[ "$have_k8s" != "$want_k8s" ]]; then
    log "warning: cluster runs Kubernetes ${have_k8s:-unknown}, but the node image $KIND_NODE_IMAGE is $want_k8s. Run 'make kind-down && make kind-up' to recreate it."
  fi
  # Capture first, so grep -q can't SIGPIPE kubectl under pipefail.
  # Right after a restart, /readyz can pass before the mirror pod is listed. Empty means "not known yet".
  apiserver_cmd="" tries=15 delay=2
  for (( try = 1; try <= tries; try++ )); do
    apiserver_cmd="$(k -n kube-system get pod -l component=kube-apiserver -o jsonpath='{.items[*].spec.containers[*].command}' 2>/dev/null || true)"
    if [[ -n "$apiserver_cmd" ]]; then break; fi
    if (( try == 1 )); then log "Waiting up to $(( tries * delay ))s for the kube-apiserver pod in '$CLUSTER_NAME' to be listed"; fi
    if (( try < tries )); then sleep "$delay"; fi
  done
  [[ -n "$apiserver_cmd" ]] \
    || die "could not read the kube-apiserver pod in cluster '$CLUSTER_NAME' after $(( tries * delay ))s (control plane still starting?). Wait and rerun, or run 'make kind-down && make kind-up'."
  # Match the whole quoted argument: kubeadm's default issuer, ...default.svc.cluster.local, shares the prefix.
  if [[ "$apiserver_cmd" != *'"--service-account-issuer=https://kubernetes.default.svc"'* ]]; then
    die "existing cluster '$CLUSTER_NAME' lacks the service-account-issuer patch (not created by this script?). Run 'make kind-down && make kind-up'."
  fi
else
  # 3. Node image, read from the pinned upstream test script.
  if [[ -z "${KIND_NODE_IMAGE:-}" ]]; then
    [[ -n "$tag" ]] || die "could not read upstream.manifestsRef from charts/keelson/values.yaml"
    [[ -f "$upstream_script" ]] || die "$upstream_script not found. Run 'make upstream-cache', or set KIND_NODE_IMAGE=kindest/node:<tag>@sha256:<digest>"
    die "no pinned KIND_NODE_IMAGE line found in $upstream_script; upstream may have changed the file. Set KIND_NODE_IMAGE=kindest/node:<tag>@sha256:<digest>"
  fi
  [[ "$KIND_NODE_IMAGE" == *@sha256:* ]] || die "KIND_NODE_IMAGE must be pinned by digest (tag@sha256:digest), got '$KIND_NODE_IMAGE'"
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
