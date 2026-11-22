# Golden scenarios

Each folder holds `values.yaml` (input) and `expected.yaml` (committed `helm template` output).
`make golden-check` fails when rendering differs. Regenerate with `make golden`, then **read the diff** before committing.

e2e installs a scenario's `values.yaml` as-is (`kind-core` for `make e2e MODULES=core`, see `tests/e2e/README.md`). Changing a scenario's values also changes what e2e installs.

Planned scenarios: `kind-core`, `aks-entra-external`, `byo-istio-certmanager`, `modules-minimal`.
