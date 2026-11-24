# ADR 0006: Kyverno copies the Dex client Secret between auth and oauth2-proxy

- Status: proposed
- Date: 2026-11-23

## Context
- `auth.oidcClient.secretRef` names one Secret that must exist in two namespaces: `auth` (Dex) and `oauth2-proxy`. The two copies must be equal (#27, `docs/configuration/authentication.md`).
- Keelson cannot check this. If the copies differ, the login fails in Dex with `invalid_client`.
- Today the user makes both copies. #114 asks for a Keelson-owned Kyverno policy that keeps them equal.
- Design §9 lists the uses of Kyverno. After the rescope of #11, the one v0.1 use is the copy of object-store credentials (#67). The oidc client copy is another use. Design §9 does not list it.
- Design §14 says that Keelson handles Secrets only through `secretRef`. A policy that reads a Secret in `auth` and writes one in `oauth2-proxy` changes who can touch the credential that protects every login.
- Facts about Kyverno, from the approved plan of #67:
  - The default background controller role cannot write Secrets.
  - The chart value `backgroundController.rbac.clusterRole.extraResources` adds that right. It is a cluster-wide `ClusterRole`.
- Facts about Kubernetes RBAC: `resourceNames` limits `get`, `update`, `patch` and `delete`. It cannot limit `create`, because the name of a new object is not known when the request is checked.

## Options
| Option | Effect |
|---|---|
| A. The user makes both copies. | No new access. No new use of Kyverno. The user can make an error. |
| B. The user keeps the copies equal with External Secrets. | No new access in Keelson. Needs a separate tool, and the docs show one example. |
| C. A Kyverno `ClusterPolicy`: `generate` with `clone` and `synchronize: true`, from `auth` to `oauth2-proxy`. | One source Secret. The copy follows every change. Gives Kyverno read access in `auth` and write access in `oauth2-proxy`. |
| D. A Keelson Job or controller that copies the Secret. | Not allowed. It is a workload and it needs an image (hard rules 1 and 2, ADR 0004). |
| E. One Secret in one namespace. | Not possible. A `secretKeyRef` cannot name a Secret in another namespace, and upstream fixes the two namespaces. |

## Decision
1. **v0.1 does not ship option C.** Options A and B stay. The docs of #27 say that the user makes both copies, and they recommend External Secrets. This is the decision of the Advisor on #114.
2. **Option C is allowed after v0.1, only under all of these conditions:**
   1. It is opt-in and off by default. `policy.kyverno` must also be on (#67).
   2. It is a Keelson-owned component (ADR 0004). The policy copies one Secret by name. It has no wildcard.
   3. The write right is a `Role` and `RoleBinding` in namespace `oauth2-proxy` only. The read right is a `Role` in `auth` with `resourceNames` set to the Secret name. Keelson does not use the cluster-wide `extraResources` value for this.
   4. A test on Kind shows that Kyverno can clone and synchronize with only these rights. If it needs more (for example, a cluster-wide `list` or `watch` on Secrets), this ADR is not valid for option C, and a new decision is needed.
   5. The docs state the new access in plain words, and state that the user can still use options A and B.
3. This ADR does not change design §9 or §14. The implementation PR changes them when option C ships.

## Consequences (including the effect on upstream bumps)
- **v0.1:** no change in the chart. The login can still fail with `invalid_client` if the user makes unequal copies. The docs name that symptom.
- **Security, when option C ships:**
  - A Kyverno background controller that is compromised can write Secrets in `oauth2-proxy`. These Secrets include the cookie Secret and the client Secret. With them, an attacker can forge sessions or act as the Dex client.
  - Kyverno already holds wide powers. The new right is smaller when it is a namespaced `Role`, but it is still a new right on the login credential.
  - `create` cannot be limited by name (see Context). So the right to write in `oauth2-proxy` covers every Secret name in that namespace.
- **Upstream bumps:**
  - A Kyverno chart bump needs the same two-minor CI as #67.
  - A change of the Secret names in the upstream Dex or oauth2-proxy base can break the policy. `make kustomize-check` and the schema name pattern (#120) already watch those names.
- **#114:** stays open. After this ADR is accepted, the plan of #114 is checked against the conditions above and sent for approval again.
