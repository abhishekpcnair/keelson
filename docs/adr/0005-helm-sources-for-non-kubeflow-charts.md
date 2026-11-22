# ADR 0005: Allow Helm sources for non-Kubeflow upstream charts

- Status: accepted
- Date: 2026-11-23

## Context
ADR 0002 says every v0.1 module uses `source.type: kustomize`. The engine accepts no other type on `main`.

Hard rule 1 allows two sources for workloads: `kubeflow/manifests` at a pinned tag, or an upstream Helm chart at a pinned version.

An optional Kyverno install (#67) needs a Helm source. Kyverno is not in `kubeflow/manifests`. Its upstream project publishes it as a Helm chart.

| Item | Value (checked 2026-11-23) |
|---|---|
| Chart repo | `https://kyverno.github.io/kyverno` |
| Chart `3.9.2` | Kyverno `v1.19.2` |
| Chart `3.10.0` | Kyverno `v1.20.0` |

ADR 0002 gives a reason for Kustomize: the Helm charts in `kubeflow/manifests` are drafts. That reason does not apply to a stable chart that an upstream project publishes for its own use.

## Decision
Keelson allows `source.type: helm` for **upstream charts that are not Kubeflow components**. Kubeflow components stay on Kustomize.

1. **Scope.**
   - A Kubeflow component is a workload that `kubeflow/manifests` ships, including its Helm charts. It uses Kustomize (ADR 0002 stays for it).
   - A chart for a component that `kubeflow/manifests` also ships stays on Kustomize. Reason: the Kubeflow release tests that version.
   - A non-Kubeflow upstream chart is a chart that an upstream project publishes, for software that `kubeflow/manifests` does not ship. The first one is Kyverno (#67).
2. **Module fields.** A `helm` module uses the contract in design §7:
   ```yaml
   source:
     type: helm
     helm: { repo: https://kyverno.github.io/kyverno, chart: kyverno, version: 3.9.2 }
   ```
   A module may add a static `values` map. The engine renders it as `helm.valuesObject`. A `helm` module has no `upstreamHelmChart` field. That field is for Kubeflow modules.
3. **Exact stable version.** `version` is an exact SemVer version. It has no range, no `*`, and no prerelease suffix (for example `-rc.1`). `check_rules.py` R2 must check this for a `helm` source (hard rule 3). The code comes with #9 or with #67. A `keelson` source (ADR 0004) is different: its version may be a prerelease, because the alpha release is `0.1.0-alpha.1` and e2e pushes `0.0.0-e2e.<run>`.
4. **Allowlisted repo.** `hack/check_rules.py` gets a constant list of chart repos for R1. A module file cannot add a repo. A new repo needs a change to that constant, and a new row in the table below. The engine adds a repo to the AppProject `sourceRepos` only when a module that uses it is enabled.

   | Repo | Chart | First use |
   |---|---|---|
   | `https://kyverno.github.io/kyverno` | `kyverno` | #67 |
5. **No image changes.** `helm.valuesObject` may hold no `image` key. `check_rules.py` R5 must fail on any `image` key in it, so Keelson cannot change a registry, a repository or a tag (hard rule 2).
6. **Version tracking.** `/upstream-bump` does not see these charts, because they are not in `kubeflow/manifests`. The first PR that adds a `helm` module also extends `hack/upstream_watch.py` to report a newer stable chart version for each `helm` module. No `helm` module merges without it. #62 does the same for the pins in `hack/kind-up.sh`.
7. **No copy.** Keelson wraps the chart. It does not copy chart templates (hard rule 1). A `helm` module needs no `NOTICE` entry for the chart.

### Relation to earlier decisions
- **ADR 0002** applies to Kubeflow modules. Its text "every v0.1 module" means every Kubeflow module. This ADR adds a line to ADR 0002 that points here.
- **ADR 0001 and design principle 1** do not change. Hard rule 1 already allows upstream Helm charts at pinned versions.
- **ADR 0004** adds a different source type, `keelson`, for Keelson-authored resources. A `helm` source and a `keelson` source both render an ArgoCD Helm source. R1 and R5 must check both in the same way. R2 needs an exact SemVer version for both. A `helm` source must also be a stable version (no prerelease). A `keelson` source may be a prerelease.

### Alternatives considered
- **B. Kustomize from the Kyverno git repository.** Rejected: hard rule 1 allows Kubeflow manifests or upstream Helm charts. A git path of another project is neither. It also adds a git repo to the allowlist.
- **C. Remove the install.** Users install Kyverno themselves, and `policy.kyverno.install` goes away. Rejected: no engine change, but a user without Kyverno then gets no optional install. The approved plan for #67 keeps `install: false` for users who have Kyverno.
- **D. Allow `helm` for Kubeflow components too.** Rejected: ADR 0002 keeps Kubeflow components on Kustomize while their charts are drafts.

## Consequences (including the effect on upstream bumps)
- The engine change lands with #67, in its first PR. It accepts `helm` with the fields above, and `check_rules.py` R1, R2 and R5 check chart sources (the code for R1 and R2 may come from #9 first).
- Design §5.1 and §7 are updated in that PR. They already list `helm` as a source type.
- A Kubeflow bump does not change `helm` modules. A chart bump is a normal change to the module file, found by `hack/upstream_watch.py`.
- The Kyverno chart versions in CI follow #67: `3.9.2` and `3.10.0`.
- A later non-Kubeflow chart needs one new row in the table in point 4, and a reason in its issue.
