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
- Use bundled storage for evaluation and CI only. External object storage (#38) and an external MySQL database (#39) replace it. PostgreSQL is not in v0.1 (#40).

## Resources
Upstream lists Pipelines at about 970m CPU, 3.5 GiB of RAM and 35 GB of storage.
These come on top of core and the dashboard. Use a Docker or VM size that fits all of them.

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

## Istio sidecar
Every Pipelines pod in `kubeflow` needs the `istio-proxy` sidecar. Upstream's DestinationRules require mesh mTLS,
so the gateway cannot reach a pod without one. `/pipeline` then returns `503`.

The sidecar is added when the pod starts. A pod that starts before `istiod` is ready never gets one.
This can happen when you install the chart with plain `helm install`: Helm creates all Applications at once,
and sync waves do not order them. Installing through a root Application orders the waves (see [argocd.md](../argocd.md)).

If `/pipeline` returns `503` after a plain `helm` install, check for pods with no sidecar, then restart them:

```sh
kubectl -n kubeflow get pods -o custom-columns='NAME:.metadata.name,CONTAINERS:.spec.containers[*].name'
kubectl -n kubeflow rollout restart deployment
```

A fix in the chart is tracked in #143.

## Smoke test
`tests/e2e/pipelines.sh` runs upstream's own tests at the pinned tag: a v2 pipeline run, a rejected unauthorized token, and SeaweedFS namespace isolation.

- It needs the profile `kubeflow-user-example-com`. When the namespace is missing, it makes the profile from upstream's `common/user-namespace/base`, as upstream's CI does. It keeps the profile, because later smoke tests use it.
- It forwards the Istio ingress gateway to `localhost:8080`. Port 8080 must be free.
- In a `helm` install it restarts Deployments that have no sidecar (see above). In a root-Application install it fails instead, because the waves should prevent it.
