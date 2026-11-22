# Authentication

Kubeflow logins go through oauth2-proxy and Dex, as upstream ships them.
Dex brokers to your identity provider (IdP) through **connectors**. It is not a user database.

## Defaults: the static user

Out of the box, upstream's static user is on: `user@example.com`, password `12341234`.
Use it on Kind or for dev only. `helm install` prints a warning while it's on.

## Production

```yaml
environment: production
auth:
  staticUsers:
    enabled: false
  dex:
    connectors:
      - type: oidc
        id: corp
        issuer: https://idp.example.com
        secretRef: { name: dex-corp }
```

`environment: production` makes the render fail unless static users are off and at least one
connector is set. With static users off, at least one connector is required in every environment.

Dex reads its config only at start. Keelson restarts Dex when the config changes. If you remove all
connectors and turn static users back on, Keelson stops patching Dex. Then restart it yourself:
`kubectl -n auth rollout restart deploy/dex`.

## OIDC connector

```yaml
domain: kubeflow.example.com
auth:
  dex:
    connectors:
      - type: oidc
        id: corp            # lowercase, digits, dashes; unique
        name: Corp SSO      # login button text (default: id)
        issuer: https://idp.example.com/realms/corp
        secretRef:
          name: dex-corp    # keys clientID and clientSecret by default
        # optional:
        # scopes: [openid, profile, email, groups]   # the default; drop groups for IdPs
        #                                             # that reject it (Google: invalid_scope)
        # groupsClaim: groups                         # claim Dex reads groups from
```

Every connector needs `domain`. Dex sends the browser back to `https://<domain>/dex/callback`
(`http://` when `tls.issuer: none`).

### Register the app in your IdP

- Redirect URI: `https://<domain>/dex/callback`
- Scopes: `openid profile email`, plus `groups` if your IdP has it

### Create the Secret

Create it in the `auth` namespace. Keelson never creates it, and the client secret never
appears in values or rendered output.

```sh
kubectl -n auth create secret generic dex-corp \
  --from-literal=clientID=<client-id> --from-literal=clientSecret=<client-secret>
```

External Secrets or the Azure Key Vault CSI driver work too, as long as the Secret ends up in `auth`.
Use `secretRef.clientIDKey` and `secretRef.clientSecretKey` if your keys have other names.

### Groups

Dex reads groups from the claim in `groupsClaim`. With **Entra ID** as a generic OIDC IdP, that
claim holds group **object IDs**, not names. Use the IDs wherever you list groups, or use the
[`microsoft` connector](#entra-id-recommended) (recommended), which returns group names.

## Entra ID (recommended)

```yaml
domain: kubeflow.example.com
auth:
  dex:
    connectors:
      - type: microsoft
        id: entra
        name: Entra ID
        tenant: 00000000-0000-0000-0000-000000000000   # tenant ID or verified domain
        allowedGroups: [ml-vision]                      # optional: only members may log in
        secretRef: { name: dex-entra }
```

In the Entra app registration:
- Add the redirect URI `https://<domain>/dex/callback` (platform: Web).
- Grant the Microsoft Graph permission `GroupMember.Read.All` and give admin consent. Without it, Dex can't read groups.
- Create a client secret and put it in the `dex-entra` Secret in `auth`, as above.

`tenant` is required. `common`, `consumers` and `organizations` are rejected: they let any
Microsoft account log in, and Dex reads no groups for them.

Groups come back as **names** (`groupNameFormat: name`). Set `groupNameFormat: id` to get object IDs.
Set `onlySecurityGroups: true` to skip Microsoft 365 groups.

Keelson sets `emailToLowercase: true`, unlike Dex's default. Kubeflow uses the email as the user ID
and compares it case-sensitively with Profile owners, so `Alice@Example.com` and `alice@example.com`
would be two users. Set it to `false` only if you know every email is already lowercase.

Users in more than 1000 groups make the Graph lookup fail at login. Turn on batching:

```yaml
        extraConfig:
          batchGroupLookups: true
```

## GitHub

```yaml
domain: kubeflow.example.com
auth:
  dex:
    connectors:
      - type: github
        id: github
        secretRef: { name: dex-github }
        orgs:
          - name: my-org
            teams: [ml-platform]   # optional: only these teams may log in
        # teamNameField: slug      # name | slug | both (Keelson default: slug)
```

- Create a GitHub OAuth app with the callback URL `https://<domain>/dex/callback`.
- `orgs` is required. Without it, any GitHub user could log in.
- Dex asks for the `read:org` scope. An org owner may need to approve the app for the org.
- Groups come back as `<org>:<team-slug>`, for example `my-org:ml-platform`.
- GitHub Enterprise Server (`hostName`, `rootCA`) is not supported yet (#46).

### Extra Dex options (unsupported)

`extraConfig` is merged last into the connector's Dex `config`. Keys that look like secrets
(`secret`, `password`, `token`, `key`) are rejected. This also rejects some real Dex options, for
example `userIDKey` and `userNameKey`. The error is `at '': 'not' failed`.

```yaml
        extraConfig:
          insecureSkipVerify: true   # test IdPs with self-signed certs only
```

## How it works

Dex keeps its whole config in one string, so Keelson replaces upstream's `config.yaml` with the
same content plus your connectors. Client IDs and secrets reach Dex as environment variables
from your Secret. The Dex issuer stays the in-cluster URL. `make kustomize-check` fails if the
upstream keys Keelson re-states ever drift from the pinned release.
