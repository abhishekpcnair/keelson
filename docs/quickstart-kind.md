# Quickstart: Keelson on Kind

Install Keelson on a Kind cluster on your laptop. In CI, the same steps take about 6 minutes.

You get the **core** modules: cert-manager, Istio, oauth2-proxy, Dex and the Kubeflow namespaces and roles.
That is 10 ArgoCD Applications. The Kubeflow dashboard, workspaces and pipelines are not in core yet.
See [What is not here yet](#what-is-not-here-yet).

Use Kind for trying Keelson and for development only. For a real cluster, see the AKS guide (planned, #42).

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

Plan for RAM. A full Kubeflow install needs about 16 GB for Docker. Core needs less.
CI runs core on a runner with 16 GB RAM, and the Applications are Healthy in about 4 minutes.
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
kubectl -n argocd get applications -l app.kubernetes.io/part-of=keelson
```

Run it again every minute. Wait until all 10 Applications show `Synced` and `Healthy`.
The list is in [`docs/modules/core.md`](modules/core.md).

`istio` can show `Degraded` for a short time while it starts. This is normal.

## 5. Look at the login

Forward the Istio gateway to your machine:

```sh
kubectl port-forward -n istio-system svc/istio-ingressgateway 8080:80
```

Open `http://localhost:8080/oauth2/start` in a browser. It redirects to the Dex login page.

Log in with the upstream static user:

| Field | Value |
|---|---|
| Email | `user@example.com` |
| Password | `12341234` |

This user is for Kind and development only. Never use it on a shared cluster.
To use your own identity provider, see [Authentication](configuration/authentication.md).

Core has no web app at `/`, so there is nothing to show after the login. The gateway answers `403 RBAC: access denied` at `/`.
This is expected. See the notes in [`docs/modules/core.md`](modules/core.md).
The Kubeflow dashboard comes with the dashboard module (#7).

## Run the checks in one command

Steps 3 and 4 have a shortcut. This command installs Keelson, waits for the Applications and runs the smoke tests:

```sh
make e2e MODULES=core
```

It runs the same commands as steps 3 and 4. It also forwards the gateway to port 8080 for its smoke tests.
Stop the port-forward from step 5 first (press Ctrl-C), or the command fails with "port-forward exited".
You can also set another port: `GATEWAY_PORT=8081 make e2e MODULES=core`.

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
| Kubeflow dashboard | Module #7 (PR #36) |
| Workspaces (Notebooks v2) | Module #14 (PR #72) |
| Pipelines with bundled storage | Module #12 |
| Profiles | #9 |

This page grows when each part lands on `main`: log in to the dashboard, create a workspace, run a sample pipeline.
