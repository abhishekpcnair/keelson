# Release checklist

## Prereleases (alpha, beta)

Before the tag:
- [ ] `main` CI green: verify, and the e2e run on `main` (the nightly run is opt-in: repository variable `NIGHTLY_E2E`)
- [ ] The `release` workflow dry run is green on the latest commit that touched it (it runs on pull requests, and with `gh workflow run release.yaml --ref main`)
- [ ] Support matrix is current (`docs/support-matrix.md`)

After the first push of a new package (one time only):
- [ ] On GitHub, set the `keelson` package on ghcr.io to **public** (the repository's Packages settings). A first push creates a private package, and anonymous `helm install` and the component Applications (ADR 0004) fail with 401 or 403 until it's public.

After every release:
- [ ] Pull the chart without logging in: `helm pull oci://ghcr.io/<owner>/charts/keelson --version <version>`
- [ ] Verify the signature with the GitHub OIDC identity (see the README), and check that the image list attestation is present
- [ ] The GitHub release is marked as a prerelease, and its notes are the `CHANGELOG.md` section

## Minor and major releases

Before the tag:
- [ ] The `sbom` dry run is green: `gh workflow run release.yaml --ref main -f sbom=true`

After the release:
- [ ] The `sbom` job is green and `sbom.tar.gz` is attached to the release
- [ ] `cosign verify-attestation --type cyclonedx` on the chart passes (see the README). The count of attestations is the number of unique images in `images.json`

Other checks:
- [ ] `main` CI green: verify, e2e (nightly), upstream-watch shows no pending bump older than four weeks
- [ ] AKS manual test with the `aks-entra-external` scenario:
  - [ ] Fresh AKS cluster, existing ArgoCD, `helm install` from the release candidate
  - [ ] Log in with Entra ID; group → profile mapping works (applies once #28 settles how groups map to profiles)
  - [ ] Create a workspace; run the sample pipeline; artifacts land in the external object store
  - [ ] Upgrade from the previous minor release: Applications return to Healthy without manual steps
- [ ] Support matrix updated (`docs/support-matrix.md`)
- [ ] Release notes: upstream version, breaking changes, migration notes
