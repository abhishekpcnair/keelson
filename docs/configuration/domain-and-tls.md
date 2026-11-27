# Domain and TLS

Set `domain` to the hostname users open Kubeflow on. Set `tls.issuer` to say where HTTPS ends.

| `tls.issuer` | What Keelson does |
|---|---|
| `none` (default) | HTTP only, as upstream. With a `domain`, the Gateway answers only on that host. |
| `existing` | Istio terminates TLS with your Secret. HTTP redirects to HTTPS. Cookies are secure. |
| `external` | TLS ends in front of the cluster (cloud load balancer, Azure Application Gateway). The Gateway stays HTTP. Cookies are secure. |
| `selfsigned` | Keelson asks cert-manager for a self-signed certificate. Istio terminates TLS with it. HTTP redirects to HTTPS. Cookies are secure. |

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

With `tls.issuer: existing` or `selfsigned`, port 80 only redirects, so use 443. Add `-k` if the certificate
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

Keelson renders a `keelson-tls` Application (wave -85, after `cert-manager-kubeflow`).
It holds one cert-manager `Certificate` in `istio-system`, for `domain` only.
Upstream's ClusterIssuer `kubeflow-self-signing-issuer` signs it.
cert-manager writes the certificate to the Secret `keelson-tls`, and the Gateway serves it.

Browsers don't trust a self-signed certificate. Use it for tests and private networks.
`curl` needs `-k`.

Keelson owns the Secret name `keelson-tls`. Don't use `keelson-tls` as the `secretRef.name`
of an `existing` Secret. The schema can't check this.

When you switch from `selfsigned` to another issuer, the `keelson-tls` Application goes away,
but ArgoCD keeps the `Certificate` and the Secret. Delete them yourself:

```sh
kubectl -n istio-system delete certificate keelson-tls
kubectl -n istio-system delete secret keelson-tls
```

## What doesn't change

- The Dex issuer stays the upstream in-cluster URL (`http://dex.auth.svc.cluster.local:5556/dex`).
  Browser logins use relative redirects, so they work on any hostname.
- A `letsencrypt` issuer is planned (#23, part 2).
