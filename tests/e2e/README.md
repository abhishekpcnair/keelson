# E2E tests

The harness installs Keelson into a cluster that already runs ArgoCD. It waits until every Keelson Application is Synced and Healthy. Then it runs each enabled module's smoke test.

## Run it locally

```sh
make kind-up             # Kind cluster + pinned ArgoCD (see CONTRIBUTING.md)
make e2e MODULES=core    # install, wait for Healthy, smoke tests
make kind-down
```

`make e2e` runs `tests/e2e/run.sh <MODULES>`. Extra arguments after `MODULES` go to `helm upgrade --install`, for example `tests/e2e/run.sh core --set ...`.

A full Kubeflow install needs about 16 GB of RAM. On a smaller machine, run only `MODULES=core`, and use CI for anything heavier: add the `needs-e2e` label to the PR, or run `gh workflow run e2e.yaml --ref <branch>`.

## Cleanup helper

Scripts that create state in the cluster or start a process register the cleanup with `on_exit <command>` (from `lib.sh`). Each call adds to one list, and all the commands run in reverse order when the script exits, even on failure. Example: `on_exit 'kubectl delete -f "$fixture" --ignore-not-found'` before the `apply`.

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `E2E_TIMEOUT` | `30m` | How long to wait for Synced + Healthy. Takes an `s`, `m` or `h` suffix. |
| `KEEP` | `0` | `1` keeps a gateway port-forward on `localhost:8080` open after a passing run, so you can look around. Press Ctrl-C to stop it. |
| `GATEWAY_PORT` | `8080` | Local port for the gateway port-forward. `dex-login.sh` needs `8080`. |
| `E2E_INSTALL` | `helm` | `helm` runs `helm upgrade --install`. `root-app` installs through a root ArgoCD Application that pulls the chart from an in-cluster OCI registry, then asserts the sync-wave order. CI uses `root-app` on `main`, nightly and `workflow_dispatch`; PRs use `helm`. |
| `E2E_REG_PORT` | `5555` | Local port for the push to the in-cluster registry (`root-app` only). |

## Root-Application mode (`E2E_INSTALL=root-app`)

1. `tests/e2e/registry.yaml` deploys a test-only OCI registry (`registry:2.8.3`, pinned by digest) in `e2e-registry`.
2. The chart under test is packaged as `<Chart.version>-e2e.<short-sha>` and pushed to it.
3. A test-only repository Secret tells ArgoCD about the registry over plain HTTP.
4. A root Application `keelson-root` (project `default`) renders the chart with the same values as `helm` mode.
5. After every Application is Synced and Healthy, the harness checks that no Application in a higher wave started its first deploy before every lower-wave Application had finished. On failure it prints a table of wave, application, start and end times.

Run it from a branch with `gh workflow run e2e.yaml --ref <branch>`. The `kind` job uses `root-app` for any event that is not a pull request.

## Scenarios

Each `MODULES` value installs a golden scenario's `values.yaml`, so e2e installs exactly what the snapshot shows:

| `MODULES` | Values file |
|---|---|
| `core` | `tests/golden/kind-core/values.yaml` |
| `all` | Not yet. Fails with a message until a broader scenario exists. |

## Extra checks

`auth_oidc.sh` runs after `make e2e MODULES=core`, on the same cluster (CI runs it as the next step). It upgrades the release with `tests/e2e/scenarios/auth-oidc/values.yaml`: one OIDC connector whose issuer is the Kind API server. The script applies upstream's own `unauthenticated-oidc-viewer` binding (from the upstream cache), so that Dex can read the issuer documents. It waits until Dex runs the new config (the `keelson.io/dex-config` hash) and the `dex` Application is Synced and Healthy, then checks the log of those pods for a `config connector` line and no `Failed to open connector` line. On failure it writes the Dex log, the Deployment, the Application and the events to `.cache/e2e/diagnostics/auth-oidc/`. A Ready Dex pod is not enough: Dex starts even when a connector fails to open. It deletes the test objects and upgrades the release back to the core values at the end.

Set `AUTH_OIDC_ISSUER` to try another issuer. A bad URL makes the script fail at step 5. You can run the script again, because step 3 waits for the pods of the new config hash.

## When it fails

`run.sh` exits non-zero and writes diagnostics to `.cache/e2e/diagnostics/`: Application status, pods that aren't running, events, and Dex, oauth2-proxy and ArgoCD controller logs. In CI they are uploaded as the `e2e-diagnostics` artifact.

## Add a smoke test for a module

1. Write `tests/e2e/<name>.sh`. Start it with `set -euo pipefail`, and `source` `lib.sh` for `log`, `fail`, `py`, `upstream_dir` and `port_forward_gateway`.
2. Set `smokeTest: tests/e2e/<name>.sh` in `charts/keelson/modules/<module>.yaml`. If the module has nothing to test beyond Healthy, use `smokeTest: none` with a comment that gives the reason.

Tests run after every Application is Healthy, in module wave order. A path shared by several modules runs once.

Prefer running upstream's own test from `.cache/upstream/<tag>/tests/` over writing a copy. `dex-login.sh` does this with `dex_login_test.py`. It needs something serving `/` behind the gateway, so the dashboard module wires it (#7): `tests/e2e/dashboard.sh` runs it first, then `dashboard.py`. Without the dashboard, core uses `auth-redirect.sh`. With the dashboard, `auth-redirect.sh` also requires oauth2-proxy's sign-in page on `GET /`.

`auth-redirect.sh` applies a test-only route, `tests/e2e/fixtures/protected-route.yaml`, and deletes it at the end. Core has no workload at `/`, and Envoy skips `ext_authz` for a request that matches no route, so the gateway answers `403 RBAC: access denied` there (#106). The route sends `/keelson-e2e/` to the Dex Service. Dex cannot return oauth2-proxy's sign-in form, so the form on that path proves that `ext_authz` answered. That gives a protected path that `ext_authz` checks.
