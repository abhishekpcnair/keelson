# Support matrix

What Keelson is tested with. Anything not listed here is untested.

| Item | Supported | Where it comes from |
|---|---|---|
| Kubeflow | `26.10.0` (`appVersion` in `Chart.yaml`) | `upstream.manifestsRef` in `values.yaml` |
| Kubernetes | The version that upstream CI tests at that tag: Kind node image `v1.37.0` | `tests/install_KinD_create_KinD_cluster_install_kustomize.sh` in kubeflow/manifests, read by `hack/kind-up.sh` |
| ArgoCD | `v3.6.2` or newer | `ARGOCD_VERSION` in `hack/kind-up.sh` ([ADR 0003](adr/0003-kind-bootstrap-installs-argocd.md)) |
| Helm | `v4.x` (CI uses `v4.3.2`) | `.github/workflows/` |
| kind (for local runs) | `v0.33.0` or newer | `KIND_VERSION` in upstream's Kind script |

## Platforms

| Platform | Status |
|---|---|
| Kind | Tested in CI (`e2e` workflow). |
| AKS | Manual checklist in [`release-checklist.md`](release-checklist.md). **Not yet validated.** It is validated before `0.1.0`. |

## Policy

Keelson supports the current and the previous upstream Kubeflow release ([design §13](design/0001-architecture.md)).
For the alpha releases, only the current release (`26.10.0`) is supported.
