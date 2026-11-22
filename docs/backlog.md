# Seed backlog (create these as GitHub issues, in order)

Each issue goes through the factory: `/triage` → `/plan` → approve → `/implement` → `/review`.

| # | Title | Size | Notes |
|---|---|---|---|
| 1 | Engine: module registry → AppProject + Applications | M | Loop over `modules/*.yaml` (§7), shared `defaultAppSpec`, AppProject allowlist, first golden scenario `kind-core` with cert-manager, Istio, oauth2-proxy, Dex, namespace and roles |
| 2 | Sync waves + ArgoCD health checks for Kubeflow CRs | S | Document the resource customisations users add to argocd-cm |
| 3 | Bootstrap script: Kind cluster + ArgoCD | S | Decide open question Q2 |
| 4 | E2E harness: install, wait for Healthy, Dex login smoke test | M | Fill in `tests/e2e/run.sh` |
| 5 | Translation: `domain` + TLS issuer | M | Gateway hosts, oauth2-proxy redirect, Dex issuer |
| 6 | Translation: Dex connectors (Entra ID, OIDC, GitHub, static-for-Kind) | M | `secretRef` only; schema forbids static users in production |
| 7 | Dashboard module (central dashboard, profile controller, PodDefaults) | S | `applications/dashboard/overlays/istio` |
| 8 | Profiles as code + group → profile RoleBindings | M | Keelson-generated `keelson-profiles` Application |
| 9 | Kyverno policies: secret copy, PSS baseline, namespace labels | M | Tested on two Kyverno minor versions |
| 10 | Pipelines module + bundled/external storage and database | L | Split if over 400 lines |
| 11 | Workspaces module (Notebooks v2) | M | Decide open question Q5 for notebooks-v1 |
| 12 | Docs: Kind quickstart, AKS guide, values reference generated from the schema | M | |
| 13 | Release v0.1.0-alpha | S | `/release 0.1.0-alpha.1` |
