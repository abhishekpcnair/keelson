#!/usr/bin/env bash
# Test IdP for the groups e2e (#66): upstream's Keycloak from .cache/upstream/<tag>/tests/keycloak.
# Source this file; don't run it. Wrap, don't copy: it applies upstream's kustomization (keycloak.yaml
# and realm.json only; not the oauth2-proxy or istio dirs next to them) and changes the running
# realm with the Keycloak admin API. Nothing upstream is copied into this repo.
#
# Functions:
#   keycloak_up <dex-callback-url>  deploy Keycloak, add a throwaway admin, let Dex log in
#   keycloak_add_group <name>       add a group and put the realm's test user in it
#   keycloak_down                   delete the namespace and the port-forward
# Read from upstream's realm.json: KEYCLOAK_USER, KEYCLOAK_EMAIL, KEYCLOAK_PASSWORD,
# KEYCLOAK_CLIENT_ID, KEYCLOAK_CLIENT_SECRET (public test values, not Keelson secrets).
# shellcheck disable=SC2034  # variables are used by the scripts that source this file

KEYCLOAK_NS=keycloak
KEYCLOAK_HOST=keycloak.keycloak.svc.cluster.local   # KC_HOSTNAME in upstream keycloak.yaml
KEYCLOAK_PORT="${KEYCLOAK_PORT:-8081}"               # local end of the port-forward
KEYCLOAK_REALM=kubeflow
KEYCLOAK_ADMIN_SECRET=keelson-e2e-keycloak-admin

_keycloak_dir() { printf '%s\n' "$(upstream_dir)/tests/keycloak"; }

# _kc_api <method> <path> [json]: admin API call through the port-forward. Prints the body.
_kc_api() {
  local method="$1" path="$2" data="${3:-}" token
  token="$(curl -sf "http://127.0.0.1:$KEYCLOAK_PORT/realms/master/protocol/openid-connect/token" \
    --data-urlencode grant_type=password --data-urlencode client_id=admin-cli \
    --data-urlencode "username=$KEYCLOAK_ADMIN_USER" --data-urlencode "password=$KEYCLOAK_ADMIN_PASSWORD" \
    | py -c 'import json,sys;print(json.load(sys.stdin)["access_token"])')" || fail "keycloak: no admin token"
  if [[ -n "$data" ]]; then
    curl -sf -X "$method" -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
      --data "$data" "http://127.0.0.1:$KEYCLOAK_PORT/admin/realms/$KEYCLOAK_REALM$path"
  else
    curl -sf -X "$method" -H "Authorization: Bearer $token" "http://127.0.0.1:$KEYCLOAK_PORT/admin/realms/$KEYCLOAK_REALM$path"
  fi
}

