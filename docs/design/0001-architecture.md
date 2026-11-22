# Design 0001: Keelson architecture

| | |
|---|---|
| Status | Draft, open for review |
| Author | Abhishek |
| Created | 2026-11-22 |
| Target upstream | Kubeflow Community Distribution **26.10.0** (`kubeflow/manifests` tag `26.10.0`) |
| Working name | `keelson` (rename in one place: see `PROJECT_NAME` in the `Makefile`) |

---

## 1. Summary

Keelson is a GitOps-first distribution of Kubeflow. You install **one Helm chart** with **one `values.yaml`**. The chart renders **ArgoCD Applications**, and those Applications deploy the **official upstream Kubeflow manifests** plus a small, reviewed set of patches. Keelson ships no copied templates and no forked images.

The main promise is **staying current**. Each new Kubeflow release produces an automated pull request with a rendered diff and an end-to-end test on Kind. The target is to ship a supported Keelson release within four weeks of each upstream release.

## 2. Background

- **deployKF** (Apache-2.0) set the bar for user experience: one values file, ArgoCD-native delivery, bring-your-own dependencies, OIDC with any provider, and profiles defined as code. Its last release was v0.1.5 in May 2024, and it never got past Kubeflow 1.8. It re-templated every upstream component into gomplate (682 generator files) and kept forked images. That made each upgrade a manual port, and that is most likely why it stalled.
- **treebeardtech/kubeflow-bootstrap** (Apache-2.0, stalled since April 2024) showed the "Helm chart that emits ArgoCD Applications" pattern, with phased sync waves and Terraform/AKS examples.
- **TheCodingSheikh/helm-charts `kubeflow`** (Apache-2.0, maintained, on Kubeflow 1.11) has a minimal engine: it loops over a map of upstream paths and renders one Application per entry. It has no opinionated configuration layer.
- **Upstream 26.10** now includes *draft* Helm charts for most components, generated from Kustomize. Kustomize is still the source of truth (`applications/*/helm`, `common/*/helm`).

Keelson combines the engine from the third project, the phasing from the second and the user experience from the first. It is designed to move onto upstream Helm charts as they mature.

## 3. Goals and non-goals

