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
{{- $_ := set $cfg "useLoginAsID" (dig "useLoginAsID" false $c) -}}
{{- with $c.enterprise -}}
{{- $_ := set $cfg "hostName" .hostName -}}
{{- /* Dex reads rootCA as a file; keelson.translate.auth mounts the Secret there. */ -}}
{{- if .rootCASecretRef -}}{{- $_ := set $cfg "rootCA" (printf "/etc/dex/ca/%s/ca.crt" $c.id) -}}{{- end -}}
{{- end -}}
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
{{- $volumes := list -}}
{{- $volSeen := dict -}}
{{- $mounts := list -}}
{{- range $connectors -}}
{{- if hasKey $seen .id -}}{{- fail (printf "auth.dex.connectors: duplicate id %q" .id) -}}{{- end -}}
{{- $_ := set $seen .id true -}}
{{- $list = append $list (include "keelson.dex.connector" (dict "root" $.root "c" .) | fromYaml) -}}
{{- $p := include "keelson.dex.envPrefix" .id -}}
{{- $ref := .secretRef -}}
{{- $env = append $env (dict "name" (printf "%s_CLIENT_ID" $p) "valueFrom" (dict "secretKeyRef" (dict "name" $ref.name "key" ($ref.clientIDKey | default "clientID")))) -}}
{{- $env = append $env (dict "name" (printf "%s_CLIENT_SECRET" $p) "valueFrom" (dict "secretKeyRef" (dict "name" $ref.name "key" ($ref.clientSecretKey | default "clientSecret")))) -}}
{{- $ca := dig "enterprise" "rootCASecretRef" dict . -}}
{{- if $ca -}}
{{- /* "ca-<id>" can pass the 63-character volume name limit: use a short hash of the id.
       Not optional: a missing Secret stops Dex loudly, not one connector quietly. */ -}}
{{- $vol := printf "ca-%s" (trunc 8 (sha256sum .id)) -}}
{{- if hasKey $volSeen $vol -}}{{- fail (printf "auth.dex.connectors[%s]: CA volume name %s collides with connector %s; rename one connector id" .id $vol (get $volSeen $vol)) -}}{{- end -}}
{{- $_ := set $volSeen $vol .id -}}
{{- $volumes = append $volumes (dict "name" $vol "secret" (dict "secretName" $ca.name "items" (list (dict "key" ($ca.key | default "ca.crt") "path" "ca.crt")))) -}}
{{- $mounts = append $mounts (dict "name" $vol "mountPath" (printf "/etc/dex/ca/%s" .id) "readOnly" true) -}}
{{- end -}}
{{- end -}}
{{- if $list -}}{{- $_ := set $cfg "connectors" $list -}}{{- end -}}
{{- $patches = append $patches (dict "patch" (include "keelson.translate.auth.config" $cfg) "target" (dict "version" "v1" "kind" "ConfigMap" "name" "dex")) -}}
{{- /* Dex reads config.yaml only at start: the config hash restarts it on change. */ -}}
{{- $deploy := dict "env" $env "volumes" $volumes "mounts" $mounts "hash" (toYaml $cfg | sha256sum) -}}
{{- $patches = append $patches (dict "patch" (include "keelson.translate.auth.deployment" $deploy) "target" (dict "group" "apps" "version" "v1" "kind" "Deployment" "name" "dex")) -}}
{{- end -}}
{{- /* Production secrets (#27): oauth2-proxy and Dex read the user's Secrets, not upstream's public literals. */ -}}
{{- $oidc := dig "oidcClient" "secretRef" "name" "" $auth -}}
{{- $cookie := dig "cookie" "secretRef" "name" "" $auth -}}
{{- if and (eq .module.name "oauth2-proxy") (or $oidc $cookie) -}}
{{- $patches = append $patches (dict "patch" (include "keelson.translate.auth.oauth2proxySecrets" (dict "oidc" $oidc "cookie" $cookie)) "target" (dict "group" "apps" "version" "v1" "kind" "Deployment" "name" "oauth2-proxy")) -}}
{{- end -}}
{{- if and (eq .module.name "dex") $oidc -}}
{{- $patches = append $patches (dict "patch" (include "keelson.translate.auth.dexSecrets" $oidc) "target" (dict "group" "apps" "version" "v1" "kind" "Deployment" "name" "dex")) -}}
{{- end -}}
{{- dict "patches" $patches | toYaml -}}
{{- end -}}

