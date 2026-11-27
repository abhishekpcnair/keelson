# Module registry

One YAML file per module, following the module contract in `docs/design/0001-architecture.md` §7.
Loaded by the engine (`templates/_engine.tpl`) with `.Files.Glob "modules/*.yaml"`.
Module files are data only. Put no template logic here.

Fields:
- `name`, `wave`, `defaultEnabled`, `dependsOn`
- `source.type`: `kustomize` (ADR 0002) or `keelson` (ADR 0004)
  - `kustomize`: `source.path`, and optional `source.platformPaths` (keyed by `platform`)
  - `keelson`: `source.component` (renders `templates/components/<component>.yaml`) and `source.values` (the values keys copied into `helm.valuesObject`). If every one of those keys is empty, the module renders no Application. Optional `source.context`: more values keys (dotted paths allowed, for example `auth.serviceAccountIssuers`) copied into `helm.valuesObject`; they never make the module render an Application. Optional `source.namespacesFrom`: a values list whose items' `name`s are added to the AppProject destinations. Add the component name to the `component` enum in `values.schema.json`.
- `namespace`: the Application destination namespace
- `namespaces`: every namespace the path writes to, which builds the AppProject allowlist (checked by `make namespaces`)
- `translations`: names of translation helpers (`templates/_translate_<name>.tpl`). The engine calls
  `keelson.translate.<name>` for each and appends the returned patches to `spec.source.kustomize.patches`.
  Unknown names fail the render. Known: `domain`, `auth`, `workspaceKinds`. A helper can return `skip: true`; then the module renders no Application. A skipped module still counts as enabled for `dependsOn`.
- `smokeTest`, `upstreamHelmChart`
- `ignoreDifferences` (optional): ArgoCD `ignoreDifferences` entries for fields another controller owns, such as a cert-manager-injected `caBundle`. Each entry needs `kind` and a non-empty `jsonPointers`, `jqPathExpressions` or `managedFieldsManagers`. The engine adds `RespectIgnoreDifferences=true`, and overrides can't remove these entries. `make kustomize-check` checks that each entry names a resource in the built upstream overlay.

User docs: `docs/modules/README.md`.

Wave bands (see `docs/argocd.md`): `-100…-40` platform, `0` dashboard, `10` profiles, `20` apps, `30+` v0.2.
A module's `wave` must be strictly higher than the wave of every module in its `dependsOn`; the engine fails otherwise.
