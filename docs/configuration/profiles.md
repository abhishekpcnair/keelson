# Profiles

A Kubeflow profile is a namespace that one user owns. Declare profiles in values:

```yaml
profiles:
  - name: team-vision          # namespace name: lowercase DNS-1123 label, at most 63 characters
    owner: alice@example.com   # the email the user logs in with (kubeflow-userid)
    contributors: [bob@example.com]
    viewers: [carol@example.com]
```

Keelson renders one `Profile` (`kubeflow.org/v1`) for each entry, in the `keelson-profiles` Application (wave 10).
The profile controller (`dashboard` module) then creates:
- the namespace;
- the owner's `namespaceAdmin` `RoleBinding`;
- the owner's Istio `AuthorizationPolicy`.

For each contributor and viewer, Keelson renders a `RoleBinding` and an Istio `AuthorizationPolicy` in the profile namespace. They have the exact shape that the dashboard's **Manage contributors** creates (KFAM), so the dashboard lists them.

| Role | Can | ClusterRole |
|---|---|---|
| Owner | Everything in the namespace, and manage contributors in the dashboard | `kubeflow-admin` (profile controller) |
| Contributor | Create and change notebooks, workspaces, pipelines and their resources | `kubeflow-edit` |
| Viewer | Read only | `kubeflow-view` |

## Git is the source of truth
- A contributor that you remove in the dashboard comes back: ArgoCD self-heal restores it. Remove the person from values instead.
- A contributor that you add only in the dashboard stays. Keelson doesn't manage it.
- If you add a person in the dashboard who is already in values, the dashboard shows an error (`AlreadyExists`). The access is already there.
- To change a role, move the email from `contributors` to `viewers` (or back). ArgoCD replaces the objects.

## Rules
- Names are unique.
- Each email has one role per profile: owner, contributor or viewer. The check ignores case.
- Two emails with the same role can't give the same KFAM name. KFAM changes every run of characters other than letters and digits to `-`, so `bob.x@a.com` and `bob-x@a.com` collide when both are contributors, or both are viewers. The render fails. The names end in `-edit` or `-view`, so the same two emails with different roles do not collide.
- Names can't be system namespaces: `kubeflow`, `istio-system`, `auth`, `oauth2-proxy`, `cert-manager`, `argocd.namespace`, or `kube-*`.
- The `dashboard` module must be on.
- Pod Security and extra namespace labels: see [Profile namespaces](profile-namespaces.md).
- Group names are unique in a profile. See [Groups](#groups).

## Groups
Give a whole IdP group access to a profile namespace:

```yaml
profiles:
  - name: team-vision
    owner: alice@example.com
    groups:
      - name: ml-vision      # exactly as the IdP puts it in the groups claim
        role: edit           # edit (default) or view
```

For a profile with `groups`, Keelson renders in the profile namespace:
- one `RoleBinding` for each group (`kind: Group`, ClusterRole `kubeflow-edit` or `kubeflow-view`);
- a `RequestAuthentication` named `keelson-groups`, for the whole namespace. It checks Dex tokens and the cluster's service-account tokens;
- an `AuthorizationPolicy` named `keelson-groups`. It allows requests whose Dex token has one of the groups.

Profiles without `groups` get none of these.

### What works and what doesn't (v0.1)
Groups grant Kubernetes RBAC, Workspaces and workload network access.
The dashboard namespace list and Pipelines still need per-user bindings.

| Works with groups | Needs `contributors` or `viewers` |
|---|---|
| `kubectl` and other Kubernetes API access (RBAC) | The dashboard namespace list and its namespace picker |
| Workspaces (the backend reads the groups header) | **Manage contributors** in the dashboard (KFAM) |
| Requests to workloads in the namespace (Istio) | Pipelines (KFP checks access per user) |

The cause is upstream: KFAM, the dashboard and Pipelines don't read groups at 26.10.0 ([#28](https://github.com/abhishekpcnair/keelson/issues/28)).

A user in two or more groups may reach the Workspaces backend with one joined value, such as `a,b` (#28). Until the e2e check in #66 confirms the behaviour, test Workspaces access for such users.

### Group names
Use the name your connector sends. Dex passes it on unchanged.

| IdP | Example |
|---|---|
| `microsoft` connector (Entra ID) | `ml-vision` (the group name) |
| Entra ID as a generic `oidc` connector | `3f2a…` (the group object ID) |
| `github` connector | `acme:ml-team` (`org:team`) |
| Keycloak | `ml-vision`, or `/parent/ml-vision` when the client's group mapper sends the full path |

Names can't start or end with `*`. Istio reads a `*` there as a wildcard.

### Service-account issuers
The namespace `RequestAuthentication` rejects tokens from issuers it doesn't list. So it must also list the issuer of the cluster's service-account tokens, or machine-to-machine requests get `401`.
- `platform: kind`: Keelson uses the two Kind issuers. You don't need to set anything.
- `platform: generic`: set `auth.serviceAccountIssuers` when any profile has `groups`. The render fails without it.

Find the issuer:

```sh
kubectl get --raw /.well-known/openid-configuration
```

Then set it:

```yaml
auth:
  serviceAccountIssuers:
    - issuer: https://<the "issuer" field from the command above>
      # jwksUri: https://...   # optional; default: the issuer's OIDC discovery
```

## Remove a profile
Removing an entry does **not** delete the namespace or its data. `Profile`s have `Prune=false`, so ArgoCD shows them as needing a prune and keeps them.
With `profiles: []`, Keelson renders no `keelson-profiles` Application. ArgoCD deletes that Application without a cascade, so the `Profile`s stay.

To delete a profile and **all its data** (workspaces, PVCs, pipelines), do it yourself:

```sh
kubectl delete profile team-vision
```

## Where the chart comes from
The `keelson-profiles` Application pulls this chart from `keelson.selfSource`. See [Keelson components](../modules/README.md#keelson-components).
