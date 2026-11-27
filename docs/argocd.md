# ArgoCD setup for Keelson

Keelson renders ArgoCD Applications with sync waves. Two things make those waves actually order
the install: a health check for `Application` resources, and a parent ("root") Application.
Keelson never changes your `argocd-cm`. You apply the health checks yourself, once.

## Prerequisites

- ArgoCD with `resource.customizations.health.<group>_<kind>` keys in `argocd-cm`.
  Keelson tests with **ArgoCD v3.6.2**, the version `make kind-up` installs. Older versions are untested.

## Apply the health checks

```sh
kubectl -n argocd patch configmap argocd-cm --type merge \
  --patch-file hack/argocd/argocd-cm-health.yaml
```

This adds two checks:

| Resource | Healthy | Progressing | Suspended | Degraded |
|---|---|---|---|---|
| `argoproj.io/Application` | child app is Healthy | no health yet | child app is Suspended | child app is Degraded |
| `kubeflow.org/Workspace` | `state: Running` | `Pending`, `Terminating`, `Unknown`, or no state yet | `Paused` | `Error` (shows `stateMessage`) |

> **Warning:** the `Application` check applies to **every** app-of-apps on this ArgoCD, not only Keelson.
> Parent apps will wait for their child Applications to become Healthy. This is the behaviour ArgoCD
> had before v1.8 ([argo-cd#3781](https://github.com/argoproj/argo-cd/issues/3781)).

On Kind, `make kind-up` applies the file for you.

There is no check for `Profile`, `PodDefault`, `WorkspaceKind`, `Viewer` or `ScheduledWorkflow`.
Their status has no reliable health signal, so ArgoCD's default (Healthy once applied) is used.
`Profile` is tracked in [#33](https://github.com/abhishekpcnair/keelson/issues/33).

## Install with a root Application (recommended)

Sync waves on Applications only take effect when a parent Application syncs them.
Point one Application at the Keelson chart, at a pinned release:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: keelson
  namespace: argocd
spec:
  project: default                 # the keelson AppProject only allows upstream sources
  source:
    repoURL: https://github.com/abhishekpcnair/keelson
    path: charts/keelson
    targetRevision: v0.1.0-alpha.1 # example: a Keelson release tag; never a branch
    helm:
      valuesObject:
        platform: kind             # only on Kind; leave it out on other clusters (default: generic)
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
```

The first Keelson release is `v0.1.0-alpha.1` ([#63](https://github.com/abhishekpcnair/keelson/issues/63)). Use a release tag or a commit SHA for `targetRevision`.

With a plain `helm install`, ArgoCD creates every Application at once. They still converge,
because each Application retries with backoff, but nothing waits for the waves.

## Sync waves

The AppProject is at wave `-1000`. Modules follow these bands (design §6):

| Wave | Modules |
|---|---|
| -100 | cert-manager |
| -90 | cert-manager-kubeflow |
| -80 | istio-crds, istio-namespace, kubeflow-namespace |
| -70 | istio |
| -60 | oauth2-proxy, dex |
| -55 | keelson-tls (only with `tls.issuer: selfsigned` or `letsencrypt`) |
| -50 | kubeflow-roles, kubeflow-istio-resources |
| -40 | Kyverno policies (planned) |
| 0 | dashboard (planned) |
| 10 | profiles (planned) |
| 20 | pipelines, workspaces (planned) |
| 30+ | v0.2 modules |

A module's wave must be higher than the wave of every module in its `dependsOn`. Rendering fails otherwise:

```
module dex (wave -70) depends on istio (wave -70): its wave must be higher
```
