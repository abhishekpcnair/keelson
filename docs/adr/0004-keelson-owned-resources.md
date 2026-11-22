# ADR 0004: Ship Keelson-owned resources through the chart's component mode

- Status: accepted
- Date: 2026-11-22

## Context
Inline Kustomize patches on an upstream path can change upstream objects, but they can't add new ones. Some v0.1 features need resources that upstream doesn't ship:

| Consumer | Resources | CRD comes from |
|---|---|---|
| Profiles as code (#9) | `Profile`, contributor `RoleBinding`s and `AuthorizationPolicy`s (group scope set by #28) | `Profile`: dashboard module (wave 0). `AuthorizationPolicy`: istio-crds (wave -80) |
| Kyverno policies (#11) | `ClusterPolicy` | Kyverno (existing or installed) |
| TLS issuers (#23) | `Certificate`, ACME `ClusterIssuer` | cert-manager (wave -100) |

Design §6 gives profiles (wave 10) and Kyverno policies (wave -40) their own rows. #23 will add a TLS row after `cert-manager-kubeflow` (wave -90). §6 doesn't say where any of these manifests come from.

The mechanism must:
- use a pinned source (rule 3), never a branch;
- be managed by ArgoCD, and applied only after the CRDs it needs exist;
- not break a bare `helm install`, because Helm rejects kinds whose CRDs don't exist yet;
- carry no inline secrets (rule 6), only `secretRef`s;
- work in PR e2e, where the chart isn't published;
- stay small, and not make upstream bumps harder (principle 7).

## Decision
**Option B:** Keelson-owned resources are rendered by the **Keelson chart itself in component mode**. Each component is consumed through an ArgoCD Application that points back at **the same pinned chart version**.

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
7. **The self-source is allowlisted and pinned.** `keelson.sourceRepos` adds the self-source to the AppProject. `hack/check_rules.py` R1 and R2 apply to it like any other source.
   - **The default resolves only for a published release.** Every other install must set `keelson.selfSource`, or its component Applications point at a ghcr.io artifact that may not exist, or may differ from what's installed. That covers installs from a git checkout or a fork, mirrored or air-gapped registries, and PR e2e.
   - An override may pin a chart version or a digest. `.Chart.Version` is a tag, and a digest is the stricter choice for mirrors.
8. **Repository Secrets are never rendered by the chart.**
   - **Public `ghcr.io`:** no Secret is needed. ArgoCD reads public OCI Helm charts without credentials.
   - **Private or mirrored registries:** the user creates an ArgoCD repository Secret (`type: helm`, `enableOCI: "true"`, plus credentials) themselves, just as for any private Helm repository.
   - **PR e2e:** the harness pushes the chart under test to an in-cluster OCI registry and points the `keelson.selfSource` override at it. This also works for PRs from forks. The harness registers that registry with a test-only repository Secret: `type: helm`, `enableOCI: "true"` and `insecureOCIForceHttp: "true"`.
9. **Ordering.** Under a root Application (#22), sync waves order the component Applications after their dependencies. Under a bare `helm install`, ArgoCD ignores sync waves on sibling Applications, so component Applications converge only through the `defaultAppSpec` retries, as upstream modules already do. That budget is 10 retries, backing off from 10s and doubling to a 5-minute cap: about 30 minutes in total. This is the same limitation for every module, and documenting it is planned in #2.
10. **Minimum ArgoCD version: `v3.6.2`.** That's `ARGOCD_VERSION` in `hack/kind-up.sh` (ADR 0003). It was checked against the ArgoCD source at tag `v3.6.2`:
    - `docs/user-guide/helm.md` and `docs/operator-manual/declarative-setup.md` (Helm section) document Helm charts from OCI registries, with `chart`, a `repoURL` without the `oci://` scheme, and `helm.valuesObject`. Repository Secrets for them set `enableOCI: "true"`.
    - `docs/user-guide/oci.md` documents native OCI sources (`repoURL: oci://…`, `path: .`) as an alternative form.
    - `util/db/repository_secrets.go` reads the `insecureOCIForceHttp` repository option used in point 8.

The mechanism is implemented with its first consumer (#9), or in an engine PR just before it.

### Principles this ADR bends
- **ADR 0002** makes every v0.1 module `source.type: kustomize`, and the engine fails on any other type. Design §5.1 and §7 list only `kustomize | helm`. This ADR **extends** them with a third source type, `keelson`, for Keelson-owned components only. Upstream workloads still come only from Kustomize sources in v0.1.
- **Design principle 1 (§4) and ADR 0001** limit Keelson to Application objects, Kustomize patches and Helm values. This ADR **narrows that rule**:
  - It allows Keelson-authored **configuration** resources that upstream doesn't ship: Profiles, RBAC and Istio policies, Kyverno policies, and cert-manager `Certificate`s and `ClusterIssuer`s, all built from user intent.
  - It never allows workloads or images. #9 extends `check_rules.py` R5 to scan component-mode render output, where any `image:` key fails.
  - Component templates must never copy upstream Kubeflow templates or third-party templates.
  - Anything adapted from a third party, for example Kyverno policies adapted from `kyverno/policies` for #11, needs attribution in `NOTICE` and in the file header.
- Design §4, §5.1 and §7 are updated to match in the first PR that implements the mechanism (#9, or the engine PR before it).

### Alternatives considered
- **A. Render the resources directly in the Helm release.** Rejected: a bare `helm install` fails on missing CRDs.
- **C. A second chart in this repo (`charts/keelson-resources`)**, sourced over git at the release tag. Rejected: two charts versioned in lockstep, a git source in the allowlist, and a tag that must exist before use. Making it a signed OCI artifact turns it into option B with extra steps.
- **D1. A Config Management Plugin (CMP).** Rejected: it needs a change to the user's ArgoCD configuration (a sidecar on the repo server), and ADR 0003 makes ArgoCD bring-your-own outside Kind.
- **D2. ApplicationSets.** Rejected: List and Git generators work with a stock ArgoCD, but an ApplicationSet only templates Applications. It still needs a source for the `Profile` and `ClusterPolicy` manifests, which is the problem this ADR solves. It also puts a second controller in the path.
- **E. Upstream components only** (for example `common/user-namespace/base`). Rejected: it covers one fixed user and can't express `profiles[]` or policies.

## Consequences (including the effect on upstream bumps)
- A bare `helm install` keeps working. It creates only Application objects, and ArgoCD applies the component resources after their CRDs exist, within the retry budget in point 9. For anything other than a published release, `keelson.selfSource` must be set (point 7).
- Components behave like modules: health, retries, `dependsOn` checks and `modules.<name>.enabled` all work the same way. Sync waves order them under a root Application.
- The chart has two render modes. Golden tests need at least one scenario per component rendered in component mode, as well as the parent scenario that renders the component's Application.
- Everything stays in one chart, one version and one signed OCI artifact (§13). Air-gapped users mirror the same chart they already install, plus their own repository Secret.
- PR e2e needs an in-cluster OCI registry. The root-Application e2e mode (#22) reuses it.
- **Upstream bumps:** a bump doesn't change the mechanism. Component resources follow upstream CRD versions (for example `kubeflow.org/v1` `Profile`, the storage version at 26.10.0), so `/upstream-bump` must check those API versions still exist at the new tag, just as it re-checks module paths.
