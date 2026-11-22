# Release checklist (minor and major releases)

- [ ] `main` CI green: verify, e2e (nightly), upstream-watch shows no pending bump older than four weeks
- [ ] AKS manual test with the `aks-entra-external` scenario:
  - [ ] Fresh AKS cluster, existing ArgoCD, `helm install` from the release candidate
  - [ ] Log in with Entra ID; group → profile mapping works
  - [ ] Create a workspace; run the sample pipeline; artifacts land in the external object store
  - [ ] Upgrade from the previous minor release: Applications return to Healthy without manual steps
- [ ] Support matrix updated (`docs/support-matrix.md`)
- [ ] Release notes: upstream version, breaking changes, migration notes
