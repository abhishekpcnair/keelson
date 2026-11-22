# ADR 0004: Ship Keelson-owned resources through the chart's component mode

- Status: proposed
- Date: 2026-11-22

## Context
Inline Kustomize patches on an upstream path can change upstream objects, but they can't add new ones. Some v0.1 features need resources that upstream doesn't ship:

| Consumer | Resources | CRD comes from |
|---|---|---|
| Profiles as code (#9) | `Profile`, contributor `RoleBinding`s and `AuthorizationPolicy`s (group scope set by #28) | dashboard module (wave 0) |
| Kyverno policies (#11) | `ClusterPolicy` | Kyverno (existing or installed) |
| TLS issuers (#23) | `Certificate`, ACME `ClusterIssuer` | cert-manager (wave -100) |

Design §6 already gives these their own waves. It doesn't say where their manifests come from.

The mechanism must:
- use a pinned source (rule 3), never a branch;
- be managed by ArgoCD, and applied only after the CRDs it needs exist;
- not break a bare `helm install`, because Helm rejects kinds whose CRDs don't exist yet;
- carry no inline secrets (rule 6), only `secretRef`s;
- work in PR e2e, where the chart isn't published;
- stay small, and not make upstream bumps harder (principle 7).

## Decision
Keelson-owned resources are rendered by the **Keelson chart itself in component mode**. Each component is consumed through an ArgoCD Application that points back at **the same pinned chart version**.

1. **Same registry, new source type.** A component is a `modules/<name>.yaml` entry with `source.type: keelson` (for example `keelson-profiles`), with a `wave`, `dependsOn` and `defaultEnabled` like any module. It has no upstream path.
2. **The engine renders an Application per enabled component.** Its source is `keelson.selfSource`. By default, that's the chart's OCI artifact at `.Chart.Version`:
   ```yaml
   source:
     repoURL: ghcr.io/<org>/charts      # no oci:// scheme for Helm-type OCI sources
     chart: keelson
     targetRevision: <.Chart.Version>   # pinned
     helm:
       valuesObject:
         component: profiles
         profiles: [ ... ]              # a copy of only the subtree this component needs
   ```
   Component Applications also set `SkipDryRunOnMissingResource=true`. The first sync then doesn't fail its dry run while the CRD is still being installed.
3. **Copy the subtree.** `valuesObject` contains a copy of the values the component needs, not a reference to the parent release. It's explicit, and it shows up in golden diffs.
4. **Component mode renders only that component.** When `component` is set, the chart renders that component's resources and nothing else: no AppProject and no Applications. A component can't render further Applications.
5. **`component` is internal and validated.** `values.schema.json` restricts `component` to an enum of the registered `source.type: keelson` modules, and the chart calls `fail` on any other value. Users never set it. Only the engine writes it into `valuesObject`.
6. **Missing CRD modules fail at render time.** `dependsOn` is enforced when the chart renders, as it is for upstream modules. For example, enabling `keelson-profiles` while `dashboard` is disabled is a render-time `fail` naming both modules, not an ArgoCD sync that retries forever. A component whose values are empty (for example `profiles: []`) renders **no Application at all**.
7. **The self-source is allowlisted and pinned.** `keelson.sourceRepos` adds the self-source to the AppProject. `hack/check_rules.py` R1 and R2 apply to it like any other source. A `keelson.selfSource` override may pin a chart version or a digest. `.Chart.Version` is a tag, and a digest is the stricter choice for mirrors.
8. **Repository Secrets are never rendered by the chart.**
   - **Public `ghcr.io`:** no Secret is needed. ArgoCD reads public OCI Helm charts without credentials.
   - **Private or mirrored registries:** the user creates an ArgoCD repository Secret (`type: helm`, `enableOCI: "true"`, plus credentials) themselves, just as for any private Helm repository.
   - **PR e2e:** the harness pushes the chart under test to an in-cluster OCI registry and points the `keelson.selfSource` override at it. This also works for PRs from forks. The harness registers that registry with a test-only repository Secret: `type: helm`, `enableOCI: "true"` and `insecureOCIForceHttp: "true"`.
9. **Ordering.** Under a root Application (#22), sync waves order the component Applications after their dependencies. Under a bare `helm install`, ArgoCD ignores sync waves on sibling Applications, so component Applications converge through the `defaultAppSpec` retries with backoff, as upstream modules already do. This is the same limitation for every module, and it's documented in #2.
10. **Minimum ArgoCD version: `v3.6.2`.** That's the version #3 pins (PR #20, `ARGOCD_VERSION` in `hack/kind-up.sh`). It was checked against the ArgoCD source at tag `v3.6.2`:
    - `docs/user-guide/helm.md` and `docs/operator-manual/declarative-setup.md` (Helm section) document Helm charts from OCI registries, with `chart`, a `repoURL` without the `oci://` scheme, and `helm.valuesObject`. Repository Secrets for them set `enableOCI: "true"`.
    - `docs/user-guide/oci.md` documents native OCI sources (`repoURL: oci://…`, `path: .`) as an alternative form.
    - `util/db/repository_secrets.go` reads the `insecureOCIForceHttp` repository option used in point 8.

The mechanism is implemented with its first consumer (#9), as #21 says. The maintainer decided on #9 that if it's over about 60 lines, it lands as its own PR before #9.

### Relation to earlier decisions
- **ADR 0002** makes every v0.1 module `source.type: kustomize`. This ADR **extends** it with a third source type, `keelson`, for Keelson-owned components only. Upstream workloads still come only from Kustomize sources in v0.1.
- **Design principle 1 and ADR 0001** limit Keelson to Application objects, Kustomize patches and Helm values. This ADR **narrows that rule to allow Keelson-authored resources that upstream doesn't ship**: Profiles, policies and certificates built from user intent.
  - Component templates must never copy upstream Kubeflow templates.
  - Anything borrowed from a third party, for example Kyverno policies adapted from `kyverno/policies` for #11, needs attribution in `NOTICE` and in the file header.

### Alternatives considered
- **A. Render the resources directly in the Helm release.** Rejected: a bare `helm install` fails on missing CRDs.
- **C. A second chart in this repo (`charts/keelson-resources`)**, sourced over git at the release tag. Rejected: two charts versioned in lockstep, a git source in the allowlist, and a tag that must exist before use. Making it a signed OCI artifact turns it into option B with extra steps.
- **D. An ArgoCD plugin (CMP) or ApplicationSet generators.** Rejected: both need changes to the user's ArgoCD config. Design goal 1 is "one `helm install` plus ArgoCD", and design §18 Q2 is still open on whether Keelson installs ArgoCD at all, so Keelson can't assume control of the user's ArgoCD configuration.
- **E. Upstream components only** (for example `common/user-namespace/base`). Rejected: it covers one fixed user and can't express `profiles[]` or policies.

## Consequences (including the effect on upstream bumps)
- A bare `helm install` keeps working. It creates only Application objects, and ArgoCD applies the component resources after their CRDs exist, retrying until they do.
- Components behave like modules: health, retries, `dependsOn` checks and `modules.<name>.enabled` all work the same way. Sync waves order them under a root Application.
- The chart has two render modes. Golden tests need at least one scenario per component rendered in component mode, as well as the parent scenario that renders the component's Application.
- Everything stays in one chart, one version and one signed OCI artifact (§13). Air-gapped users mirror the same chart they already install, plus their own repository Secret.
- PR e2e needs an in-cluster OCI registry. The root-Application e2e mode (#22) reuses it.
- **Upstream bumps:** a bump doesn't change the mechanism. Component resources follow upstream CRD versions (for example `kubeflow.org/v1` `Profile`, the storage version at 26.10.0), so `/upstream-bump` must check those API versions still exist at the new tag, just as it re-checks module paths.
