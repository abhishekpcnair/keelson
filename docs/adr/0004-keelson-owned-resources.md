# ADR 0004: Ship Keelson-owned resources through the chart's component mode

- Status: proposed
- Date: 2026-11-22

## Context
Inline Kustomize patches on an upstream path can change upstream objects, but they can't add new ones. Some v0.1 features need resources that upstream doesn't ship:

| Consumer | Resources | CRD comes from |
|---|---|---|
| Profiles as code (#9) | `Profile`, contributor `RoleBinding`s and `AuthorizationPolicy`s | dashboard module (wave 0) |
| Kyverno policies (#11) | `ClusterPolicy` | Kyverno (existing or installed) |
| TLS issuers (#23) | `Certificate`, ACME `ClusterIssuer` | cert-manager (wave -100) |

Design §6 already gives these their own waves. It doesn't say where their manifests come from.

The mechanism must:
- use a pinned source (rule 3), never a branch;
- be managed by ArgoCD and ordered by sync waves, after the CRDs it needs;
- not break a bare `helm install`, because Helm rejects kinds whose CRDs don't exist yet;
- carry no inline secrets (rule 6), only `secretRef`s;
- work in PR e2e, where the chart isn't published;
- stay small, and not make upstream bumps harder (principle 7).

## Decision
Keelson-owned resources are rendered by the **Keelson chart itself in component mode**. Each component is consumed through an ArgoCD Application that points back at **the same pinned chart version**.

1. **Same registry.** A component is a `modules/<name>.yaml` entry with `source.type: keelson` (for example `keelson-profiles`), with a `wave`, `dependsOn` and `defaultEnabled` like any module. It has no upstream path.
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
3. **Copy the subtree.** `valuesObject` contains a copy of the values the component needs, not a reference to the parent release. It's explicit, and it shows up in golden diffs.
4. **Component mode renders only that component.** When `component` is set, the chart renders that component's resources and nothing else: no AppProject and no Applications. A component can't render further Applications.
5. **The self-source is allowlisted and pinned.** `keelson.sourceRepos` adds the self-source to the AppProject. `hack/check_rules.py` R1 and R2 apply to it like any other source.
6. **Override for dev and e2e.** `keelson.selfSource` can point at another pinned source. PR e2e pushes the chart under test to an in-cluster OCI registry and points the override at it, which also works for PRs from forks. The harness registers that registry in ArgoCD with a repository Secret that sets `insecureOCIForceHttp: "true"`. That Secret is test-only, and the chart never renders it.
7. **Minimum ArgoCD version: `v3.6.2`**, the pin from #3/#20. Checked against the ArgoCD source at tag `v3.6.2`:
   - `docs/user-guide/helm.md` and `docs/operator-manual/declarative-setup.md` (Helm section) document Helm charts from OCI registries, with `chart`, a `repoURL` without the `oci://` scheme, and `helm.valuesObject`. Public registries need no credentials.
   - `docs/user-guide/oci.md` also documents native OCI sources (`repoURL: oci://…`, `path: .`) as an alternative form.
   - `util/db/repository_secrets.go` reads the `insecureOCIForceHttp` repository option used in point 6.

The mechanism is implemented with its first consumer (#9), not in this ADR's PR. If it's over about 60 lines, it lands as its own PR first.

### Alternatives considered
- **A. Render the resources directly in the Helm release**, with sync-wave annotations. Rejected: a bare `helm install` fails on missing CRDs, and the waves only work under a root Application.
- **C. A second chart in this repo (`charts/keelson-resources`)**, sourced over git at the release tag. Two charts versioned in lockstep, a git source in the allowlist, and a tag that must exist before use. Making it a signed OCI artifact turns it into option B with extra steps.
- **D. An ArgoCD plugin (CMP) or ApplicationSet generators.** Rejected: both need changes to the user's ArgoCD config, which conflicts with "bring your own ArgoCD" (ADR 0003).
- **E. Upstream components only** (for example `common/user-namespace/base`). Rejected: it covers one fixed user and can't express `profiles[]` or policies.

## Consequences (including the effect on upstream bumps)
- A bare `helm install` keeps working. It creates only Application objects, and ArgoCD applies the component resources after their CRDs exist.
- Components behave like modules: sync waves, health, retries, `dependsOn` checks and `modules.<name>.enabled` all work the same way.
- The chart has two render modes. Golden tests need at least one scenario per component rendered in component mode, as well as the parent scenario that renders the component's Application.
- Everything stays in one chart, one version and one signed OCI artifact (§13). Air-gapped users mirror the same chart they already install.
- PR e2e needs an in-cluster OCI registry. The root-Application e2e mode (#22) reuses it.
- **Upstream bumps:** a bump doesn't change the mechanism. Component resources follow upstream CRD versions (for example `kubeflow.org/v1beta1` `Profile`), so `/upstream-bump` must check those API versions still exist at the new tag, just as it re-checks module paths.
