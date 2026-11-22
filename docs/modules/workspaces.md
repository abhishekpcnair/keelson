# Workspaces modules

Two modules install Kubeflow Workspaces (Notebooks v2). Both are on by default.

| Module | Wave | Upstream path (`26.10.0`) | What it installs |
|---|---|---|---|
| `workspaces` | 20 | `applications/workspaces/overlays/istio` | Controller, backend and frontend in `kubeflow-workspaces`. CRDs `Workspace` and `WorkspaceKind`. A validating webhook. VirtualServices on `kubeflow-gateway`. |
| `workspace-kinds` | 25 | `applications/workspaces/upstream/controller/samples` | The WorkspaceKinds you select in `workspaces.kinds`. |

Images are upstream only: `ghcr.io/kubeflow/notebooks/workspaces-*:v2.0.0` and `ghcr.io/kubeflow/kubeflow/notebook-servers/*`.

## Choose WorkspaceKinds

A user needs a WorkspaceKind to start a workspace. Upstream installs none. Keelson installs `jupyterlab` by default.

```yaml
workspaces:
  kinds: [jupyterlab, codeserver]   # any of: jupyterlab, codeserver, rstudio
```

- `kinds: []` installs no kinds and renders no `workspace-kinds` Application. Use this to bring your own kinds.
- `kinds: null` is the same as `[]`. You get no warning.
- If you remove a kind from `kinds`, ArgoCD prunes that WorkspaceKind. Delete or move the Workspaces that use it first.
- The samples path also has two PVCs, a Secret, a ConfigMap and a sample Workspace. Keelson deletes them with inline patches. They are not part of an install.
- `make kustomize-check` fails if upstream adds a new object to that path.

## Turn it off

```yaml
modules:
  workspaces:
    enabled: false
  workspace-kinds:
    enabled: false
```

`workspace-kinds` depends on `workspaces`. If you disable only `workspaces`, the render fails.

## Dashboard menu

The central dashboard menu links to `/workspaces/`. The link works when both the `dashboard` module ([#7](https://github.com/abhishekpcnair/keelson/issues/7)) and `workspaces` are on.

## Aggregated ClusterRoles

`kubeflow-workspaces-admin`, `-edit` and `-view` ship with `aggregationRule` and `rules: []`. Kubernetes fills `rules` at runtime. Without help, the `workspaces` Application stays `OutOfSync` for ever. The module ignores `/rules` on these three roles. It lists them by name, so drift on the other roles still shows.

## Webhook CA

The validating webhook has no `caBundle` field in the upstream manifest. cert-manager injects it. ArgoCD does not own the field, so the module needs no `ignoreDifferences` for the webhook. The smoke test checks this after a forced sync.

## Notebooks v1

Keelson does not offer notebooks-v1. Upstream removes it in Kubeflow 27.03. See design §18, Q5.

## Smoke test

`tests/e2e/workspaces.sh`:
1. Make sure the `kubeflow-user-example-com` namespace has a `default-editor` ServiceAccount bound to `kubeflow-edit`.
   - With the Profile CRD (dashboard module), it applies upstream's `common/user-namespace/base`.
   - Without it, it makes the namespace, the ServiceAccount and the RoleBinding, as the profile controller does. Profiles ([#9](https://github.com/abhishekpcnair/keelson/issues/9)) replace this.
2. Start upstream's test Workspace on `jupyterlab`. Wait for `Running`.
3. Run upstream's `tests/workspaces_test.sh` (200 for `default-editor`, 403 otherwise).
4. Force a sync of `workspaces`. Check the webhook CA and `Synced`.
