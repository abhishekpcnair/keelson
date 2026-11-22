# Module registry

One YAML file per module, following the module contract in `docs/design/0001-architecture.md` §7.
Loaded by the engine (`templates/_engine.tpl`) with `.Files.Glob "modules/*.yaml"`.
Module files are data only. Put no template logic here.

Fields:
- `name`, `wave`, `defaultEnabled`, `dependsOn`
- `source.type` (`kustomize` only for now, see ADR 0002), `source.path`, and optional `source.platformPaths` (keyed by `platform`)
- `namespace`: the Application destination namespace
- `namespaces`: every namespace the path writes to, which builds the AppProject allowlist (check with `kubectl kustomize`)
- `translations`, `smokeTest`, `upstreamHelmChart`

User docs: `docs/modules/README.md`.
