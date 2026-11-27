# Domain and TLS

Set `domain` to the hostname users open Kubeflow on. Set `tls.issuer` to say where HTTPS ends.

| `tls.issuer` | What Keelson does |
|---|---|
| `none` (default) | HTTP only, as upstream. With a `domain`, the Gateway answers only on that host. |
| `existing` | Istio terminates TLS with your Secret. HTTP redirects to HTTPS. Cookies are secure. |
| `external` | TLS ends in front of the cluster (cloud load balancer, Azure Application Gateway). The Gateway stays HTTP. Cookies are secure. |
| `selfsigned` | Keelson asks cert-manager for a self-signed certificate. Istio terminates TLS with it. HTTP redirects to HTTPS. Cookies are secure. |
| `letsencrypt` | Keelson asks cert-manager for a Let's Encrypt certificate (DNS-01, Azure DNS). Istio terminates TLS with it. HTTP redirects to HTTPS. Cookies are secure. |

`domain` is a hostname without a scheme: `kubeflow.example.com`, not `https://kubeflow.example.com`.
Use lowercase letters only. `Kubeflow.Example.com` fails the render.

## Port-forward and health probes

With a `domain`, the Gateway answers only requests whose `Host` is that domain.
A plain `kubectl port-forward svc/istio-ingressgateway -n istio-system 8080:80` and
`http://localhost:8080` then give a 404 (or, with `existing`, a redirect to `https://<domain>`).
Send the right host instead:

```sh
kubectl -n istio-system port-forward svc/istio-ingressgateway 8080:80
curl -H 'Host: kubeflow.example.com' http://localhost:8080/
```

With `tls.issuer: existing`, `selfsigned` or `letsencrypt`, port 80 only redirects, so use 443. Add `-k` if the certificate
is self-signed or from a private CA:

```sh
kubectl -n istio-system port-forward svc/istio-ingressgateway 8443:443
curl --resolve kubeflow.example.com:8443:127.0.0.1 https://kubeflow.example.com:8443/
```

With any issuer other than `none`, login cookies are secure, so a browser login over a plain-HTTP
port-forward won't stick.

Load balancer health probes have the same problem. Point them at the ingress gateway's
readiness endpoint, port `15021`, path `/healthz/ready`, not at the Gateway.

## Kind and local testing

You need none of this. Leave `domain` empty and `tls.issuer: none`.
The Gateway then accepts any host over HTTP, and you use `kubectl port-forward`.

## `none`: HTTP on your own hostname

```yaml
domain: kubeflow.internal.example.com
```

Upstream warns that plain HTTP on a hostname other than `localhost` breaks web apps that need
secure cookies. Use this only on a trusted network.

## `existing`: Istio terminates TLS

```yaml
domain: kubeflow.example.com
tls:
  issuer: existing
  secretRef:
    name: kubeflow-tls
```

Create a `kubernetes.io/tls` Secret named `kubeflow-tls` in `istio-system` first.
Keelson doesn't create it. cert-manager, External Secrets or `kubectl create secret tls` all work:

```sh
kubectl -n istio-system create secret tls kubeflow-tls --cert=tls.crt --key=tls.key
```

`secretRef` takes a name only. Never put certificate or key data in values.

## `external`: TLS in front of the cluster

```yaml
domain: kubeflow.example.com
tls:
  issuer: external
```

Your load balancer serves HTTPS and forwards HTTP to the `istio-ingressgateway` Service.
How you expose that Service (LoadBalancer, Ingress, Application Gateway) depends on your platform.

## `selfsigned`: a certificate from cert-manager

```yaml
domain: kubeflow.example.com
tls:
  issuer: selfsigned
```

Keelson renders a `keelson-tls` Application (wave -55, after `istio-namespace` and just before the Gateway).
It holds one cert-manager `Certificate` in `istio-system`, for `domain` only.
Upstream's ClusterIssuer `kubeflow-self-signing-issuer` signs it.
cert-manager writes the certificate to the Secret `keelson-tls`, and the Gateway serves it.

Browsers don't trust a self-signed certificate. Use it for tests and private networks.
`curl` needs `-k`.

