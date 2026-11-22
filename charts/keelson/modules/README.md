# Module registry

One YAML file per module, following the module contract in `docs/design/0001-architecture.md` §7.
Loaded by the engine (`templates/_engine.tpl`) with `.Files.Glob "modules/*.yaml"`.
Module files are data only. Put no template logic here.

Fields:
- `name`, `wave`, `defaultEnabled`, `dependsOn`
- `source.type` (`kustomize` only for now, see ADR 0002), `source.path`, and optional `source.platformPaths` (keyed by `platform`)
- `namespace`: the Application destination namespace
- `namespaces`: every namespace the path writes to, which builds the AppProject allowlist (checked by `make namespaces`)
- `translations`: names of translation helpers (`templates/_translate_<name>.tpl`). The engine calls
  `keelson.translate.<name>` for each and appends the returned patches to `spec.source.kustomize.patches`.
  Unknown names fail the render. Known: `domain`, `workspaceKinds`. A helper can return `skip: true`; then the module renders no Application.
- `smokeTest`, `upstreamHelmChart`

User docs: `docs/modules/README.md`.

Wave bands (see `docs/argocd.md`): `-100…-40` platform, `0` dashboard, `10` profiles, `20` apps, `30+` v0.2.
A module's `wave` must be strictly higher than the wave of every module in its `dependsOn`; the engine fails otherwise.