{{/*
oauth2-proxy env entries 0, 1 and 2 are the client ID, client secret and cookie secret
(upstream common/oauth2-proxy/base/deployment.yaml at 26.10.0). Each `test` op checks the env var name
first, so a moved entry fails the sync and never changes the wrong one. The Secret name is not tested:
upstream's generator adds a hash to it. Secret key names stay the same as upstream's.
*/}}
{{- define "keelson.translate.auth.oauth2proxySecrets" -}}
# purpose: oauth2-proxy reads its client ID, client secret and cookie secret from the user's Secrets, not upstream's public literals
# upstream: none
# remove-when: upstream ships a production overlay without literal secrets
{{- if .oidc }}
- op: test
  path: /spec/template/spec/containers/0/env/0/name
  value: OAUTH2_PROXY_CLIENT_ID
- op: replace
  path: /spec/template/spec/containers/0/env/0/valueFrom/secretKeyRef/name
  value: {{ .oidc | quote }}
- op: test
  path: /spec/template/spec/containers/0/env/1/name
  value: OAUTH2_PROXY_CLIENT_SECRET
- op: replace
  path: /spec/template/spec/containers/0/env/1/valueFrom/secretKeyRef/name
  value: {{ .oidc | quote }}
{{- end }}
{{- if .cookie }}
- op: test
  path: /spec/template/spec/containers/0/env/2/name
  value: OAUTH2_PROXY_COOKIE_SECRET
- op: replace
  path: /spec/template/spec/containers/0/env/2/valueFrom/secretKeyRef/name
  value: {{ .cookie | quote }}
{{- end }}
{{- end -}}

{{/*
Dex gets its static client ID and secret from `envFrom[0]` (Secret dex-oidc-client, no name hash:
upstream sets disableNameSuffixHash). Replace that entry with two env entries from the user's Secret.
envFrom[1] (dex-passwords) stays.
*/}}
{{- define "keelson.translate.auth.dexSecrets" -}}
# purpose: Dex reads the static client ID and secret from the user's Secret, not upstream's public literals
# upstream: none
# remove-when: upstream ships a production overlay without literal secrets
- op: test
  path: /spec/template/spec/containers/0/envFrom/0/secretRef/name
  value: dex-oidc-client
- op: remove
  path: /spec/template/spec/containers/0/envFrom/0
- op: add
  path: /spec/template/spec/containers/0/env/-
  value:
    name: OIDC_CLIENT_ID
    valueFrom:
      secretKeyRef:
        name: {{ . | quote }}
        key: client-id
- op: add
  path: /spec/template/spec/containers/0/env/-
  value:
    name: OIDC_CLIENT_SECRET
    valueFrom:
      secretKeyRef:
        name: {{ . | quote }}
        key: client-secret
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
# purpose: restart Dex when its config changes; pass connector client IDs and secrets from the user's Secret{{ if .volumes }}; mount GitHub Enterprise CA Secrets{{ end }}
# upstream: none
# remove-when: never (Keelson intent: auth.dex.connectors[].secretRef{{ if .volumes }} and enterprise.rootCASecretRef{{ end }})
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dex
spec:
  template:
    metadata:
      annotations:
        keelson.io/dex-config: {{ .hash | quote }}
    {{- if or .env .volumes }}
    spec:
      containers:
        - name: dex
          {{- with .env }}
          env:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with .mounts }}
          volumeMounts:
            {{- toYaml . | nindent 12 }}
          {{- end }}
      {{- with .volumes }}
      volumes:
        {{- toYaml . | nindent 8 }}
      {{- end }}
    {{- end }}
{{- end -}}
