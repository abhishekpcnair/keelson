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
  Unknown names fail the render. Known: `domain`.
- `smokeTest`, `upstreamHelmChart`
- `ignoreDifferences` (optional): ArgoCD `ignoreDifferences` entries for fields another controller owns, such as a cert-manager-injected `caBundle`. The engine adds `RespectIgnoreDifferences=true`, and overrides can't remove these entries.

User docs: `docs/modules/README.md`.
