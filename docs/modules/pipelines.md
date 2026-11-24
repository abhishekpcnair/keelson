# Pipelines

The `pipelines` module installs multi-user Kubeflow Pipelines from
`applications/pipeline/overlays` at the pinned `kubeflow/manifests` tag. Wave 20.

## What it installs
- The KFP API server, UI, persistence agent, scheduled workflow and cache server, in `kubeflow`.
- Argo Workflows (the workflow controller).
- Metacontroller and the KFP profile controller. It gives each profile namespace its own pipeline resources and object-store credentials.
- **SeaweedFS** for artifacts, and **MySQL** for pipeline metadata. Each has a PVC.

All images are upstream images. Keelson sets none.

## Bundled storage is not for production
- SeaweedFS and MySQL run as single pods with one PVC each. There is no backup and no high availability.
- Upstream ships fixed credentials in `Secret/mysql-secret` and `Secret/mlpipeline-minio-artifact`. Anyone who reads the upstream manifests knows them.
- Use bundled storage for evaluation and CI only. External object storage (#12b) and an external database (#12c) replace it.

## Needs
`dashboard`, `cert-manager-kubeflow`, `istio`, `kubeflow-istio-resources` and `kubeflow-roles`. Rendering fails if one of them is off.

## Turn it off
```yaml
modules:
  pipelines:
    enabled: false
```
ArgoCD then deletes the Application but keeps its resources, including the PVCs. Delete them yourself if you want the data gone.

## Domain and TLS
The Pipelines UI is served through `kubeflow-gateway` at `/pipeline`. `domain` and `tls` apply with no extra setting.

## Smoke test
`tests/e2e/pipelines.sh` runs upstream's own tests at the pinned tag: a v2 pipeline run, a rejected unauthorized token, and SeaweedFS namespace isolation.
