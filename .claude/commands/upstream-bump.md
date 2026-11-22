---
description: Bump the pinned Kubeflow release and repair modules and patches
argument-hint: <new-tag e.g. 26.10.1>
---
Bump upstream to `$ARGUMENTS`.

1. `make upstream-cache TAG=$ARGUMENTS`, and also make sure the current tag (`upstream.manifestsRef` in `charts/keelson/values.yaml`) is cached.
2. Use the `upstream-scout` subagent to compare the current tag with `$ARGUMENTS` and return an impact summary.
3. Create the branch `chore/upstream-$ARGUMENTS`. Update `upstream.manifestsRef` and `Chart.yaml` `appVersion`.
4. For every module in `charts/keelson/modules/`: check that its `source.path` exists at the new tag, and update or flag it if not.
5. For every patch: check that it still applies (`make golden`). If upstream fixed the issue, delete the patch and note this.
6. `make verify`, then `make e2e`.
7. Open the PR with the scout's impact summary, the golden diff summary and the e2e result. Add the labels `type/upstream-bump` and `needs-e2e`.
