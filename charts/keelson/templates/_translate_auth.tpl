{{/*
Translation: `auth` (design 0001 §5.2, §8). Turns `auth.staticUsers` and
`auth.dex.connectors[]` into patches on the upstream `dex` module.

The whole Dex config is one string (ConfigMap dex, data.config.yaml), so any
change replaces it, as upstream's README documents. Keelson re-states the
upstream keys below unchanged; `make kustomize-check` fails if they drift from
the pinned tag. Client IDs and secrets reach Dex only as env vars from the
user's Secret (`secretRef`), never as values (hard rule 6).
*/}}

{{/* Upstream common/dex/overlays/oauth2-proxy/config-map.yaml at 26.10.0. Keep identical. */}}
{{- define "keelson.dex.upstreamConfig" -}}
issuer: http://dex.auth.svc.cluster.local:5556/dex
storage:
  type: kubernetes
  config:
    inCluster: true
web:
  http: 0.0.0.0:5556
logger:
  level: "debug"
  format: text
oauth2:
  skipApprovalScreen: true
enablePasswordDB: true
staticPasswords:
- email: user@example.com
  hashFromEnv: DEX_USER_PASSWORD
  username: user
  userID: "15841185641784"
staticClients:
- idEnv: OIDC_CLIENT_ID
  redirectURIs: ["/oauth2/callback"]
  name: 'Dex Login Application'
  secretEnv: OIDC_CLIENT_SECRET
{{- end -}}

{{/* keelson.dex.envPrefix: KEELSON_DEX_<ID>, from a connector id. */}}
{{- define "keelson.dex.envPrefix" -}}
{{- printf "KEELSON_DEX_%s" (. | upper | replace "-" "_") -}}
{{- end -}}

{{/* keelson.dex.connector: one Dex connector. Call with (dict "root" $ "c" $connector). */}}
{{- define "keelson.dex.connector" -}}
{{- $c := .c -}}
{{- $env := include "keelson.dex.envPrefix" $c.id -}}
{{- $cfg := dict
    "clientID" (printf "$%s_CLIENT_ID" $env)
    "clientSecret" (printf "$%s_CLIENT_SECRET" $env)
    "redirectURI" (printf "%s/dex/callback" (include "keelson.domain.url" .root)) -}}
{{- if eq $c.type "oidc" -}}
{{- $_ := set $cfg "issuer" $c.issuer -}}
{{- $_ := set $cfg "scopes" ($c.scopes | default (list "openid" "profile" "email" "groups")) -}}
{{- $_ := set $cfg "insecureEnableGroups" true -}}
{{- $_ := set $cfg "claimMapping" (dict "groups" ($c.groupsClaim | default "groups")) -}}
{{- else if eq $c.type "microsoft" -}}
{{- $_ := set $cfg "tenant" $c.tenant -}}
{{- $_ := set $cfg "onlySecurityGroups" (dig "onlySecurityGroups" false $c) -}}
{{- $_ := set $cfg "groupNameFormat" ($c.groupNameFormat | default "name") -}}
{{- /* Kubeflow compares kubeflow-userid (the email) case-sensitively with Profile owners. */ -}}
{{- $_ := set $cfg "emailToLowercase" (dig "emailToLowercase" true $c) -}}
{{- with $c.allowedGroups -}}
{{- $_ := set $cfg "groups" . -}}
{{- $_ := set $cfg "useGroupsAsWhitelist" true -}}
{{- end -}}
{{- else if eq $c.type "github" -}}
{{- $_ := set $cfg "orgs" $c.orgs -}}
{{- $_ := set $cfg "teamNameField" ($c.teamNameField | default "slug") -}}
{{- $_ := set $cfg "loadAllGroups" (dig "loadAllGroups" false $c) -}}
{{- $_ := set $cfg "useLoginAsID" (dig "useLoginAsID" false $c) -}}
{{- else -}}
{{- fail (printf "auth.dex.connectors[%s]: unsupported type %q" $c.id $c.type) -}}
{{- end -}}
{{- $cfg = mustMergeOverwrite $cfg (deepCopy ($c.extraConfig | default dict)) -}}
{{- dict "type" $c.type "id" $c.id "name" ($c.name | default $c.id) "config" $cfg | toYaml -}}
{{- end -}}

