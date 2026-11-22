# Module registry

One YAML file per module, following the module contract in `docs/design/0001-architecture.md` §7.
Loaded by the engine with `.Files.Glob "modules/*.yaml"`. This folder has no `.yaml` files until backlog issue #1 adds the engine.
