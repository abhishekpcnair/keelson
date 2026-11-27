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
| `E2E_REG_PORT` | `5555` | Local port for the push to the in-cluster registry (`root-app` mode, and `MODULES=profiles` in `helm` mode). |

## Root-Application mode (`E2E_INSTALL=root-app`)

1. `tests/e2e/registry.yaml` deploys a test-only OCI registry (`registry:2.8.3`, pinned by digest) in `e2e-registry`.
2. The chart under test is packaged as `<Chart.version>-e2e.<unix-time>.g<short-sha>` and pushed to it.
3. A test-only repository Secret tells ArgoCD about the registry over plain HTTP.
4. A root Application `keelson-root` (project `default`) renders the chart with the same values as `helm` mode.
5. After every Application is Synced and Healthy, the harness checks that no Application in a higher wave started its first deploy before every lower-wave Application had finished. On failure it prints a table of wave, application, start and end times.

Run it from a branch with `gh workflow run e2e.yaml --ref <branch>`. The `kind` job uses `root-app` for any event that is not a pull request.

## Scenarios

Each `MODULES` value installs a golden scenario's `values.yaml`, so e2e installs exactly what the snapshot shows:

| `MODULES` | Values file |
|---|---|
| `core` | `tests/golden/kind-core/values.yaml` |
| `profiles` | `tests/golden/profiles/values.yaml`: `core` plus a `keelson-profiles` component Application (ADR 0004) |
| `all` | Not yet. Fails with a message until a broader scenario exists. |

## Extra checks

`auth_oidc.sh` runs after `make e2e MODULES=core`, on the same cluster (CI runs it as the next step). It upgrades the release with `tests/e2e/scenarios/auth-oidc/values.yaml`: one OIDC connector whose issuer is the Kind API server. The script applies upstream's own `unauthenticated-oidc-viewer` binding (from the upstream cache), so that Dex can read the issuer documents. It waits until Dex runs the new config (the `keelson.io/dex-config` hash) and the `dex` Application is Synced and Healthy, then checks the log of those pods for a `config connector` line and no `Failed to open connector` line. On failure it writes the Dex log, the Deployment, the Application and the events to `.cache/e2e/diagnostics/auth-oidc/`. A Ready Dex pod is not enough: Dex starts even when a connector fails to open. It deletes the test objects and upgrades the release back to the core values at the end.

Set `AUTH_OIDC_ISSUER` to try another issuer. A bad URL makes the script fail at step 5. You can run the script again, because step 3 waits for the pods of the new config hash.

### Groups (`groups.sh`, #66)