keycloak_up() {
  local callback="$1" dir realm i
  dir="$(_keycloak_dir)"
  [[ -f "$dir/kustomization.yaml" && -f "$dir/realm.json" ]] || fail "$dir not found; upstream may have moved it (check during /upstream-bump)"
  realm="$dir/realm.json"
  eval "$(py - "$realm" <<'EOF'
import json, shlex, sys
r = json.load(open(sys.argv[1]))
u, c = r["users"][0], r["clients"][0]
pw = next(x["value"] for x in u["credentials"] if x["type"] == "password")
for k, v in {"KEYCLOAK_USER": u["username"], "KEYCLOAK_EMAIL": u["email"], "KEYCLOAK_PASSWORD": pw,
             "KEYCLOAK_CLIENT_ID": c["clientId"], "KEYCLOAK_CLIENT_SECRET": c["secret"]}.items():
    print(f"{k}={shlex.quote(v)}")
EOF
)" || fail "could not read $realm"

  log "keycloak: applying upstream tests/keycloak"
  kubectl kustomize "$dir" | kubectl apply -f - >/dev/null
  # A throwaway admin with a random password, so the admin API can change the realm. Upstream starts
  # Keycloak without one. Keycloak creates it at first start (dev mode keeps no data across restarts).
  KEYCLOAK_ADMIN_USER=keelson-e2e
  KEYCLOAK_ADMIN_PASSWORD="$(openssl rand -hex 16)"
  kubectl -n "$KEYCLOAK_NS" create secret generic "$KEYCLOAK_ADMIN_SECRET" \
    --from-literal=KC_BOOTSTRAP_ADMIN_USERNAME="$KEYCLOAK_ADMIN_USER" \
    --from-literal=KC_BOOTSTRAP_ADMIN_PASSWORD="$KEYCLOAK_ADMIN_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "$KEYCLOAK_NS" set env deployment/keycloak --from="secret/$KEYCLOAK_ADMIN_SECRET" >/dev/null
  kubectl -n "$KEYCLOAK_NS" rollout status deployment/keycloak --timeout=300s >/dev/null \
    || fail "keycloak did not become ready in 300s"

  kubectl -n "$KEYCLOAK_NS" port-forward svc/keycloak "$KEYCLOAK_PORT:8081" >"$E2E_CACHE/keycloak-port-forward.log" 2>&1 &
  E2E_KC_PF=$!
  local up=0
  for i in $(seq 1 30); do
    if curl -sf -o /dev/null "http://127.0.0.1:$KEYCLOAK_PORT/realms/$KEYCLOAK_REALM/.well-known/openid-configuration"; then up=1; break; fi
    kill -0 "$E2E_KC_PF" 2>/dev/null || fail "keycloak port-forward exited: $(cat "$E2E_CACHE/keycloak-port-forward.log")"
    sleep 2
  done
  (( up == 1 )) || fail "keycloak did not answer on 127.0.0.1:$KEYCLOAK_PORT after 60s"

  # Dex is the client now: allow its callback, and turn off PKCE (upstream's client requires it for
  # oauth2-proxy; the Dex oidc connector does not send it).
  log "keycloak: allowing the Dex callback $callback"
  local id client
  id="$(_kc_api GET "/clients?clientId=$KEYCLOAK_CLIENT_ID" | py -c 'import json,sys;print(json.load(sys.stdin)[0]["id"])')" \
    || fail "keycloak: client $KEYCLOAK_CLIENT_ID not found"
  client="$(_kc_api GET "/clients/$id" | py -c '
import json, sys
c = json.load(sys.stdin)
c["redirectUris"] = sorted(set(c.get("redirectUris", [])) | {sys.argv[1]})
c.setdefault("attributes", {})["pkce.code.challenge.method"] = ""
print(json.dumps(c))
' "$callback")" || fail "keycloak: could not read client $KEYCLOAK_CLIENT_ID"
  _kc_api PUT "/clients/$id" "$client" >/dev/null || fail "keycloak: could not update client $KEYCLOAK_CLIENT_ID"
}

keycloak_add_group() {
  local name="$1" uid gid
  _kc_api POST /groups "{\"name\": \"$name\"}" >/dev/null || true   # already there on a rerun
  gid="$(_kc_api GET "/groups?search=$name&exact=true" | py -c '
import json, sys
print(next(g["id"] for g in json.load(sys.stdin) if g["name"] == sys.argv[1]))' "$name")" \
    || fail "keycloak: group $name not found"
  uid="$(_kc_api GET "/users?username=$KEYCLOAK_USER&exact=true" | py -c 'import json,sys;print(json.load(sys.stdin)[0]["id"])')" \
    || fail "keycloak: user $KEYCLOAK_USER not found"
  _kc_api PUT "/users/$uid/groups/$gid" >/dev/null || fail "keycloak: could not add $KEYCLOAK_USER to $name"
}

keycloak_down() {
  if [[ -n "${E2E_KC_PF:-}" ]]; then kill "$E2E_KC_PF" 2>/dev/null || true; fi
  kubectl delete namespace "$KEYCLOAK_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
