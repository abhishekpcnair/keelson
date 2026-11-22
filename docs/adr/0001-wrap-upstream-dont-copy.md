# ADR 0001: Wrap upstream manifests; never copy or re-template them

- Status: accepted
- Date: 2026-11-22

## Context
deployKF re-templated every upstream component (682 generator files) and kept forked images. Each Kubeflow release then needed a manual port, and the project stalled on Kubeflow 1.8.

## Decision
Keelson renders ArgoCD Applications that reference `kubeflow/manifests` at a pinned tag (or upstream Helm charts at pinned versions). Keelson contributes only Applications, small headed patches, and Helm values. `hack/check_rules.py` enforces this in CI.

## Consequences
- An upgrade is a ref bump plus re-checking patches, and can be automated (`upstream-watch`, `/upstream-bump`).
- Some customisations are harder. Those go upstream first, or into `advanced.modules` (unsupported).
- When upstream Helm charts leave draft status, modules can switch per module without changing the user-facing values.
