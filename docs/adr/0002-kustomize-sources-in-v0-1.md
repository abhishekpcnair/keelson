# ADR 0002: Use Kustomize sources in v0.1; track upstream draft Helm charts

- Status: accepted
- Date: 2026-11-22

## Context
Kubeflow 26.10 ships Helm charts under `applications/*/helm` and `common/*/helm`, generated from Kustomize. Kustomize remains the source of truth upstream, and the Pipelines chart README says it is a draft and "not administrator-ready".

## Decision
Every v0.1 module uses `source.type: kustomize`. Each module records `upstreamHelmChart` so the switch can be tracked. A module switches to `helm` only when the upstream chart is no longer marked draft, upstream's helm-vs-kustomize comparison covers our scenario, and our golden diff is empty or explained. One module per PR.

## Consequences
No dependence on draft charts for v0.1. A later move to Helm doesn't change the user-facing values.
