# Security policy

## Supported versions
Keelson is pre-release. Only the latest release gets security fixes. After v0.1, the support policy follows [`docs/design/0001-architecture.md`](docs/design/0001-architecture.md) §13: the current and the previous upstream Kubeflow release.

## Reporting a vulnerability
**Don't open a public issue.** Report it privately through [GitHub private vulnerability reporting](https://github.com/abhishekpcnair/keelson/security/advisories/new).

Please include:
- the Keelson version and the `values.yaml` settings involved (with secrets removed)
- what an attacker can do, and the steps to reproduce it

You'll get an acknowledgement within 7 days. We'll agree a disclosure date with you once a fix is ready.

## Scope
- **In scope:** what Keelson renders: ArgoCD Applications, AppProject, patches, translation helpers and Kyverno policies.
- **Upstream components:** vulnerabilities in Kubeflow images or manifests belong to the [Kubeflow project](https://github.com/kubeflow/manifests/security). Report them there. We'll pick up the fix through a pinned upstream bump.
