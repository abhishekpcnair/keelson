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
You need `helm`, `kubeconform`, `python3` with `pyyaml`, and (for e2e) `kind`, `kubectl` and Docker.

```sh
make upstream-cache      # clone the pinned kubeflow/manifests into .cache/upstream/
make verify              # lint, golden diff, kubeconform, rules (must pass)
make e2e MODULES=core    # Kind + ArgoCD smoke test
```

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
