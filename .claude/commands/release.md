---
description: Prepare a release PR
argument-hint: <semver e.g. 0.1.0>
---
Prepare release v$ARGUMENTS.

1. Check that `main` is green (`gh run list --branch main --limit 3`).
2. Collect `changes/*.md` into a new `CHANGELOG.md` section for v$ARGUMENTS (grouped as Features / Fixes / Upstream / Docs), and delete the fragments.
3. Set `charts/keelson/Chart.yaml` `version: $ARGUMENTS`.
4. For a minor or major release, remind the maintainer to complete `docs/release-checklist.md` (the AKS manual test).
5. Open the PR `release: v$ARGUMENTS`. Once it's merged, the maintainer tags `v$ARGUMENTS`, and that triggers `release.yaml`.
