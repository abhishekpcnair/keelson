# Profiles

A Kubeflow profile is a namespace that one user owns. Declare profiles in values:

```yaml
profiles:
  - name: team-vision          # namespace name: lowercase DNS-1123 label, at most 63 characters
    owner: alice@example.com   # the email the user logs in with (kubeflow-userid)
```

Keelson renders one `Profile` (`kubeflow.org/v1`) for each entry, in the `keelson-profiles` Application (wave 10).
The profile controller (`dashboard` module) then creates:
- the namespace;
- the owner's `namespaceAdmin` `RoleBinding`;
- the owner's Istio `AuthorizationPolicy`.

## Rules
- Names are unique.
- Names can't be system namespaces: `kubeflow`, `istio-system`, `auth`, `oauth2-proxy`, `cert-manager`, `argocd.namespace`, or `kube-*`.
- The `dashboard` module must be on.
- Pod Security and extra namespace labels: see [Profile namespaces](profile-namespaces.md).
- `groups` is not supported yet. See [#28](https://github.com/abhishekpcnair/keelson/issues/28).
- Contributors and viewers come in a later release (#9).

## Remove a profile
Removing an entry does **not** delete the namespace or its data. `Profile`s have `Prune=false`, so ArgoCD shows them as needing a prune and keeps them.
With `profiles: []`, Keelson renders no `keelson-profiles` Application. ArgoCD deletes that Application without a cascade, so the `Profile`s stay.

To delete a profile and **all its data** (workspaces, PVCs, pipelines), do it yourself:

```sh
kubectl delete profile team-vision
```

## Where the chart comes from
The `keelson-profiles` Application pulls this chart from `keelson.selfSource`. See [Keelson components](../modules/README.md#keelson-components).
