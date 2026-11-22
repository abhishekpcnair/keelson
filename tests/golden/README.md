# Golden scenarios

Each folder holds `values.yaml` (input) and `expected.yaml` (committed `helm template` output).
`make golden-check` fails when rendering differs. Regenerate with `make golden`, then **read the diff** before committing.

Scenarios: `kind-core`, `domain-only`, `domain-tls-existing`, `domain-tls-external`, `connectors-oidc`, `production-oidc`, `aks-entra-external`, `connectors-github`.
Planned: `byo-istio-certmanager`, `modules-minimal`.
