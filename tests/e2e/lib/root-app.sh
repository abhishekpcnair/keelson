#!/usr/bin/env bash
# Root-Application install mode for tests/e2e/run.sh (#22). Source this file; don't run it.
# Runs on main and nightly (E2E_INSTALL=root-app). ArgoCD pulls the chart under test from an
# in-cluster OCI registry (ADR 0004 point 8), so the sync waves order the install.
# Needs: log, fail, py, kd, kubectl, helm, ARGOCD_NS, E2E_ROOT, E2E_CACHE, CHART, SCENARIO.

E2E_REG_PORT="${E2E_REG_PORT:-5555}"
E2E_REG_REPO="registry.e2e-registry.svc:5000/charts"

# root_app_install: push the chart under test, register the registry with ArgoCD, apply the root.
root_app_install() {
  kubectl apply -f "$E2E_ROOT/tests/e2e/registry.yaml" >/dev/null || fail "could not apply tests/e2e/registry.yaml"
  kubectl -n e2e-registry rollout status deployment/registry --timeout=180s >/dev/null \
    || fail "the e2e registry did not roll out"

  local base sha ver pkg tgz pf
  base="$(py -c "import yaml;print(yaml.safe_load(open('$CHART/Chart.yaml'))['version'])")"
  sha="$(git -C "$E2E_ROOT" rev-parse --short=8 HEAD)"
  ver="$base-e2e.$sha"   # unique per commit, so no chart version is reused (R2 needs an exact version)
  pkg="$E2E_CACHE/root-app"
  mkdir -p "$pkg"
  helm package "$CHART" --version "$ver" -d "$pkg" >/dev/null || fail "helm package failed"
  tgz="$pkg/keelson-$ver.tgz"

  # Push through a port-forward. The forward lives only for this push.
  kubectl -n e2e-registry port-forward "svc/registry" "$E2E_REG_PORT:5000" >"$pkg/port-forward.log" 2>&1 &
  pf=$!
  for _ in $(seq 1 30); do
    curl -fsS -o /dev/null "http://localhost:$E2E_REG_PORT/v2/" && break
    sleep 1
  done
  if ! helm push "$tgz" "oci://localhost:$E2E_REG_PORT/charts" --plain-http >/dev/null; then
    kill "$pf" 2>/dev/null || true
    fail "helm push to the e2e registry failed"
  fi
  kill "$pf" 2>/dev/null || true
  log "Pushed keelson $ver to the e2e registry"

  # Test-only repository Secret: ArgoCD reads the in-cluster registry over plain HTTP.
  kubectl apply -f - >/dev/null <<EOS || fail "could not create the e2e registry repository Secret"
apiVersion: v1
kind: Secret
metadata:
  name: e2e-registry-repo
  namespace: $ARGOCD_NS
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: helm
  name: e2e-registry
  url: $E2E_REG_REPO
  enableOCI: "true"
  insecureOCIForceHttp: "true"
EOS

  # The root Application renders the chart under test with the same values as the helm mode.
  py - "$SCENARIO" "$ARGOCD_NS" "$ver" <<'PYEOF' | kubectl apply -f - >/dev/null || fail "could not apply the root Application"
import json, sys, yaml
scenario, ns, ver = sys.argv[1], sys.argv[2], sys.argv[3]
values = yaml.safe_load(open(scenario)) or {}
root = {
    "apiVersion": "argoproj.io/v1alpha1",
    "kind": "Application",
    "metadata": {"name": "keelson-root", "namespace": ns},
    "spec": {
        "project": "default",
        "source": {
            "repoURL": "registry.e2e-registry.svc:5000/charts",
            "chart": "keelson",
            "targetRevision": ver,
            "helm": {"releaseName": "keelson", "valuesObject": values},
        },
        "destination": {"server": "https://kubernetes.default.svc", "namespace": ns},
        "syncPolicy": {"automated": {"prune": True, "selfHeal": True}, "syncOptions": ["CreateNamespace=true"]},
    },
}
print(json.dumps(root))
PYEOF
  log "Applied the root Application keelson-root (chart $ver)"
}

# assert_wave_order: no Application in wave N may start its first deploy before every Application
# in a lower wave has finished its first deploy. Uses the history entry with the lowest id, so a
# later self-heal sync cannot cause a false failure. Prints a table, then fails on any violation.
assert_wave_order() {
  local json
  json="$(kd -n "$ARGOCD_NS" get applications.argoproj.io -l app.kubernetes.io/part-of=keelson -o json)" \
    || fail "could not read the Applications for the wave-order check"
  py "$E2E_ROOT/tests/e2e/lib/wave_order.py" <<<"$json" || fail "sync-wave order is not respected (see the table above)"
  log "Sync-wave order holds for every wave pair"
}
