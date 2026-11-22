---
description: Bump the pinned Kubeflow release and repair modules and patches
argument-hint: <new-tag e.g. 26.10.1>
---
Bump upstream to `$ARGUMENTS`.

1. `make upstream-cache TAG=$ARGUMENTS`, and also make sure the current tag (`upstream.manifestsRef` in `charts/keelson/values.yaml`) is cached.
2. Use the `upstream-scout` subagent to compare the current tag with `$ARGUMENTS` and return an impact summary.
3. Create the branch `chore/upstream-$ARGUMENTS`. Update `upstream.manifestsRef` and `Chart.yaml` `appVersion`.
4. For every module in `charts/keelson/modules/`: check that its `source.path` exists at the new tag, and update or flag it if not.
5. Check that `tests/install_KinD_create_KinD_cluster_install_kustomize.sh` still exists at the new tag and still has a pinned `KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:...@sha256:...}"` line. `hack/kind-up.sh` reads it. If it moved, update the script. If its `KIND_VERSION` or node image minor changed, update `version` and `kubectl_version` for `helm/kind-action` in `.github/workflows/e2e.yaml`. Also diff upstream's `kind create cluster` config block (kubeadm patches and node layout) against the heredoc in `hack/kind-up.sh`, and port any changes. Update the minimum kind version in `CONTRIBUTING.md` if `KIND_VERSION` changed.
5a. For every module with `ignoreDifferences`: check that the named resource still exists in `kubectl kustomize <source.path>` at the new tag, with the same kind and name and the field still owned by another controller. For example, the dashboard's `poddefaults-webhook-mutating-webhook-configuration` must still have `caBundle: ""` and `cert-manager.io/inject-ca-from`. A renamed resource silently disables the ignore rule.
6. For every patch: check that it still applies (`make golden`). If upstream fixed the issue, delete the patch and note this.
7. `make verify`, then `make e2e`.
8. Open the PR with the scout's impact summary, the golden diff summary and the e2e result. Add the labels `type/upstream-bump` and `needs-e2e`.
