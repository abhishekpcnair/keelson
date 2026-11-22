# Domain and TLS

Set `domain` to the hostname users open Kubeflow on. Set `tls.issuer` to say where HTTPS ends.

| `tls.issuer` | What Keelson does |
|---|---|
| `none` (default) | HTTP only, as upstream. With a `domain`, the Gateway answers only on that host. |
| `existing` | Istio terminates TLS with your Secret. HTTP redirects to HTTPS. Cookies are secure. |
| `external` | TLS ends in front of the cluster (cloud load balancer, Azure Application Gateway). The Gateway stays HTTP. Cookies are secure. |

`domain` is a hostname without a scheme: `kubeflow.example.com`, not `https://kubeflow.example.com`.

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

## What doesn't change

- The Dex issuer stays the upstream in-cluster URL (`http://dex.auth.svc.cluster.local:5556/dex`).
  Browser logins use relative redirects, so they work on any hostname.
- `selfsigned` and `letsencrypt` issuers are planned (#23).
