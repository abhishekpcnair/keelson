# Changelog

## v0.1.0-alpha.1

### Features

- module registry engine. The chart renders an `AppProject` and one ArgoCD `Application` per enabled module in `charts/keelson/modules/`. Ships the 10 core dependency modules (cert-manager, Istio, oauth2-proxy, Dex, Kubeflow namespace, roles and Istio resources) and adds the `platform`, `argocd.destinationServer`, `argocd.extraSourceRepos`, `modules.<name>.enabled` and `advanced.modules.<name>.appSpecOverride` values. `appSpecOverride` is an allow-list (`syncPolicy`, `ignoreDifferences`, `info`, `revisionHistoryLimit`, `source.path`, and a small `source.kustomize` subset with image-free inline patches), so it can't change the pinned source, project or destination. (#1)
- ArgoCD health checks for sync waves. `hack/argocd/argocd-cm-health.yaml` adds `Application` and `Workspace` health checks that you apply to `argocd-cm` yourself (the chart never writes it), tested offline by `make health-check`. The engine now fails if a module's wave isn't higher than its dependencies' waves. See `docs/argocd.md`. (#2)
- `make kind-up` creates a Kind cluster in upstream's CI shape and installs a pinned ArgoCD (v3.6.2); `make kind-down` deletes it. (#3)
- `make e2e MODULES=core` installs Keelson on a Kind cluster with ArgoCD, waits until every Application is Synced and Healthy, and runs module smoke tests (an auth redirect check through Istio, oauth2-proxy and Dex). (#4)
- `domain` and `tls.issuer` (`none` | `existing` | `external`). The Kubeflow Gateway serves only on `domain`; `existing` adds HTTPS on :443 with your `tls.secretRef` Secret and an HTTP redirect; `existing` and `external` turn on secure oauth2-proxy cookies. Adds the module `translations` hook and `make kustomize-check`, which builds patched modules against the pinned upstream offline. (#5)
- Dex connectors and static users. New `environment` (`dev` | `production`), `auth.staticUsers.enabled` and `auth.dex.connectors[]` with the `oidc` type. Client IDs and secrets come only from a `secretRef` Secret in `auth`. `production` needs static users off and at least one connector. `make kustomize-check` fails if the Dex config drifts from upstream. (#6)
- `dashboard` module (central dashboard, PodDefaults webhook, profile controller with KFAM) from `applications/dashboard/overlays/istio`, on by default at wave 0. Modules can now declare `ignoreDifferences`; the dashboard uses it so ArgoCD doesn't reset the cert-manager-injected webhook `caBundle`. (#7)
- the release workflow takes notes from `CHANGELOG.md`, marks `-alpha`/`-beta` versions as prereleases, attaches an image list attested with cosign, and has a dry run that runs on pull requests; adds `docs/support-matrix.md` and a prerelease checklist. (#15)
- `make verify` checks each module's `namespaces:` list against the upstream `kubectl kustomize` output (#18)
- the values schema rejects unknown top-level keys, so a typo such as `platfrom: kind` fails instead of using the default. Placeholders declare the keys that later issues add. Before upgrading, remove any stray top-level keys from your values.yaml. (#19)
- e2e root-Application mode on main and nightly installs through an in-cluster OCI registry and asserts that sync waves order the install (#22)
- `microsoft` (Entra ID) and `github` Dex connector types. `microsoft` needs a single-tenant `tenant` and makes emails lowercase by default. `github` needs at least one `orgs[]` entry. GitHub Enterprise is not supported yet (#46). (#26)
- `auth.oidcClient.secretRef` and `auth.cookie.secretRef` make oauth2-proxy and Dex read their client and cookie secrets from your Secrets, not from upstream's public literals. `environment: production` requires both. The names `oauth2-proxy` and `dex-oidc-client` are rejected. (#27)
- kind-up verifies the sha256 of the pinned ArgoCD install.yaml before it applies it (#31)
- `make values-ref` generates `docs/reference/values.md` from `values.schema.json`. `make verify` fails when the file is stale or a schema property has no `description`. (#41)
- the values schema rejects uppercase letters in `domain`. (#48)
- upstream-watch reports newer ArgoCD and metrics-server releases for the kind-up pins (#62)
- `make kustomize-check` verifies that each `ignoreDifferences` entry names a resource in the upstream overlay, and that `/rules` entries on a ClusterRole still have `aggregationRule`. (#108)

### Fixes

- rule R5 finds image changes in JSON and JSON6902 patches, and in `*.json` patch files (#24)
- ignore a `.cache` symlink, not only a directory, and add rule R6 that rejects tracked symlinks in `make verify` (#25)
- e2e starts one run per PR event and cancels superseded runs (#30)
- kind-up retries the apiserver check after a cluster restart (#35)
- core Applications reach Synced/Healthy on Kind (ignore controller-owned fields, metrics-server in kind-up, inotify limits in CI e2e) (#37)
- R6 fails on a --repo path that is not a git repository (#47)
- kind-up existing-cluster checks time out after 5s per call (#55)
- `make namespaces` uses the pinned `kustomize build`, the same binary as `make kustomize-check` (#59)
- `check_namespaces` errors go to stderr and handle bad module files and a tool that cannot run (#60)
- the engine rejects `ignoreDifferences` entries (registry or `appSpecOverride`) that name no field to ignore (#64)
- `appSpecOverride` `syncOptions` merge into the engine defaults by key, so an override keeps `ServerSideApply=true` and `CreateNamespace=true` (#65)
- `make health-check` fails when the argocd CLI exits non-zero and cleans up its temp files; `CONTRIBUTING.md` names the pinned CLI; e2e checks that `make kind-up` applied the health checks under their own field manager. (#70)
- R6 fails when git cannot run; the R6 tests do not depend on the locale or a parent repo (#71)
- check_kind_up_health uses the kind-keelson context (#76)
- the engine rejects empty `ignoreDifferences` items and checks the `appSpecOverride` of disabled modules. A bad override on a disabled module now fails the render. (#79)
- T1 checks indented doc comments, fails on a missing `--templates` folder or one with no `*.tpl` files, and shows how many comments it checked (#84)
- an `ignoreDifferences` entry in an `appSpecOverride` also forces `RespectIgnoreDifferences=true` (#88)
- `check_namespaces` gives clear N0 messages for an empty `source:` and for a module file that is not UTF-8 (#89)
- `extraConfig` guard keys for the `microsoft` and `github` connectors are blocked in any letter case. (#91)
- remove the `loadAllGroups` key of the `github` connector. Dex ignores it while `orgs` is set, and `orgs` is required. (#92)
- `check_version` raises `VersionError`, so callers add their own prefix; the namespaces check tests cover a missing `kustomize_install.sh` (#98)
- `extraConfig` keys are ASCII only, so Unicode case folding cannot bypass the guard keys. (#103)

### Docs

- Kind quickstart (`docs/quickstart-kind.md`): create the cluster, install core, wait for the Applications, look at the login, clean up. The README links to it. (#16)
- ADR 0004 (proposed) ships Keelson-owned resources through the chart's component mode (#21)
- design goal 7 is MySQL only in v0.1; PostgreSQL waits for an upstream cert-manager overlay (#40)
- ADR 0004 selfSource overrides pin an exact chart version, not a digest (#57)
- CLAUDE.md lesson and `make rules` check T1: a helper doc comment in the chart templates comes directly before its own `define` (#80)
