# Keelson

**GitOps-first Kubeflow.** One Helm chart and one `values.yaml` render ArgoCD Applications that deploy the **official, pinned** Kubeflow manifests. Keelson ships no forked templates and no forked images, and it stays current: every upstream release produces an automated bump PR with an end-to-end test.

> Status: design phase. Target upstream: Kubeflow Community Distribution **26.10.0**.
> Working name; see open question Q1 in the design doc.

- Design: [`docs/design/0001-architecture.md`](docs/design/0001-architecture.md)
- How we build it: [`docs/development-factory.md`](docs/development-factory.md)
- Backlog: [`docs/backlog.md`](docs/backlog.md)
- Decisions: [`docs/adr/`](docs/adr/)
- Contributing: [`CONTRIBUTING.md`](CONTRIBUTING.md) · Security: [`SECURITY.md`](SECURITY.md) · [Code of Conduct](CODE_OF_CONDUCT.md)

Licensed under [Apache-2.0](LICENSE).

Inspired by [deployKF](https://github.com/deployKF/deployKF), [kubeflow-bootstrap](https://github.com/treebeardtech/kubeflow-bootstrap) and [TheCodingSheikh's kubeflow chart](https://github.com/TheCodingSheikh/helm-charts/tree/main/charts/kubeflow). See [`NOTICE`](NOTICE).

Kubeflow is a trademark of The Linux Foundation. Keelson is not affiliated with the Kubeflow project.
