# Keelson

**GitOps-first Kubeflow.** One Helm chart and one `values.yaml` render ArgoCD Applications that deploy the **official, pinned** Kubeflow manifests. Keelson ships no forked templates and no forked images, and it stays current: every upstream release produces an automated bump PR with an end-to-end test.

> Status: design phase. Target upstream: Kubeflow Community Distribution **26.10.0**.
> Working name; see open question Q1 in the design doc.

- Design: [`docs/design/0001-architecture.md`](docs/design/0001-architecture.md)
- How we build it: [`docs/development-factory.md`](docs/development-factory.md)
- Backlog: [`docs/backlog.md`](docs/backlog.md)
- Decisions: [`docs/adr/`](docs/adr/)
- Contributing: [`CONTRIBUTING.md`](CONTRIBUTING.md) · Security: [`SECURITY.md`](SECURITY.md) · [Code of Conduct](CODE_OF_CONDUCT.md)

## Install

> Not released yet. The first pre-release, `v0.1.0-alpha.1`, is tracked in #63. The commands below work once it's published.

You need a cluster that already runs ArgoCD. Install the signed chart from the OCI registry:

```sh
helm install keelson oci://ghcr.io/abhishekpcnair/charts/keelson --version 0.1.0-alpha.1
```

Check the signature before you install. Releases are signed with cosign, keyless, using the GitHub OIDC identity of the release workflow:

```sh
cosign verify ghcr.io/abhishekpcnair/charts/keelson:0.1.0-alpha.1 \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github.com/abhishekpcnair/keelson/\.github/workflows/release\.yaml@refs/tags/v'
```

To try Keelson on a laptop, see [Local Kind cluster](CONTRIBUTING.md#local-kind-cluster). What each release is tested with is in the [support matrix](docs/support-matrix.md).

Licensed under [Apache-2.0](LICENSE).

Inspired by [deployKF](https://github.com/deployKF/deployKF), [kubeflow-bootstrap](https://github.com/treebeardtech/kubeflow-bootstrap) and [TheCodingSheikh's kubeflow chart](https://github.com/TheCodingSheikh/helm-charts/tree/main/charts/kubeflow). See [`NOTICE`](NOTICE).

Kubeflow is a trademark of The Linux Foundation. Keelson is not affiliated with the Kubeflow project.