{{/*
keelson.translate.auth: patches for the dex module. Call with (dict "root" $
"module" $m). Returns YAML `{patches: [...]}`; empty when the intent matches
upstream (static users on, no connectors).
*/}}
{{- define "keelson.translate.auth" -}}
{{- $auth := .root.Values.auth | default dict -}}
{{- $static := dig "staticUsers" "enabled" true $auth -}}
{{- $connectors := dig "dex" "connectors" list $auth -}}
{{- $patches := list -}}
{{- if and (eq .module.name "dex") (or (not $static) $connectors) -}}
{{- $cfg := include "keelson.dex.upstreamConfig" . | fromYaml -}}
{{- if not $static -}}
{{- $_ := set $cfg "enablePasswordDB" false -}}
{{- $_ := unset $cfg "staticPasswords" -}}
{{- end -}}
{{- $seen := dict -}}
{{- $list := list -}}
{{- $env := list -}}
{{- range $connectors -}}
{{- if hasKey $seen .id -}}{{- fail (printf "auth.dex.connectors: duplicate id %q" .id) -}}{{- end -}}
{{- $_ := set $seen .id true -}}
{{- $list = append $list (include "keelson.dex.connector" (dict "root" $.root "c" .) | fromYaml) -}}
{{- $p := include "keelson.dex.envPrefix" .id -}}
{{- $ref := .secretRef -}}
{{- $env = append $env (dict "name" (printf "%s_CLIENT_ID" $p) "valueFrom" (dict "secretKeyRef" (dict "name" $ref.name "key" ($ref.clientIDKey | default "clientID")))) -}}
{{- $env = append $env (dict "name" (printf "%s_CLIENT_SECRET" $p) "valueFrom" (dict "secretKeyRef" (dict "name" $ref.name "key" ($ref.clientSecretKey | default "clientSecret")))) -}}
{{- end -}}
{{- if $list -}}{{- $_ := set $cfg "connectors" $list -}}{{- end -}}
{{- $patches = append $patches (dict "patch" (include "keelson.translate.auth.config" $cfg) "target" (dict "version" "v1" "kind" "ConfigMap" "name" "dex")) -}}
{{- /* Dex reads config.yaml only at start: the config hash restarts it on change. */ -}}
{{- $deploy := dict "env" $env "hash" (toYaml $cfg | sha256sum) -}}
{{- $patches = append $patches (dict "patch" (include "keelson.translate.auth.deployment" $deploy) "target" (dict "group" "apps" "version" "v1" "kind" "Deployment" "name" "dex")) -}}
{{- end -}}
{{- dict "patches" $patches | toYaml -}}
{{- end -}}

{{- define "keelson.translate.auth.config" -}}
# purpose: set Dex connectors and static users from auth values (upstream-documented config replacement)
# upstream: none
# remove-when: upstream Dex config supports adding connectors without replacing config.yaml
- op: replace
  path: /data/config.yaml
  value: |
    {{- toYaml . | nindent 4 }}
{{- end -}}

{{- define "keelson.translate.auth.deployment" -}}
# purpose: restart Dex when its config changes; pass connector client IDs and secrets from the user's Secret
# upstream: none
# remove-when: never (Keelson intent: auth.dex.connectors[].secretRef)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dex
spec:
  template:
    metadata:
      annotations:
        keelson.io/dex-config: {{ .hash | quote }}
    {{- if .env }}
    spec:
      containers:
        - name: dex
          env:
            {{- toYaml .env | nindent 12 }}
    {{- end }}
{{- end -}}
