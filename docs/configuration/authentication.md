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
  oidcClient:
    secretRef: { name: kubeflow-oidc-client }
  cookie:
    secretRef: { name: oauth2-proxy-cookie }
  dex:
    connectors:
      - type: oidc
        id: corp
        issuer: https://idp.example.com
        secretRef: { name: dex-corp }
```

`environment: production` makes the render fail unless static users are off, at least one
connector is set, and both secretRefs (`auth.oidcClient` and `auth.cookie`) are set.
With static users off, at least one connector is required in every environment.

### Secrets for oauth2-proxy and Dex

Upstream ships fixed secrets: the OIDC client secret (shared by oauth2-proxy and Dex) and the
oauth2-proxy cookie secret. They are the same in every install. Anyone who knows them can forge
session cookies. A production install must not use them.

Make two Secrets with random values. Keelson never creates them.

```sh
CLIENT_SECRET=$(openssl rand -base64 32)
COOKIE_SECRET=$(openssl rand -base64 24 | tr -d '\n' | tr '+/' '-_')   # 32 characters

# the OIDC client: the same Secret in BOTH namespaces
for ns in auth oauth2-proxy; do
  kubectl -n "$ns" create secret generic kubeflow-oidc-client \
    --from-literal=client-id=kubeflow-oidc-authservice \
    --from-literal=client-secret="$CLIENT_SECRET"
done

# the session cookie
kubectl -n oauth2-proxy create secret generic oauth2-proxy-cookie \
  --from-literal=cookie-secret="$COOKIE_SECRET"
```

| Value | Secret | Namespace | Keys |
|---|---|---|---|
| `auth.oidcClient.secretRef.name` | `kubeflow-oidc-client` | `auth` **and** `oauth2-proxy` | `client-id`, `client-secret` |
| `auth.cookie.secretRef.name` | `oauth2-proxy-cookie` | `oauth2-proxy` | `cookie-secret` |

Rules:
- Use any Secret names except `oauth2-proxy` and `dex-oidc-client`. These are the names of upstream's
  generated Secrets, and the render rejects them.
- The client Secret must have the same values in both namespaces. If they differ, the login fails in
  Dex with `invalid_client`. Keelson cannot check this. External Secrets or a Kyverno policy can keep the
  two copies equal.
- The cookie secret must be 16, 24 or 32 bytes long. The command above makes 32 characters.
- Keelson restarts the pods when a Secret *name* changes. It does not restart them when the
  *contents* of a Secret change. Restart them yourself: `kubectl -n oauth2-proxy rollout restart
  deploy/oauth2-proxy` and `kubectl -n auth rollout restart deploy/dex`.

The generated upstream Secrets still exist in the cluster, with the public values. Nothing reads them
once you set the two refs. You can delete them, but Argo CD will make them again.

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

`tenant` is required: a tenant ID (GUID) or a verified domain. `common`, `consumers` and
`organizations` are rejected: they let any Microsoft account log in, and Dex reads no groups for them.
`extraConfig` cannot set `tenant`, `groups` or `useGroupsAsWhitelist`, in any letter case.

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
- `orgs` is required. Without it, any GitHub user could log in. `extraConfig` cannot set `orgs`,
  `org`, `hostName` or `rootCA`, in any letter case. Use `enterprise` for those ([below](#github-enterprise-server)).
- Dex asks for the `read:org` scope. An org owner may need to approve the app for the org.
- Groups come back as `<org>:<team-slug>`, for example `my-org:ml-platform`.

### GitHub Enterprise Server

```yaml
auth:
  dex:
    connectors:
      - type: github
        id: ghe
        secretRef: { name: dex-ghe }
        orgs: [{ name: my-org }]
        enterprise:
          hostName: ghe.example.com           # no scheme, no path; a :port is allowed
          rootCASecretRef: { name: ghe-ca }   # optional; key defaults to ca.crt
```

- Create the OAuth app on the GHE server, with the callback URL `https://<domain>/dex/callback`.
- Leave out `rootCASecretRef` when the server's certificate comes from a public CA. Dex then uses the system CAs.
- For a private CA, make the Secret in `auth` first:

  ```sh
  kubectl -n auth create secret generic ghe-ca --from-file=ca.crt=./ca.pem
  ```

- **Warning:** the Secret is required. If it is missing, the Dex Pod does not start, and **all** logins fail,
  static users too. This is on purpose: a quiet failure of one connector is harder to find.
- Dex reads the CA file only at start. After you change the Secret, restart Dex:
  `kubectl -n auth rollout restart deployment/dex`.

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
