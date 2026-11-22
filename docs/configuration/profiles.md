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
- `groups` is not supported yet. See [#28](https://github.com/abhishekpcnair/keelson/issues/28).

## Remove a profile
Removing an entry does **not** delete the namespace or its data. `Profile`s have `Prune=false`, so ArgoCD shows them as needing a prune and keeps them.
With `profiles: []`, Keelson renders no `keelson-profiles` Application. ArgoCD deletes that Application without a cascade, so the `Profile`s stay.

To delete a profile and **all its data** (workspaces, PVCs, pipelines), do it yourself:

```sh
kubectl delete profile team-vision
```

## Where the chart comes from
The `keelson-profiles` Application pulls this chart from `keelson.selfSource`. See [Keelson components](../modules/README.md#keelson-components).
