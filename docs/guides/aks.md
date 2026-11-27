# Run Keelson on AKS (production)

This guide takes you from an AKS cluster with ArgoCD to a Keelson install with a real domain,
HTTPS and Entra ID login.

> **Not yet tested on AKS.** Keelson is tested on Kind. The commands and values here come from those
> tests and from the pages this guide links. The manual AKS run in
> [`release-checklist.md`](../release-checklist.md) has not passed yet. This note stays until it does.
> If something differs on your cluster, open an issue.

Some parts are not written yet. See [What is not here yet](#what-is-not-here-yet).

## Before you start

You need:
- An AKS cluster, and `kubectl` access to it.
- ArgoCD on that cluster, version **v3.6.2 or newer** ([support matrix](../support-matrix.md)).
- A hostname you control, for example `kubeflow.example.com`.
- A Microsoft Entra ID tenant where you can register an app and give admin consent.
- Something that serves HTTPS for that hostname. Section 3 says what.

A full Kubeflow install needs about 16 GB of RAM in total ([ADR 0003](../adr/0003-kind-bootstrap-installs-argocd.md)).
Keelson has not tested an AKS node size.

Which Keelson version to install: the first pre-release, `v0.1.0-alpha.1`, is not published yet
([#63](https://github.com/abhishekpcnair/keelson/issues/63)).
Until it is, pin a commit SHA, as [ArgoCD setup](../argocd.md) says. Never use a branch.

## 1. Use your existing ArgoCD

Keelson does not install ArgoCD outside Kind ([ADR 0003](../adr/0003-kind-bootstrap-installs-argocd.md)).
Use the one you have. Keelson never changes your `argocd-cm`, so you apply the health checks once:

```sh
kubectl -n argocd patch configmap argocd-cm --type merge \
  --patch-file hack/argocd/argocd-cm-health.yaml
```

Read the warning in [ArgoCD setup](../argocd.md) first. The `Application` check applies to every
app-of-apps on this ArgoCD, not only Keelson.

Then install Keelson with a root Application. [ArgoCD setup](../argocd.md) has the YAML. Put the values
from section 2 in its `helm.valuesObject`. A plain `helm install` also works, but then nothing
waits for the sync waves.

Do **not** set `platform: kind` on AKS. Leave `platform` at its default, `generic`.

## 2. Production values

Set `environment: production`. The render then fails unless all four of these hold:
- Static users are off. Otherwise Dex keeps upstream's test user (`user@example.com`, password `12341234`).
- At least one Dex connector is set.
- `auth.oidcClient.secretRef` is set.
- `auth.cookie.secretRef` is set.

The last two name Secrets that replace upstream's fixed OIDC client secret and cookie secret, which
are the same in every install. See
[Secrets for oauth2-proxy and Dex](../configuration/authentication.md#secrets-for-oauth2-proxy-and-dex).

This is the whole example. It is the file `tests/golden/aks-entra-external/values.yaml`, which
`make golden-check` renders on every pull request:

```yaml
environment: production
domain: kubeflow.example.com
tls:
  issuer: external
auth:
  staticUsers:
    enabled: false
  oidcClient:
    secretRef:
      name: kubeflow-oidc-client
  cookie:
    secretRef:
      name: oauth2-proxy-cookie
  dex:
    connectors:
      - type: microsoft
        id: entra
        name: Entra ID
        tenant: 00000000-0000-0000-0000-000000000000
        allowedGroups: [ml-vision]
        secretRef:
          name: dex-entra
```

Change these things:
- `domain`: your hostname (section 3).
- `tls.issuer`: `external`, `existing` or `letsencrypt` (section 3).
- `tenant` and `allowedGroups`: your Entra tenant and groups (section 4).
- `connectors[].secretRef.name`: the name of the Secret you create in section 4.
- `auth.oidcClient.secretRef.name` and `auth.cookie.secretRef.name`: two Secrets with random values.
  Create them before ArgoCD syncs, as
  [Authentication](../configuration/authentication.md#secrets-for-oauth2-proxy-and-dex) describes.

## 3. Domain and TLS

Set `domain` to a lowercase hostname without a scheme: `kubeflow.example.com`, not
`https://kubeflow.example.com`. Then the Gateway answers only for that host.

Pick where HTTPS ends. Full details are in [Domain and TLS](../configuration/domain-and-tls.md).

| `tls.issuer` | HTTPS ends | Use it when |
|---|---|---|
| `external` | In front of the cluster. The Gateway stays HTTP. | A service in front of AKS holds the certificate. The example above uses this. |
| `existing` | At Istio, with a Secret you create. HTTP redirects to HTTPS. | You hold the certificate and want the cluster to serve it. |
| `letsencrypt` | At Istio, with a Let's Encrypt certificate that cert-manager gets through Azure DNS. HTTP redirects to HTTPS. | Your domain is in an Azure DNS zone. See [Azure DNS on AKS](../configuration/domain-and-tls.md#azure-dns-on-aks). |

With `external`, an Azure service in front of the cluster serves HTTPS and forwards HTTP to the
`istio-ingressgateway` Service. One option is
[Application Gateway for Containers](https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/overview),
which Microsoft describes as a layer 7 load balancer and ingress service for Kubernetes with TLS termination.
Keelson has not been tested with it.

With `existing`, use these values (the scenario `domain-tls-existing`):

```yaml
domain: kubeflow.example.com
tls:
  issuer: existing
  secretRef:
    name: kubeflow-tls
```

Create a `kubernetes.io/tls` Secret with that name in `istio-system` first. Keelson does not
create it, and `secretRef` takes a name only. Never put certificate data in values.

All three modes make login cookies secure, so a browser login over plain HTTP will not stick.

Point your DNS name at whatever serves the front end (section 5).

## 4. Sign in with Entra ID

Dex sends users to Entra ID through the `microsoft` connector. Full reference:
[Authentication](../configuration/authentication.md#entra-id-recommended).

1. [Register an app](https://learn.microsoft.com/en-us/graph/auth-register-app-v2) in your tenant.
   Add the redirect URI `https://<domain>/dex/callback` (platform: Web), and create a client secret.
2. Add the Microsoft Graph permission `GroupMember.Read.All` and give admin consent.
   Without it, Dex cannot read groups. The
   [permissions reference](https://learn.microsoft.com/en-us/graph/permissions-reference) lists it
   as needing admin consent.
3. Create the Secret in the `auth` namespace. Keelson never creates it, and the client secret
   never appears in values:

   ```sh
   kubectl -n auth create secret generic dex-entra \
     --from-literal=clientID=<client-id> --from-literal=clientSecret=<client-secret>
   ```

   External Secrets and the Azure Key Vault CSI driver also work, as long as the Secret ends up in `auth`.
4. Set `tenant` to your tenant ID or a verified domain. `common`, `consumers` and `organizations`
   are rejected.

### Group names or IDs

The `microsoft` connector returns group **names** by default (`groupNameFormat: name`).
Set `groupNameFormat: id` to get object IDs.

A generic `oidc` connector pointed at Entra ID returns group **object IDs**, not names. That is why
Keelson recommends the `microsoft` connector.

`allowedGroups` limits who can log in. Users who are in more than 1000 groups need
`extraConfig.batchGroupLookups: true`, or the Graph lookup fails at login.

Keelson lowercases emails (`emailToLowercase: true`). Kubeflow compares the email with Profile owners
case-sensitively, so `Alice@Example.com` and `alice@example.com` would be two users otherwise.

Which Entra group gets which Kubeflow profile is in [section 8](#8-groups-to-profiles).

## 5. Expose the ingress gateway

Keelson leaves the `istio-ingressgateway` Service in `istio-system` as `ClusterIP`, as upstream does,
and has no value to change that. You put the front end in place yourself. The Service has these ports:

| Port | Target | Use |
|---|---|---|
| 80 | 8080 | HTTP |
| 443 | 8443 | HTTPS (used by `existing`) |
| 15021 | 15021 | Readiness |

- **`external`:** point your HTTPS service at this Service on port 80.
- **`existing`:** Istio serves HTTPS on 443, so a plain `LoadBalancer` Service works. On AKS, a Service
  of type `LoadBalancer` is exposed through the
  [public Standard Load Balancer](https://learn.microsoft.com/en-us/azure/aks/load-balancer-standard).
  This Service selects the gateway pods:

  ```yaml
  apiVersion: v1
  kind: Service
  metadata:
    name: istio-ingressgateway-lb
    namespace: istio-system
  spec:
    type: LoadBalancer
    selector:
      app: istio-ingressgateway
      istio: ingressgateway
    ports:
      - { name: status-port, port: 15021, targetPort: 15021 }
      - { name: http2, port: 80, targetPort: 8080 }
      - { name: https, port: 443, targetPort: 8443 }
  ```

  You apply it yourself. It is not part of Keelson's output.

Set the health probe of your front end to **port 15021, path `/healthz/ready`**. The Service above
exposes port 15021 for this. Do not probe the Gateway: with a `domain` set, it answers only requests for
that host. How to set a probe on the Azure side is not covered here, and is not yet tested on AKS.

To check without DNS, forward the Service and send the right host:

```sh
kubectl -n istio-system port-forward svc/istio-ingressgateway 8080:80
curl -H 'Host: kubeflow.example.com' http://localhost:8080/
```

With `tls.issuer: existing`, port 80 only redirects. Forward port 443 and use `curl --resolve` instead.
See [Port-forward and health probes](../configuration/domain-and-tls.md#port-forward-and-health-probes).

The dashboard module is on by default and serves `/`. An unauthenticated request is not served the
dashboard: `tests/e2e/auth-redirect.sh` checks that `GET /` is refused or redirected (302, 401 or 403),
and that it never gets `200`.

## 6. Upgrades

Keelson tests each release against one upstream Kubeflow version, the chart's `appVersion`.
To upgrade, move to the next Keelson release:

1. Read the release notes. They list the upstream version and breaking changes.
2. Change `targetRevision` in your root Application to the new release tag.
3. Let ArgoCD sync, then check that everything is healthy:

   ```sh
   kubectl -n argocd get applications.argoproj.io -l app.kubernetes.io/part-of=keelson
   ```

   Every Application should be `Synced` and `Healthy`.

Setting `upstream.manifestsRef` yourself is not tested.

If you turn a module off, ArgoCD deletes its Application but keeps what it deployed
([Modules](../modules/README.md#turning-a-module-off-leaves-its-resources-running)).

Keelson supports the current and the previous upstream release. For the alpha releases, only the current one.
The upgrade from the previous minor release is on the manual AKS checklist and is not yet tested.

## 7. Pipelines database

By default, Pipelines runs its own MySQL pod with upstream's public credentials. Use it for evaluation only.
For production, point Pipelines at your own MySQL server with `database.mode: external`.
The values, the Secret and the grants are in [Pipelines: external MySQL](../modules/pipelines.md#external-mysql).

```yaml
database:
  mode: external
  external:
    host: mysql.example.internal
    secretRef: { name: kfp-db }   # in namespace kubeflow; keys username and password
```

**Azure Database for MySQL is not supported yet.** Its flexible server requires TLS by default
([`require_secure_transport`](https://learn.microsoft.com/azure/mysql/flexible-server/how-to-connect-tls-ssl)),
and at `26.10.0` Kubeflow Pipelines has no setting for a TLS connection to MySQL. This is tracked in
[#146](https://github.com/abhishekpcnair/keelson/issues/146). Don't turn TLS off on a production server to work around it.
Until #146 is done, use a MySQL server that you run without TLS inside your network, or stay on the bundled database for evaluation.

Switching an existing install from bundled to external deletes the bundled data. Read the warning in
[Pipelines](../modules/pipelines.md#external-mysql) first.

PostgreSQL is not in v0.1 ([#40](https://github.com/abhishekpcnair/keelson/issues/40)).

## 8. Groups to profiles

Give an Entra group access to a profile namespace with `profiles[].groups`. With the `microsoft`
connector, use the group **name** (section 4):

```yaml
platform: generic
auth:
  serviceAccountIssuers:
    - issuer: <issuer URL from step 2 below>
      jwksUri: <jwks_uri from step 3 below>
profiles:
  - name: team-vision
    owner: alice@example.com
    groups:
      - name: ml-vision   # the Entra group name, as Dex sends it
        role: edit        # edit (default) or view
```

A profile with `groups` gets a namespace policy that checks Dex tokens and the cluster's service-account tokens.
On AKS, Keelson needs the cluster's OIDC issuer for that, or the render fails:

1. Turn on the [AKS OIDC issuer](https://learn.microsoft.com/azure/aks/use-oidc-issuer) (`az aks update --enable-oidc-issuer`).
2. Read its URL with `az aks show -n <cluster> -g <resource-group> --query oidcIssuerProfile.issuerUrl -o tsv`.
3. Read the `jwks_uri` from `curl -s <issuer URL>.well-known/openid-configuration` (the issuer URL ends with `/`).
4. Put both in `auth.serviceAccountIssuers`, as above. The details are in
   [Profiles: service-account issuers](../configuration/profiles.md#service-account-issuers).

Groups give access to Workspaces and the namespace, but not everything: the dashboard's namespace list
and Pipelines still need `contributors` or `viewers`, and a user in two or more groups may not match.
See [what works and what doesn't](../configuration/profiles.md#what-works-and-what-doesnt-v01).
`kubectl` with AKS Entra integration sees group **object IDs**, not the names Dex sends.

## What is not here yet

These parts are added when the feature they describe is released:

| Part | Status |
|---|---|
| Auth secrets | Done. See [Secrets for oauth2-proxy and Dex](../configuration/authentication.md#secrets-for-oauth2-proxy-and-dex), linked from section 2. |
| Object store | Waits for [#38](https://github.com/abhishekpcnair/keelson/issues/38). |
| Azure Database for MySQL | External MySQL is done (section 7). Azure's TLS requirement waits for [#146](https://github.com/abhishekpcnair/keelson/issues/146). |
| Groups to profiles | Done (section 8). |

Progress is tracked in [#42](https://github.com/abhishekpcnair/keelson/issues/42).
