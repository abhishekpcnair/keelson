# Dashboard module

The `dashboard` module installs the Kubeflow central dashboard and the pieces it needs.
It is on by default.

| | |
|---|---|
| Upstream path | `applications/dashboard/overlays/istio` (`kubeflow/manifests` `26.10.0`) |
| Wave | `0` |
| Namespace | `kubeflow` (plus cluster-scoped CRDs, RBAC and a webhook) |
| Depends on | cert-manager-kubeflow, istio, kubeflow-namespace, kubeflow-roles, kubeflow-istio-resources, oauth2-proxy |
| Images | `ghcr.io/kubeflow/dashboard/*:v2.0.1` (upstream; Keelson sets none) |

## What it installs

- **Central dashboard**: the Kubeflow UI, at `/` behind oauth2-proxy (`VirtualService dashboard`).
- **PodDefaults webhook**: injects `PodDefault` settings into pods in profile namespaces.
- **Profile controller** with **KFAM** (access management): turns `Profile` resources into namespaces.
  It uses upstream's `kubeflow-pss` overlay, which sets Pod Security labels on profile namespaces.

## Turn it off

```yaml
modules:
  dashboard:
    enabled: false
```

## Why the webhook `caBundle` is ignored

Upstream ships the PodDefaults `MutatingWebhookConfiguration` with `caBundle: ""`. cert-manager's
cainjector fills it in. Without help, ArgoCD's self-heal would reset it to `""`, and every pod in
every profile namespace would be rejected (the webhook has `failurePolicy: Fail`).

So the module declares `ignoreDifferences` for `.webhooks[].clientConfig.caBundle`, and the
Application gets `RespectIgnoreDifferences=true`. No upstream manifest is patched.
`appSpecOverride` can add more `ignoreDifferences`, but can't remove this one.

## Menu links

The dashboard uses upstream's menu. It links Workspaces, Katib, KServe Endpoints, Model Registry and
Pipelines. Some of these aren't installed yet (Katib, KServe and Model Registry are v0.2+), so those
links show an error page until their module exists. Changing the menu would mean copying upstream's
configuration, so Keelson keeps it as is for v0.1.

## Users and namespaces

A user who logs in has no namespace until a `Profile` exists for them. Keelson creates profiles from
`profiles` in values (#9). It doesn't use upstream's `common/user-namespace`.

## Smoke test

`tests/e2e/dashboard.py` logs in through Dex with upstream's test helper, then checks that:
- `/` and `/api/workgroup/env-info` work (the latter returns the logged-in user);
- the webhook `caBundle` survives a hard refresh and the Application stays `Synced`.
