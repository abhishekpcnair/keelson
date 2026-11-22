# Modules

A module is one upstream Kubeflow component. Each module becomes one ArgoCD `Application`.
Modules are defined in `charts/keelson/modules/<name>.yaml`.

## Turn a module on or off

Use the module name as the key:

```yaml
modules:
  kubeflow-roles:
    enabled: false
```

If you don't set a key, the module's `defaultEnabled` applies.

Rendering fails if you name a module that doesn't exist. It also fails if you turn off a module
that another enabled module needs (`dependsOn`):

```
module dex depends on istio, which is disabled
```

## Platform

Set `platform: kind` on Kind clusters. Some modules switch to a Kind-specific upstream overlay.
The default is `generic`.

## What every Application gets

- The pinned source: `upstream.manifestsRepo` at `upstream.manifestsRef`.
- A sync wave from the module file.
- Automated sync with prune and self-heal, `ServerSideApply`, `CreateNamespace`, and retries with backoff.
- The AppProject `argocd.project`. It allows only `upstream.manifestsRepo` plus `argocd.extraSourceRepos`,
  and only the namespaces that enabled modules write to.

## Turning a module off leaves its resources running

Applications have no `resources-finalizer.argocd.argoproj.io`. When you disable a module,
ArgoCD deletes the Application but keeps what it deployed. This is on purpose: deleting CRDs
or namespaces by accident would delete user data. To remove a module's resources, delete them
yourself.

## Override an Application spec (unsupported)

`advanced.modules.<name>.appSpecOverride` is deep-merged over the generated `spec`:

```yaml
advanced:
  modules:
    dex:
      appSpecOverride:
        syncPolicy:
          automated:
            prune: false
```

This is an escape hatch. We don't support it, and it may break on upgrade.

You can't override the fields that keep sources pinned and inside the AppProject.
Rendering fails if an override sets `project`, `sources`, `source.repoURL`,
`source.targetRevision` or `destination.server`.

## Add a module

1. Find the path in `.cache/upstream/<tag>` (`make upstream-cache`).
2. Add `charts/keelson/modules/<name>.yaml` with every field from the contract (design §7).
   List every namespace the path writes to in `namespaces`. Use `kubectl kustomize <path>` to check.
3. Add or update a golden scenario, a smoke test, and a docs page.

Core modules are described in [core.md](core.md).
