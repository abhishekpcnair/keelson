# Core modules

These modules install the shared dependencies of Kubeflow. All are on by default.
Paths are for `kubeflow/manifests` `26.10.0`.

| Module | Wave | Upstream path | Namespaces | Why |
|---|---|---|---|---|
| `cert-manager` | -100 | `common/cert-manager/base` | cert-manager, kube-system | Certificates for webhooks |
| `cert-manager-kubeflow` | -90 | `common/cert-manager/overlays/kubeflow` | cert-manager | The `kubeflow-self-signing-issuer` ClusterIssuer and network policies. Comes after the CRDs and webhook. |
| `istio-crds` | -80 | `common/istio/istio-crds/base` | istio-system (destination only; the CRDs are cluster-scoped) | Istio CRDs |
| `istio-namespace` | -80 | `common/istio/istio-namespace/base` | istio-system | Namespace and network policies |
| `kubeflow-namespace` | -80 | `common/kubeflow-namespace/base` | kubeflow, kubeflow-system | Kubeflow namespaces. Comes before `istio`, which writes `Sidecar`s into `kubeflow`. |
| `istio` | -70 | `common/istio/istio-install/overlays/oauth2-proxy` | istio-system, kube-system, kubeflow | Control plane and ingress gateway, with oauth2-proxy external auth |
| `oauth2-proxy` | -60 | `common/oauth2-proxy/overlays/m2m-dex-only` (`m2m-dex-and-kind` when `platform: kind`) | oauth2-proxy, istio-system | Login in front of the gateway |
| `dex` | -60 | `common/dex/overlays/oauth2-proxy` | auth | OIDC broker for oauth2-proxy |
| `kubeflow-roles` | -50 | `common/kubeflow-roles/base` | kubeflow (destination only; the ClusterRoles are cluster-scoped) | Aggregated Kubeflow ClusterRoles |
| `kubeflow-istio-resources` | -50 | `common/istio/kubeflow-istio-resources/base` | kubeflow | The `kubeflow-gateway` and related roles |

Notes:
- Sync waves order the Applications, but ArgoCD doesn't wait for an Application to be healthy
  unless you add a health check for `Application` resources (issue #2). Until then, retries
  with backoff cover the ordering.
- Dex currently uses the upstream static test user. Connectors come from values in issue #6.
- `tests/e2e/auth-redirect.sh` is the smoke test for `istio`, `oauth2-proxy` and `dex`. For the
  other 7 modules, Healthy is the check. See [tests/e2e/README.md](../../tests/e2e/README.md).
