# Golden scenarios

Each folder holds `values.yaml` (input) and `expected.yaml` (committed `helm template` output).
`make golden-check` fails when rendering differs. Regenerate with `make golden`, then **read the diff** before committing.

Planned scenarios: `kind-core`, `aks-entra-external`, `byo-istio-certmanager`, `modules-minimal`.