### Goals (v0.1)
1. One `helm install` plus ArgoCD gives a working multi-user Kubeflow on Kind and on AKS.
2. The config surface is one `values.yaml`, validated by `values.schema.json`.
3. Identity uses Dex and oauth2-proxy, with connectors for Entra ID, generic OIDC, GitHub and static test users. Group claims map to profiles.
4. Profiles, and who belongs to them, are declared in values.
5. Kyverno is optional. It handles secret distribution and a Pod Security baseline, and is tested on two current minor versions.
6. Core modules: dashboard and profiles, Pipelines, Workspaces (Notebooks v2), plus their dependencies (cert-manager, Istio, Knative only if needed).
7. Storage and database can be bundled (upstream defaults) or bring-your-own (S3-compatible storage, MySQL). MySQL in v0.1. PostgreSQL when upstream ships a cert-manager overlay (#40).
8. Every upstream release triggers an automated bump PR with a rendered diff and an e2e run.

### Non-goals (v0.1)
- KServe, Katib, Trainer, Spark, Hub/Model Registry (v0.2+)
- MLflow, Airflow (v0.3+ / v0.4+, add-on modules)
- Installing without ArgoCD
- Multi-cluster, ARM64
- Any forked component image

## 4. Design principles

These are binding rules, and the factory enforces them (see `docs/development-factory.md`).

1. **Wrap, don't copy.** Every workload comes from an upstream source (a `kubeflow/manifests` path at a pinned tag, or an upstream Helm chart at a pinned version). Keelson contributes only Application objects, Kustomize patches and Helm values.
2. **Upstream is the source of truth.** If a change can't be expressed as a small patch, open an upstream issue or PR first, and carry the patch only with a link to it.
3. **Pinned everything.** No `HEAD`, `master` or floating tags. CI fails on unpinned sources.
4. **Every patch has a reason.** Each patch file starts with a comment giving its purpose, the upstream issue link (if any) and the removal condition.
5. **Users configure intent, not mechanics.** Users set `domain`, `auth.connectors` and `profiles`. The chart translates these into patches. A per-module override is available for advanced users and marked as unsupported.
6. **Boring defaults.** Defaults match the upstream `example/kustomization.yaml`, except where a documented decision says otherwise.
7. **Upgrades are routine.** Any feature that makes an upgrade harder needs an ADR.

## 5. Architecture

```
 values.yaml  (user intent: domain, auth, profiles, storage, modules)
     │
     ▼
┌───────────────────────── Keelson Helm chart ─────────────────────────┐
│ Layer 1  Opinionated values + values.schema.json                     │
│ Layer 2  Translation: intent → per-module kustomize patches / values │
│ Layer 3  Engine: module registry → ArgoCD AppProject + Applications  │
└──────────────────────────────────────────────────────────────────────┘
     │  renders
     ▼
 ArgoCD Applications (sync waves, retries, health checks)
     │  pull
     ▼
 github.com/kubeflow/manifests @ 26.10.0  (+ upstream Helm repos)
```

### 5.1 Layer 3: engine
- A **module registry** (`charts/keelson/modules/*.yaml`, loaded with `.Files.Glob`) declares, for each module: name, sync wave, source type (`kustomize` | `helm`), upstream path or chart, dependencies, and a default enabled state.
- One template iterates over the registry and renders an `Application` for each enabled module. A shared `defaultAppSpec` provides ServerSideApply, CreateNamespace, retries with backoff and automated sync. A per-module `appSpecOverride` is the escape hatch.
- An `AppProject` restricts source repos to an allowlist (upstream `kubeflow/manifests`, pinned Helm repos, and the user's own repo for patches).
- A `raw:` escape hatch lets users add arbitrary manifests. It is unsupported but available.

### 5.2 Layer 2: translation
Helpers in `templates/_translate_*.tpl` turn intent into inline `spec.source.kustomize.patches` (for Kustomize sources) or `helm.valuesObject` (for Helm sources). Examples:
- `domain` + `tls` → Istio Gateway hosts and HTTPS server, oauth2-proxy secure cookies, Dex connector `redirectURI`s (#6). The Dex issuer stays in-cluster (#5).
- `auth.connectors[]` → Dex `config.yaml` connectors
- `profiles[]` → `Profile` resources plus contributor RoleBindings (rendered into a `keelson-profiles` Application)
- `storage.external.s3` → Pipelines object-store config and the secret reference

Translation logic is the only real code in the project. It is covered by golden tests (§12).

### 5.3 Layer 1: values API (sketch)

```yaml
upstream:
  manifestsRef: "26.10.0"          # single knob for the Kubeflow release
domain: kubeflow.example.com
platform: generic                  # generic | kind; selects platform-specific upstream overlays
tls:
  issuer: existing                  # none | existing | external (selfsigned, letsencrypt: #23)
  secretRef: { name: kubeflow-tls } # issuer=existing: kubernetes.io/tls Secret in istio-system
environment: production            # dev | production
auth:
  dex:
    connectors:
      - type: microsoft             # oidc | microsoft | github
        id: entra
        tenant: "<tenant-id>"       # microsoft; oidc takes issuer + groupsClaim, github takes orgs[]
        secretRef: { name: dex-entra, clientIDKey: clientID, clientSecretKey: clientSecret }
  staticUsers:                       # Kind/testing only; schema forbids it when environment=production
    enabled: false
profiles:
  - name: team-vision
    owner: alice@example.com
    contributors: [ bob@example.com ]
    groups: [ "ml-vision" ]
storage:
  objectStore: bundled               # bundled | external
  external: { endpoint: "", bucket: "", secretRef: {} }
database:
  mode: bundled                      # bundled | external
policy:
  kyverno: { enabled: true, install: false }   # install=false → use an existing Kyverno
argocd:
  namespace: argocd
  project: keelson
modules:
  pipelines: { enabled: true }
  workspaces: { enabled: true }
  notebooks-v1: { enabled: false }   # keys are module names (kebab-case); legacy, upstream EOL notice
advanced:
  modules: {}                        # per-module appSpecOverride / extra patches (unsupported)
```

## 6. Modules and sync waves (26.10 paths)

| Wave | Module | Upstream source (26.10.0) | v0.1 |
|---|---|---|---|
| -100 | cert-manager | `common/cert-manager/base` | ✓ |
| -90 | cert-manager-kubeflow | `common/cert-manager/overlays/kubeflow` (not included by base; ClusterIssuer needs the CRDs and webhook) | ✓ |
| -80 | istio-crds, istio-namespace, kubeflow-namespace | `common/istio/istio-crds/base`, `common/istio/istio-namespace/base`, `common/kubeflow-namespace/base` (istio writes `Sidecar`s into `kubeflow`) | ✓ |
| -70 | istio | `common/istio/istio-install/overlays/oauth2-proxy` | ✓ |
| -60 | oauth2-proxy | `common/oauth2-proxy/overlays/m2m-dex-only` (`m2m-dex-and-kind` on Kind) | ✓ |
| -60 | dex | `common/dex/overlays/oauth2-proxy` | ✓ |
| -50 | kubeflow-roles, kubeflow-istio-resources | `common/kubeflow-roles/base`, `common/istio/kubeflow-istio-resources/base` | ✓ |
| -40 | kyverno policies (optional) | Keelson-owned policies | ✓ |
| 0 | dashboard (central dashboard, profile controller, PodDefaults) | `applications/dashboard/overlays/istio` | ✓ |
| 10 | profiles (Keelson-generated) | rendered from `profiles[]` | ✓ |
| 20 | pipelines | `applications/pipeline/overlays` | ✓ |
| 20 | workspaces | `applications/workspaces/overlays/istio` | ✓ |
| 20 | notebooks-v1 (legacy, off) | `applications/notebooks-v1/...` | opt-in |
| 30 | knative-serving, cluster-local-gateway | `common/knative/knative-serving/overlays/gateways`, `common/istio/cluster-local-gateway/base` | v0.2 (KServe) |
| 40 | kserve, kserve-ui | `applications/kserve/kserve`, `applications/kserve/kserve-ui` | v0.2 |
| 40 | katib, trainer, spark, hub | see `example/kustomization.yaml` | v0.2+ |

Each path must be re-verified against the pinned tag by the `upstream-bump` workflow. Upstream paths do move between releases.

## 7. Module contract

Each module file (`charts/keelson/modules/<name>.yaml`) must declare:

```yaml
name: pipelines
wave: 20
source:
  type: kustomize                 # kustomize | helm
  path: applications/pipeline/overlays
  # helm: { repo: ..., chart: ..., version: ... }  # when type=helm
  # platformPaths: { kind: <path> }  # optional; chosen by values `platform`
namespace: kubeflow               # Application destination namespace
namespaces: [kubeflow]            # every namespace the path writes to (AppProject allowlist)
dependsOn: [dashboard, istio]
defaultEnabled: true
translations: [domain, storage, database]   # which translation helpers apply
smokeTest: tests/e2e/pipelines.sh
upstreamHelmChart: applications/pipeline/helm  # tracked; switch when not Draft
```

A module is accepted only if it has a golden test scenario, a smoke test (or a documented reason it has none), and a docs page.

## 8. Identity

- The default is oauth2-proxy with Dex, because upstream tests that combination. Dex brokers to the user's IdP and is not used as a user database.
- Connectors come from values: Entra ID (`microsoft`), generic OIDC, GitHub, Google, LDAP. Client secrets are referenced through `secretRef` and never inlined.
- Group claims are mapped to profiles through `profiles[].groups` (a Keelson-generated RoleBinding per group).
- Static users exist for Kind/CI only. The schema rejects them when `environment: production`, which also requires a connector.
- With `environment: production`, oauth2-proxy and Dex read their client and cookie secrets from Secrets that the user makes (`auth.oidcClient`, `auth.cookie`), not from upstream's public literals. Keelson never creates these Secrets.
- Connectors are added by replacing upstream's Dex `config.yaml` (the upstream-documented way). The re-stated upstream keys are checked against the pinned tag by `make kustomize-check`. The issuer stays in-cluster.
- A user-management GUI (Keycloak/Authentik) is an **optional future module** that sits behind Dex as one more connector. It is never the default.

## 9. Policy (Kyverno)

- Optional, and can use an existing Kyverno install (`policy.kyverno.install: false`).
- It is used for exactly three things in v0.1: (1) copying the object-store and database secrets into profile namespaces, (2) a Pod Security baseline for notebook and pipeline pods, (3) default labels on profile namespaces.
- CI tests against two current Kyverno minor versions. Each policy is individually switchable.
- Kubernetes `ValidatingAdmissionPolicy` is kept under consideration as a no-dependency alternative for the Pod Security policies (open question Q3).

## 10. Storage and database
- **Bundled:** whatever upstream 26.10 bundles for Pipelines (SeaweedFS for objects, plus the bundled database). Clearly labelled not-for-production.
- **External:** any S3-compatible object store and an external MySQL (PostgreSQL: see goal 7 and #40). On AKS, the documented production path is Azure Database for MySQL, Azure Workload Identity, and object storage reachable through an S3-compatible endpoint. The exact Azure object-store option must be validated before the AKS guide is published (open question Q4).

## 11. Upgrades and tracking upstream
- `upstream.manifestsRef` is the single knob. Changing it should be the whole upgrade for users.
- `.github/workflows/upstream-watch.yaml` runs weekly. When `kubeflow/manifests` has a new release tag, it opens an `upstream-bump` issue containing the changed `example/kustomization.yaml` entries and the component version table.
- The `/upstream-bump` factory command then bumps the ref, re-renders the golden scenarios, verifies every module path still exists, refreshes or removes patches, and runs e2e.
- **Moving to upstream Helm charts:** for each module, track `upstreamHelmChart`. Switch `source.type` to `helm` once (a) the upstream chart README no longer says Draft, (b) upstream's helm-vs-kustomize comparison test covers the scenario we use, and (c) our golden diff is empty or explained. Do this one module per PR.

## 12. Testing strategy

| Gate | Tool | Where |
|---|---|---|
| Chart lint | `helm lint` | pre-commit, CI |
| Schema | `values.schema.json` validated against every scenario's values | CI |
| Golden render | `helm template` per scenario in `tests/golden/<scenario>/` compared with the committed `expected.yaml` | CI (blocking) |
| Manifest validity | `kubeconform` on rendered output (with ArgoCD CRD schemas) | CI |
| Design rules | `hack/check_rules.py`: pinned revisions, source allowlist, sync wave on every Application, a reason header on every patch | CI (blocking) |
| E2E | Kind plus ArgoCD; sync to Healthy; smoke tests: log in through Dex, create a profile, start a workspace, run a sample pipeline | CI on `main` + nightly + bump PRs |
| AKS | Manual checklist before each minor release | release |

## 13. Release and supply chain
- SemVer for the chart. `appVersion` = upstream Kubeflow release (e.g. `26.10.0`).
- Published as an OCI artifact to `ghcr.io/<org>/charts/keelson`, signed with cosign (keyless, GitHub OIDC).
- Images referenced by the release:
  - Prereleases attach an image list (`images.txt`, `images.json`), attested with cosign to the chart digest.
  - `0.1.0` and later releases attach a full SBOM for each referenced upstream image (#61).
- A support policy: the current and previous upstream release, documented in `docs/support-matrix.md`.

## 14. Security
- No inline secrets in values. Secrets are referenced only through `secretRef` (compatible with External Secrets / Azure Key Vault CSI).
- The AppProject restricts allowed source repos and destination namespaces.
- Pod Security baseline by default for user namespaces. Upstream PSS components are used where available.
- `SECURITY.md` with a private reporting route.

## 15. Migration from deployKF
- `hack/deploykf-convert` (v0.1 stretch goal, required by v0.2): converts the deployKF values that matter (domain, Dex connectors, profiles, external MySQL/S3) into Keelson values, and lists what can't be converted.
- `docs/migrating-from-deploykf.md`: covers a side-by-side install and data migration for the Pipelines database and artifacts. In-place migration is not supported.

## 16. Roadmap
- **v0.1:** core + auth + profiles + Kyverno + Pipelines + Workspaces, Kind + AKS docs
- **v0.2:** KServe (+ Knative), Katib, Trainer, deployKF converter
- **v0.3:** MLflow module (per-profile tracking servers, SSO through oauth2-proxy), Hub/Model Registry
- **v0.4+:** Airflow module (only with a co-maintainer), Spark, Keycloak/Authentik optional IdP

## 17. Risks
| Risk | Mitigation |
|---|---|
| A single maintainer burns out | The factory automates bumps; scope is capped; recruit co-maintainers from deployKF users early |
| Upstream breaking changes (Dashboard v2, Workspaces) | Pinned refs; golden diffs make breakage visible; one module per PR |
| Upstream Helm charts change shape | Per-module switch; Kustomize fallback is kept for one release after each switch |
| Overlap with TheCodingSheikh chart | Reach out early; offer collaboration rather than competition |
| Positioning as the deployKF successor | Ask the deployKF maintainers before using that phrasing |

## 18. Open questions
- **Q1** Final project name (check GitHub org, domain, ArtifactHub and trademarks).
- ~~**Q2** ArgoCD: should v0.1 ship a bootstrap script that installs ArgoCD, or only document "bring your own ArgoCD"?~~ **Resolved:** a bootstrap script installs ArgoCD for Kind, dev and CI only; everywhere else is bring-your-own ArgoCD. See [ADR 0003](../adr/0003-kind-bootstrap-installs-argocd.md).
- **Q3** Kyverno vs `ValidatingAdmissionPolicy` for the Pod Security baseline.
- **Q4** Production object store on Azure (which S3-compatible option to document).
- **Q5** Should notebooks-v1 be offered at all in v0.1, given upstream's EOL notice and that Workspaces is the default in 26.10?

## 19. Attribution
Design ideas, and possibly code under Apache-2.0 with attribution in `NOTICE`, come from deployKF, treebeardtech/kubeflow-bootstrap and TheCodingSheikh/helm-charts.