`groups.sh` runs after `make e2e MODULES=profiles`, on the same cluster. It needs the `keelson.selfSource` override that `run.sh` sets for that scope.
1. `idp-keycloak.sh` starts upstream's test Keycloak from `.cache/upstream/<tag>/tests/keycloak` (`keycloak.yaml` and `realm.json` only). It adds a throwaway admin with a random password, and uses the admin API to allow the Dex callback and turn off PKCE for the client.
2. The release is upgraded with `tests/e2e/scenarios/groups/values.yaml`: a Dex `oidc` connector to Keycloak, and a profile `keelson-e2e-groups` with `groups: [kubeflow-users]` and another owner.
3. `kubectl auth can-i create pods` is `yes` for `user@example.com` with the group, and `no` without it.
4. m2m: a pod in the namespace (the registry image from `registry.yaml`, pinned by digest) calls itself through its Service. A malformed token must get `401`. A service-account token must not.
5. `groups.py` logs in through Dex and Keycloak. The Workspaces API gives `200`, and the dashboard does not list the namespace (the documented caveat).
6. It adds a second group to the user and logs in again. It prints the Workspaces status for the comma-joined groups header (#28) as a `comma-caveat` JSON line. This step records the result. It does not fail on it.

`groups.py` resolves `kubeflow.example.com` and the Keycloak host to `127.0.0.1` itself, so you don't need to change `/etc/hosts`. On failure it writes diagnostics to `.cache/e2e/diagnostics/groups/`. At the end it deletes the test objects and the test profile, and upgrades the release back to the values it had before.

```sh
make e2e MODULES=profiles && tests/e2e/groups.sh
```

## When it fails

`run.sh` exits non-zero and writes diagnostics to `.cache/e2e/diagnostics/`: Application status, pods that aren't running, events, and Dex, oauth2-proxy and ArgoCD controller logs. For gateway denials (#139) it also writes `istio-pods.txt`, `istiod.log`, `istio-ingressgateway.log` and `gateway-stats-<pod>.txt` (Envoy `rbac` counters; Istio does not expose `jwt_authn` or `ext_authz` filter stats by default). In CI they are uploaded as the `e2e-diagnostics` artifact.

`dashboard.py` retries `GET /api/workgroup/env-info` up to 5 times, 5 seconds apart, but only for `403 RBAC: access denied`. A retry is never silent: it prints a `WARN` line and a GitHub `::warning` annotation, and the final JSON line has `env-info-tries`. If the warning shows in 3 or more runs, open a product issue (see #139); the retry is not the fix. Unit test: `tests/e2e/test_dashboard_retry.py` (run by `make rules`).

## Add a smoke test for a module

1. Write `tests/e2e/<name>.sh`. Start it with `set -euo pipefail`, and `source` `lib.sh` for `log`, `fail`, `py`, `upstream_dir` and `port_forward_gateway`.
2. Set `smokeTest: tests/e2e/<name>.sh` in `charts/keelson/modules/<module>.yaml`. If the module has nothing to test beyond Healthy, use `smokeTest: none` with a comment that gives the reason.

Tests run after every Application is Healthy, in module wave order. A path shared by several modules runs once.

Prefer running upstream's own test from `.cache/upstream/<tag>/tests/` over writing a copy. `dex-login.sh` does this with `dex_login_test.py`. It needs something serving `/` behind the gateway, so the dashboard module wires it (#7): `tests/e2e/dashboard.sh` runs it first, then `dashboard.py`. Without the dashboard, core uses `auth-redirect.sh`. With the dashboard, `auth-redirect.sh` also requires oauth2-proxy's sign-in page on `GET /`.

`auth-redirect.sh` applies a test-only route, `tests/e2e/fixtures/protected-route.yaml`, and deletes it at the end. Core has no workload at `/`, and Envoy skips `ext_authz` for a request that matches no route, so the gateway answers `403 RBAC: access denied` there (#106). The route sends `/keelson-e2e/` to the Dex Service. Dex cannot return oauth2-proxy's sign-in form, so the form on that path proves that `ext_authz` answered. That gives a protected path that `ext_authz` checks.

## Component Applications and the in-cluster registry

A component Application (`keelson-profiles`) pulls this chart from `keelson.selfSource`. The chart under test is not published. So `MODULES=profiles` uses the same in-cluster registry as the root-Application mode (`tests/e2e/registry.yaml`, upstream `registry` image pinned by digest, `lib/root-app.sh`):
1. `e2e_registry_push` starts the registry, packages the chart at an exact pre-release version (`<version>-e2e.<unix-time>.g<commit>`) and pushes it.
2. It creates the ArgoCD repository Secret for the registry. Only the harness makes this Secret. The chart never renders it.
3. The helm mode passes `--set keelson.selfSource.repoURL=… --set keelson.selfSource.targetRevision=…`. The root-Application mode puts the same override in the root Application's values.

The override exists only in the harness. No chart default or golden scenario sets `keelson.selfSource`, and `check_rules.py` is unchanged.

CI runs `profiles` on `main`, nightly (only when the repository variable `NIGHTLY_E2E` is `true`), on manual runs, and on PRs that change the profiles component, the component engine (`source.type: keelson`), the e2e harness or its workflow. Other PRs run `core`.
