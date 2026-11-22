# Contributing to Keelson

Thanks for helping. Keelson is a small project with strict rules, so please read this page before you open a pull request.

## Before you start
- Read the [architecture](docs/design/0001-architecture.md), especially §3 (goals and non-goals) and §4 (principles).
- Every change starts as a GitHub issue opened from a template: feature, bug or upstream-bump.
- Implementation starts only after the issue has the `plan-approved` label. This avoids wasted work.
- One issue per pull request. Keep it under about 400 changed lines (rendered golden output doesn't count).

## Hard rules
These come from [`CLAUDE.md`](CLAUDE.md) and are checked by `hack/check_rules.py`:
1. Wrap, don't copy. Never vendor upstream Kubeflow manifests into this repo.
2. No forked images.
3. Pin every source and image. No `HEAD`, `main`, `master` or `latest`.
4. Every patch file starts with `# purpose:`, `# upstream:` and `# remove-when:`.
5. No inline secrets. Use `secretRef`.

## Local setup
You need `helm`, `kubeconform`, the pinned `kustomize` (for `make verify`), `python3` with `pyyaml`, and (for e2e) `kind`, `kubectl` and Docker.

`make verify` also runs `make health-check`, which needs the `argocd` CLI at **v3.6.2**. That is `ARGOCD_VERSION` in `hack/kind-up.sh`, and CI uses the same pin. Use one of these:
- Set `ARGOCD=/path/to/argocd`.
- Put the binary at `.cache/bin/argocd` (gitignored).

Download it from the `v3.6.2` release on GitHub and check it against the release's `cli_checksums.txt`.

```sh
make upstream-cache      # clone the pinned kubeflow/manifests into .cache/upstream/
make verify              # lint, schema, golden-check, kubeconform, rules, kustomize-check, namespaces, health-check (must pass)
make e2e MODULES=core    # Kind + ArgoCD smoke test
```

## Local Kind cluster
`make kind-up` creates a Kind cluster named `keelson` and installs a pinned ArgoCD. It uses the same shape as upstream Kubeflow CI: one control-plane node, two workers, and the service-account-issuer patch. The node image comes from the pinned upstream test script, so `make kind-up` runs `make upstream-cache` first. You can run it again safely; it skips the cluster if it exists.

```sh
make kind-up             # cluster + ArgoCD; kubectl context is kind-keelson
make e2e MODULES=core    # install Keelson, wait for Healthy, run smoke tests (tests/e2e/README.md)
make kind-down           # delete the cluster
```

Plan for RAM. A full Kubeflow install needs about 16 GB for Docker. `MODULES=core` needs less. The script needs `kind` v0.33.0 or newer (the version upstream pins for 26.10.0), `kubectl` and Docker (or Podman, with `KIND_EXPERIMENTAL_PROVIDER=podman`). An older kind fails at the start with a clear message. It does not download tools or use `sudo`. On Linux it warns if your inotify limits are lower than upstream recommends.

If you change rendered output, run `make golden` and **read the diff** before you commit it.

## Pull requests
- Use [Conventional Commits](https://www.conventionalcommits.org/) in titles: `feat:`, `fix:`, `docs:`, `chore(upstream):`.
- Fill in the pull request template. Link the issue with `Closes #<n>`.
- Add a change fragment, `changes/<issue>.md` (see [`changes/README.md`](changes/README.md)).
- Update the schema, golden scenario and docs in the same PR as the code.
- PRs are squash-merged. The PR title becomes the commit message.

## Sign-off (DCO)
We use the [Developer Certificate of Origin](https://developercertificate.org/). Sign each commit with `git commit -s`. This certifies that you have the right to submit the change under the project license.

## AI-assisted contributions
AI-assisted changes are welcome. They follow the same rules and the same review. You are responsible for every line you submit. The maintainer's own workflow is described in [`docs/development-factory.md`](docs/development-factory.md).

## License
By contributing, you agree that your contributions are licensed under the [Apache License 2.0](LICENSE).

## Code of conduct
This project follows the [Code of Conduct](CODE_OF_CONDUCT.md).