`keelson-tls` is a component Application: it pulls this chart from `keelson.selfSource`.
The default works only for a published release. For a git checkout, a fork or a mirror,
set `keelson.selfSource` ([Keelson components](../modules/README.md#keelson-components)).

Keelson owns the Secret name `keelson-tls`. The schema rejects `keelson-tls` as the `secretRef.name`
of an `existing` Secret. The render also fails if you turn off the `keelson-tls` module with
`selfsigned` or `letsencrypt`. To bring your own Secret, use `existing`.

When you switch from `selfsigned` or `letsencrypt` to another issuer, the `keelson-tls` Application goes away,
but ArgoCD keeps what it made. Delete it yourself:

```sh
kubectl -n istio-system delete certificate keelson-tls
kubectl -n istio-system delete secret keelson-tls
# letsencrypt only: the ClusterIssuer and the ACME account key, one of each per server you used
kubectl delete clusterissuer keelson-letsencrypt-staging keelson-letsencrypt-production --ignore-not-found
kubectl -n cert-manager delete secret keelson-letsencrypt-staging keelson-letsencrypt-production --ignore-not-found
```

## `letsencrypt`: a certificate from Let's Encrypt

```yaml
domain: kubeflow.example.com
tls:
  issuer: letsencrypt
  acme:
    email: platform-team@example.com
    server: staging
    dns01:
      azureDNS:
        subscriptionID: "<subscription-id>"
        resourceGroupName: "<dns-zone-resource-group>"
        hostedZoneName: example.com
        managedIdentity:
          clientID: "<client-id>"
```

The `keelson-tls` Application then holds two resources:
- a cert-manager `ClusterIssuer` named `keelson-letsencrypt-staging` or `keelson-letsencrypt-production`,
  for the ACME server in `acme.server`;
- the `Certificate` for `domain`, issued by that ClusterIssuer into the Secret `keelson-tls`.

cert-manager proves that you own `domain` with a DNS-01 challenge. It writes a TXT record into
your Azure DNS zone. The cluster needs no public port 80, so this works behind any load balancer.
v0.1 supports Azure DNS only. HTTP-01 and other DNS providers are follow-ups.

`acme.email` is the contact of the ACME account. cert-manager creates the account key in the
Secret `keelson-letsencrypt-staging` or `keelson-letsencrypt-production` in the `cert-manager`
namespace. You never put a key in values.

### A failing issuance holds back the install

Under a root Application, ArgoCD waits until each wave is Healthy before it starts the next one.
The `keelson-tls` Application is Healthy only when the `Certificate` is Ready. If cert-manager
can't solve the challenge, for example because the identity has no role on the DNS zone, the
Application stays Progressing or Degraded. Wave -55 holds the Gateway (`kubeflow-istio-resources`)
and every later module. cert-manager, Istio, Dex and oauth2-proxy still come up.

Find the cause:

```sh
kubectl -n istio-system describe certificate keelson-tls
kubectl -n istio-system get certificaterequests,orders.acme.cert-manager.io,challenges.acme.cert-manager.io
kubectl -n istio-system describe challenges.acme.cert-manager.io
kubectl -n cert-manager logs -l app.kubernetes.io/component=controller --tail=100
```

Fix the role or the values. cert-manager retries on its own, and the install goes on.

### Azure DNS on AKS

The identity that cert-manager uses must be allowed to change the DNS zone.

1. Pick the identity. The simplest is the AKS kubelet identity:

   ```sh
   az aks show -g <cluster-resource-group> -n <cluster> \
     --query identityProfile.kubeletidentity -o json
   ```

   Note its `clientId` and `objectId`. Every pod on the nodes can use this identity,
   so give it access to the DNS zone only.
2. Let it change the zone:

   ```sh
   zone_id="$(az network dns zone show -g <dns-zone-resource-group> -n example.com --query id -o tsv)"
   az role assignment create --role "DNS Zone Contributor" --assignee-object-id <objectId> \
     --assignee-principal-type ServicePrincipal --scope "$zone_id"
   ```
3. Set `managedIdentity.clientID` to the `clientId`.

Workload identity also needs the label `azure.workload.identity/use: "true"` on the cert-manager pods.
Keelson doesn't set it yet, so use the kubelet identity or a service principal.

With a service principal, set `clientID`, `tenantID` and `clientSecretRef` instead of `managedIdentity`.
Create the Secret in the `cert-manager` namespace. The default key is `client-secret`:

```sh
kubectl -n cert-manager create secret generic azuredns-sp --from-literal=client-secret=<secret>
```

```yaml
      azureDNS:
        subscriptionID: "<subscription-id>"
        resourceGroupName: "<dns-zone-resource-group>"
        hostedZoneName: example.com
        clientID: "<app-id>"
        tenantID: "<tenant-id>"
        clientSecretRef:
          name: azuredns-sp
```

### From staging to production

`acme.server` defaults to `staging`. Staging certificates are not trusted by browsers, but staging
has high rate limits. Start there, and wait until the `Certificate` is Ready:

```sh
kubectl -n istio-system get certificate keelson-tls
```

Then set `acme.server: production`. The `Certificate` then points at the ClusterIssuer
`keelson-letsencrypt-production`, and cert-manager issues a trusted certificate by itself.
The staging ClusterIssuer and its account Secret stay. Delete them when you no longer need them:

```sh
kubectl delete clusterissuer keelson-letsencrypt-staging
kubectl -n cert-manager delete secret keelson-letsencrypt-staging
```

## What doesn't change

- The Dex issuer stays the upstream in-cluster URL (`http://dex.auth.svc.cluster.local:5556/dex`).
  Browser logins use relative redirects, so they work on any hostname.
