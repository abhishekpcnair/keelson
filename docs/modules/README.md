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

## Fields other controllers own

Some modules tell ArgoCD to ignore fields that a controller writes at runtime, so the
Application stays Synced. For example, `istio` ignores the `caBundle` and `failurePolicy`
that istiod sets on its validating webhook. Aggregated ClusterRoles such as `kubeflow-admin`
ignore `.rules`, which the RBAC controller fills in.

Each `ignoreDifferences` entry, in a module file or in `appSpecOverride`, must have a `kind` and name
at least one field: `jsonPointers`, `jqPathExpressions` or `managedFieldsManagers`. Rendering fails otherwise.

The `istio` HPAs need a metrics-server. Without one, the `istio` Application shows Degraded.
`make kind-up` installs one; managed clusters such as AKS already have one.

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

`syncPolicy.syncOptions` in an override merge into the engine defaults by key (the text before `=`).
An entry with the same key replaces the default. A new key is added at the end. Each entry must be `Key=Value`.

```yaml
syncOptions: [CreateNamespace=false, PruneLast=true]
# result: [ServerSideApply=true, CreateNamespace=false, PruneLast=true]
```

You can't remove a default option. Set the opposite value instead, for example `CreateNamespace=false`.
`RespectIgnoreDifferences=true` stays on for modules with `ignoreDifferences`, from the module file or from your override.

The override is an allow-list, so sources stay pinned and inside the AppProject:
- At the top level you may set only `syncPolicy`, `ignoreDifferences`, `info`,
  `revisionHistoryLimit` and `source`.
- Inside `source` you may set only `path` and `kustomize`.
- Inside `source.kustomize` you may set only `patches`, `commonLabels`, `commonAnnotations`,
  `namePrefix`, `nameSuffix` and `replicas`. Each patch takes `patch` (an inline string),
  `target` and `options`. Your patches are added after the patches Keelson generates from
  `domain` and `tls`; they don't replace them.
- A patch may not change an image, in YAML, JSON or JSON6902 form (no forked images).
- Allowed keys may not be `null`. For example, `syncPolicy: null` would turn off automated sync.

Anything else fails at render time. That includes newer ArgoCD fields such as `sourceHydrator`,
and Kustomize fields that load remote content, such as `components`.
`project`, `source.repoURL`, `source.targetRevision` and `destination.server` always come from values.
The engine checks every override, also the override of a disabled module.

## Smoke tests

Each module file has a `smokeTest` field. It is either a script path or `none` with a comment that gives the reason:

```yaml
smokeTest: tests/e2e/auth-redirect.sh
```

`make e2e` runs the smoke tests of the enabled modules after every Application is Healthy. Scripts can use the helpers in `tests/e2e/lib.sh`. See [tests/e2e/README.md](../../tests/e2e/README.md).

## Add a module

1. Find the path in `.cache/upstream/<tag>` (`make upstream-cache`).
2. Add `charts/keelson/modules/<name>.yaml` with every field from the contract (design §7).
   List every namespace the path writes to in `namespaces`. Use `make namespaces` to check.
3. Add or update a golden scenario, a smoke test, and a docs page.

Core modules are described in [core.md](core.md).
