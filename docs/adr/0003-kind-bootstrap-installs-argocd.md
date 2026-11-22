# ADR 0003: The Kind bootstrap script installs ArgoCD; everywhere else is bring-your-own

- Status: accepted
- Date: 2026-11-22

## Context
Keelson renders ArgoCD Applications, so a cluster needs ArgoCD before Keelson can do anything. Open question Q2 asked whether v0.1 should ship a script that installs ArgoCD, or only document "bring your own ArgoCD". Contributors and CI need a cluster they can create in one command. Production clusters usually already run ArgoCD, with its own lifecycle and settings.

## Decision
`hack/kind-up.sh` (`make kind-up`) creates a Kind cluster and installs ArgoCD from the official `manifests/install.yaml` at a pinned tag. It is for Kind, dev and CI only. For every other cluster, the documented path is bring-your-own ArgoCD.

The cluster has the same shape as upstream Kubeflow CI at the pinned tag: one control-plane, two workers, and the kubeadm `service-account-issuer` patch. The node image is read from upstream's test script in `.cache/upstream/<tag>/`, not copied.

Alternatives we rejected:
- **Bring-your-own only.** Every contributor and CI job would repeat the same setup by hand, and drift from upstream's cluster shape.
- **A chart dependency on the `argo-cd` Helm chart.** Keelson would then own ArgoCD's lifecycle on production clusters, and it would conflict with an existing ArgoCD. That is out of scope.

## Consequences (including the effect on upstream bumps)
- This does not conflict with the "installing without ArgoCD" non-goal. The chart still never installs ArgoCD.
- The ArgoCD pin lives in `hack/kind-up.sh` (`ARGOCD_VERSION`), with the sha256 of its `install.yaml` (`ARGOCD_INSTALL_SHA256`) next to it. Bump both together. Any CI `argocd` CLI must use the same version.
- The 3-node shape plus a full install needs about 16 GB of RAM. We keep upstream parity over a smaller footprint.
- Upstream can move or reformat its Kind test script. The script then fails with an override hint (`KIND_NODE_IMAGE`), and `/upstream-bump` checks the file on every bump.
- kind-up also installs a pinned metrics-server (`METRICS_SERVER_VERSION`), for dev and CI only. The istio HPAs need it, or ArgoCD reports the `istio` Application Degraded. Real clusters (AKS) already have one.
