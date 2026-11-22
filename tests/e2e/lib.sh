#!/usr/bin/env bash
# Shared helpers for the e2e harness. Source this file; don't run it.
# shellcheck disable=SC2034  # variables are used by the scripts that source this file

E2E_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
E2E_CACHE="$E2E_ROOT/.cache/e2e"
E2E_VENV="$E2E_CACHE/venv"
GATEWAY_PORT="${GATEWAY_PORT:-8080}"

log()  { printf '==> %s\n' "$*"; }
fail() { printf 'e2e: FAIL: %s\n' "$*" >&2; exit 1; }

# Python with PyYAML and requests, from the harness venv when run.sh created it.
py() {
  if [[ -x "$E2E_VENV/bin/python" ]]; then "$E2E_VENV/bin/python" "$@"; else python3 "$@"; fi
}

# .cache/upstream/<manifestsRef>, read from the chart values the same way the Makefile reads it.
upstream_dir() {
  local tag
  tag="$(py -c "import yaml,sys;print(yaml.safe_load(open(sys.argv[1]))['upstream']['manifestsRef'])" \
    "$E2E_ROOT/charts/keelson/values.yaml")" || fail "could not read upstream.manifestsRef"
  [[ -d "$E2E_ROOT/.cache/upstream/$tag" ]] || fail ".cache/upstream/$tag missing; run 'make upstream-cache'"
  printf '%s\n' "$E2E_ROOT/.cache/upstream/$tag"
}

# Forward the Istio ingress gateway to localhost:$GATEWAY_PORT, as upstream's
# tests/port_forward_gateway.sh does. The forward is stopped when the calling shell exits.
port_forward_gateway() {
  local svc i
  svc="$(kubectl get svc -n istio-system -l app=istio-ingressgateway -o jsonpath='{.items[0].metadata.name}')" \
    || fail "no istio-ingressgateway Service in istio-system"
  [[ -n "$svc" ]] || fail "no istio-ingressgateway Service in istio-system"
  mkdir -p "$E2E_CACHE"
  kubectl port-forward -n istio-system "svc/$svc" "$GATEWAY_PORT:80" >"$E2E_CACHE/port-forward.log" 2>&1 &
  E2E_PF_PID=$!
  trap 'kill "$E2E_PF_PID" 2>/dev/null || true' EXIT
  for i in $(seq 1 30); do
    if curl -s -o /dev/null "http://localhost:$GATEWAY_PORT/"; then return 0; fi
    kill -0 "$E2E_PF_PID" 2>/dev/null || fail "port-forward exited: $(cat "$E2E_CACHE/port-forward.log")"
    sleep 2
  done
  fail "gateway did not answer on localhost:$GATEWAY_PORT after 60s"
}

# --- In-cluster OCI registry for component Applications (ADR 0004 point 8, #129) ---------
# A component Application pulls this chart from keelson.selfSource. The chart under test is
# not published, so the harness serves it from a registry inside the cluster. Test tooling
# only: no chart template or module names this image, and it is not in any AppProject default.
E2E_REGISTRY_NS=keelson-e2e
# Upstream docker.io/library/registry (distribution): exact version and index digest. Bump both
# together; get the digest from the registry API (Docker-Content-Digest of the multi-arch index).
E2E_REGISTRY_IMAGE="docker.io/library/registry:3.1.2@sha256:82f6ff4a7f982960c8aa51617fea3aabc485df6e55cce80d22deb1de36f1bc3c"
# ArgoCD's repo-server reaches the registry by Service DNS. Helm OCI form: no oci:// scheme.
E2E_REGISTRY_REPO="registry.${E2E_REGISTRY_NS}.svc.cluster.local:5000/charts"
# An exact SemVer pre-release, so ArgoCD treats it as a pin (not a range) and R2 stays strict.
E2E_CHART_VERSION="0.0.0-e2e.${GITHUB_RUN_ID:-local}"

# Start the registry (Deployment + Service) and wait until it is ready.
start_e2e_registry() {
  log "Starting the e2e OCI registry ($E2E_REGISTRY_IMAGE)"
  kubectl apply -f - >/dev/null <<EOF2 || fail "could not apply the e2e registry"
apiVersion: v1
kind: Namespace
metadata: { name: $E2E_REGISTRY_NS }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: registry, namespace: $E2E_REGISTRY_NS }
spec:
  replicas: 1
  selector: { matchLabels: { app: registry } }
  template:
    metadata: { labels: { app: registry } }
    spec:
      containers:
        - name: registry
          image: $E2E_REGISTRY_IMAGE
          ports: [{ containerPort: 5000 }]
          readinessProbe: { httpGet: { path: /v2/, port: 5000 } }
---
apiVersion: v1
kind: Service
metadata: { name: registry, namespace: $E2E_REGISTRY_NS }
spec:
  selector: { app: registry }
  ports: [{ port: 5000, targetPort: 5000 }]
EOF2
  kubectl -n "$E2E_REGISTRY_NS" rollout status deployment/registry --timeout=180s >/dev/null \
    || fail "the e2e registry did not become ready"
}

# Package the chart under test at $E2E_CHART_VERSION and push it to the registry.
push_e2e_chart() {
  local dir pf i
  dir="$(mktemp -d)"
  helm package "$E2E_ROOT/charts/keelson" --version "$E2E_CHART_VERSION" -d "$dir" >/dev/null \
    || fail "helm package failed"
  mkdir -p "$E2E_CACHE"
  kubectl -n "$E2E_REGISTRY_NS" port-forward svc/registry 5000:5000 >"$E2E_CACHE/registry-pf.log" 2>&1 &
  pf=$!
  for i in $(seq 1 30); do
    curl -fs -o /dev/null http://localhost:5000/v2/ && break
    kill -0 "$pf" 2>/dev/null || fail "registry port-forward exited: $(cat "$E2E_CACHE/registry-pf.log")"
    sleep 1
  done
  helm push "$dir/keelson-$E2E_CHART_VERSION.tgz" oci://localhost:5000/charts --plain-http >/dev/null \
    || { kill "$pf" 2>/dev/null || true; fail "helm push to the e2e registry failed"; }
  kill "$pf" 2>/dev/null || true
  rm -rf "$dir"
  log "Pushed keelson $E2E_CHART_VERSION to $E2E_REGISTRY_REPO"
}

# Tell ArgoCD about the registry. The repository Secret (insecureOCIForceHttp) is a test-only
# object made here; the chart never renders it and no values key or doc shows it (ADR 0004 point 8).
register_e2e_registry() {
  local argocd_ns="$1"
  kubectl apply -f - >/dev/null <<EOF2 || fail "could not register the e2e registry in ArgoCD"
apiVersion: v1
kind: Secret
metadata:
  name: keelson-e2e-registry
  namespace: $argocd_ns
  labels: { argocd.argoproj.io/secret-type: repository }
stringData:
  type: helm
  name: keelson-e2e-registry
  url: $E2E_REGISTRY_REPO
  enableOCI: "true"
  insecureOCIForceHttp: "true"
EOF2
}
