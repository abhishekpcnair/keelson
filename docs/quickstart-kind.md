# Quickstart: Keelson on Kind

Install Keelson on a Kind cluster on your laptop.

You get the **core** modules (cert-manager, Istio, oauth2-proxy, Dex and the Kubeflow namespaces and roles), the **dashboard**,
**workspaces** and **pipelines** modules. That is 14 ArgoCD Applications.
See [What is not here yet](#what-is-not-here-yet).

Use Kind for trying Keelson and for development only. For a real cluster, see the [AKS guide](guides/aks.md).

## Before you start

You need these tools on your `PATH`:

| Tool | Version |
|---|---|
| Docker (or Podman) | Running. For Podman, set `KIND_EXPERIMENTAL_PROVIDER=podman`. |
| `kind` | v0.33.0 or newer |
| `kubectl` | v1.37.0 is the version CI uses. Stay within one minor version of it. |
| `helm` | v4.x |
| `git`, `make`, `curl` | Any recent version |
| `python3` | Any recent version, with the `venv` module (Debian and Ubuntu: `python3-venv`) and network access for `pip`. `make e2e` makes a virtual environment. |

The scripts never download tools and never use `sudo`.

Plan for RAM. This install needs about 16 GB for Docker: Pipelines alone needs about 3.5 GiB of RAM and 35 GB of disk.
CI runs it on a runner with 16 GB RAM and 4 CPUs.
On Linux, `make kind-up` warns when the inotify limits are low.

## 1. Get the code

```sh
git clone https://github.com/abhishekpcnair/keelson.git
cd keelson
```

## 2. Create the cluster

```sh
make kind-up
```

This creates a Kind cluster named `keelson` with 1 control-plane node and 2 workers.
It installs ArgoCD `v3.6.2`, metrics-server, and the ArgoCD health checks that Keelson needs.
The kubectl context is `kind-keelson`.
When the cluster already exists, `make kind-up` does not switch the context. Switch it yourself, so that the next steps use this cluster:

```sh
kubectl config use-context kind-keelson
```

The first run fetches the upstream Kubeflow manifests into `.cache/upstream/`. You can run the command again safely.

## 3. Install Keelson

```sh
helm upgrade --install keelson charts/keelson -n argocd -f tests/golden/kind-core/values.yaml
```

The values file sets `platform: kind`. This selects the Kind overlays of the upstream manifests.
Every other value has its default.

This creates the ArgoCD Applications. ArgoCD then installs Kubeflow from the pinned upstream release.

## 4. Wait until the Applications are Healthy

```sh
kubectl -n argocd get applications.argoproj.io -l app.kubernetes.io/part-of=keelson
```

Run it again every minute. Wait until all 14 Applications show `Synced` and `Healthy`.
Use the full name `applications.argoproj.io`: Pipelines installs a second `Application` kind (`applications.app.k8s.io`), and plain `applications` can pick that one.
The core modules are in [`docs/modules/core.md`](modules/core.md). The dashboard is in [`docs/modules/dashboard.md`](modules/dashboard.md), Workspaces in [`docs/modules/workspaces.md`](modules/workspaces.md) and Pipelines in [`docs/modules/pipelines.md`](modules/pipelines.md).

`istio` can show `Degraded` for a short time while it starts. This is normal.
If `/pipeline` later returns `503`, some pods started before Istio was ready. See [Istio sidecar](modules/pipelines.md#istio-sidecar).

## 5. Open the dashboard

Forward the Istio gateway to your machine:

```sh
kubectl port-forward -n istio-system svc/istio-ingressgateway 8080:80
```

Open `http://localhost:8080` in a browser. oauth2-proxy sends you to the Dex login page.

Log in with the upstream static user:

| Field | Value |
|---|---|
| Email | `user@example.com` |
| Password | `12341234` |

This user is for Kind and development only. Never use it on a shared cluster.
To use your own identity provider, see [Authentication](configuration/authentication.md).

After the login, the Kubeflow central dashboard opens. CI checks this login and the dashboard on every run.

A new user has no namespace yet. Step 6 makes one.

If you turn the dashboard module off, there is no web app at `/`, and the gateway answers `403 RBAC: access denied`.
See the notes in [`docs/modules/core.md`](modules/core.md).

## 6. Make a profile namespace

Kubeflow gives each user a namespace through a `Profile`. On a real cluster you list profiles in the
`profiles` value ([Profiles](configuration/profiles.md)). That needs a published Keelson chart, so on a git
checkout use upstream's test Profile instead. It makes `kubeflow-user-example-com`, owned by `user@example.com`:

```sh
TAG="$(sed -nE 's/^  manifestsRef: "(.*)"/\1/p' charts/keelson/values.yaml)"   # the pinned Kubeflow release
kubectl apply -k ".cache/upstream/$TAG/common/user-namespace/base"
kubectl -n kubeflow-user-example-com get serviceaccount default-editor
```

`make kind-up` fetched `.cache/upstream/$TAG`. The last command fails until the profile controller has made the
namespace; run it again after a few seconds. Reload the dashboard: it now shows the namespace.

## 7. Start a workspace

Workspaces (Notebooks v2) run in a profile namespace. Start upstream's test Workspace, a JupyterLab:

```sh
kubectl apply -f ".cache/upstream/$TAG/tests/workspace.test.kubeflow-user-example-com.yaml"
kubectl -n kubeflow-user-example-com get workspace test -o jsonpath='{.status.state}{"\n"}'
```

Run the second command until it prints `Running`. The first start pulls a large image and can take several
minutes. It can show `Error` for up to 3 minutes while the readiness probe waits; then it changes to `Running`.
The dashboard menu links to `/workspaces/`, where you can open it. See [Workspaces](modules/workspaces.md).

Delete it when you are done:

```sh
kubectl delete -f ".cache/upstream/$TAG/tests/workspace.test.kubeflow-user-example-com.yaml"
```

## 8. Run a sample pipeline

Run upstream's pipeline test in the profile namespace. It uses the KFP SDK at the version upstream's CI pins,
and it talks to Kubeflow Pipelines through the gateway on `localhost:8080`, so keep the port-forward from step 5 open:

```sh
python3 -m venv .cache/kfp-venv
.cache/kfp-venv/bin/pip install "kfp==2.18.0" "kfp-kubernetes==2.18.0"
TOKEN="$(kubectl -n kubeflow-user-example-com create token default-editor)"
.cache/kfp-venv/bin/python ".cache/upstream/$TAG/tests/pipeline_v2_test.py" run_pipeline "$TOKEN" kubeflow-user-example-com
```

It submits a small v2 pipeline and waits until the run succeeds. The run also shows in the Pipelines UI at
`http://localhost:8080/pipeline/`. If `/pipeline` returns `503`, see [Istio sidecar](modules/pipelines.md#istio-sidecar).
Pipelines is described in [Pipelines](modules/pipelines.md). Its bundled MySQL and SeaweedFS are for evaluation only.

## Run the checks in one command

Steps 3 and 4 have a shortcut. This command installs Keelson, waits for the Applications and runs the smoke tests:

```sh
make e2e MODULES=core
```

It runs the same commands as steps 3 and 4, then the smoke test of each module, which includes steps 6, 7 and 8.
It forwards the gateway to port 8080 for its smoke tests, and several of them need port 8080 (they use upstream's tests).
Stop the port-forward from step 5 first (press Ctrl-C), or the command fails with "port-forward exited".

Add `KEEP=1` to keep the gateway port-forward open after the checks pass:

```sh
KEEP=1 make e2e MODULES=core
```

If a check fails, the script writes logs to `.cache/e2e/diagnostics/`.

## Clean up

```sh
make kind-down
```

This deletes the Kind cluster.

## What is not here yet

| Part | Status |
|---|---|
| KServe, Katib, Trainer, Model Registry | v0.2 and later (design 0001, §3) |

This page grows when each part lands on `main`: create a workspace, run a sample pipeline.
