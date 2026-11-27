{{/*
Translation: `database` → patches on the upstream `pipelines` module (#39, design 0001 §5.2).
`database.mode: external` points KFP at the user's MySQL server, reads the credentials from
the user's Secret in namespace kubeflow (`secretRef`, hard rule 6), and deletes bundled MySQL.
`bundled` (the default) returns no patches.

Facts at 26.10.0 (`applications/pipeline/overlays`): every consumer reads the host, port and
database names from ConfigMap pipeline-install-config, and the user name and password from
Secret mysql-secret in 8 env entries of 3 Deployments. `make kustomize-check` fails if any env
entry still names mysql-secret after the patches, so a new upstream consumer fails at bump time.
Call with (dict "root" $ "module" $m). Returns YAML `{patches: [...]}`.
*/}}
{{- define "keelson.translate.database" -}}
{{- $db := .root.Values.database | default dict -}}
{{- $patches := list -}}
{{- if and (eq .module.name "pipelines") (eq ($db.mode | default "bundled") "external") -}}
{{- $ext := $db.external | default dict -}}
{{- if not $ext.host -}}{{- fail "database.external.host is required when database.mode is external" -}}{{- end -}}
{{- if not (dig "secretRef" "name" "" $ext) -}}{{- fail "database.external.secretRef.name is required when database.mode is external" -}}{{- end -}}
{{- $ctx := dict "ext" $ext "user" (dig "secretRef" "usernameKey" "username" $ext) "password" (dig "secretRef" "passwordKey" "password" $ext) -}}
{{- /* pipeline-install-config has no hash suffix, so a change to it alone restarts nothing: the hash rolls the consumers. */ -}}
{{- $_ := set $ctx "hash" (toYaml $ext | sha256sum) -}}
{{- $patches = append $patches (dict "patch" (include "keelson.translate.database.config" $ctx) "target" (dict "version" "v1" "kind" "ConfigMap" "name" "pipeline-install-config")) -}}
{{- range $d := list (list "ml-pipeline" "ml-pipeline-api-server" (list "DBCONFIG_USER" "DBCONFIG_PASSWORD" "DBCONFIG_MYSQLCONFIG_USER" "DBCONFIG_MYSQLCONFIG_PASSWORD"))
                     (list "cache-server" "server" (list "DBCONFIG_USER" "DBCONFIG_PASSWORD"))
                     (list "metadata-grpc-deployment" "container" (list "DBCONFIG_USER" "DBCONFIG_PASSWORD")) -}}
{{- $p := include "keelson.translate.database.credentials" (merge (dict "deployment" (index $d 0) "container" (index $d 1) "env" (index $d 2)) $ctx) -}}
{{- $patches = append $patches (dict "patch" $p "target" (dict "group" "apps" "version" "v1" "kind" "Deployment" "name" (index $d 0))) -}}
{{- end -}}
{{- $patches = append $patches (dict "patch" (include "keelson.translate.database.deleteBundled" .) "target" (dict "labelSelector" "application-crd-id=kubeflow-pipelines" "name" "^(mysql|mysql-pv-claim|mysql-secret|ml-pipeline-mysql)$")) -}}
{{- end -}}
{{- dict "patches" $patches | toYaml -}}
{{- end -}}

{{- define "keelson.translate.database.config" -}}
# purpose: point Kubeflow Pipelines at the user's external MySQL server (database.mode external)
# upstream: none
# remove-when: upstream ships an external-database overlay for applications/pipeline
apiVersion: v1
kind: ConfigMap
metadata:
  name: pipeline-install-config
data:
  mysqlHost: {{ .ext.host | quote }}
  mysqlPort: {{ .ext.port | default 3306 | toString | quote }}
  {{- with .ext.databases }}
  {{- with .pipeline }}
  pipelineDb: {{ . | quote }}
  {{- end }}
  {{- with .cache }}
  cacheDb: {{ . | quote }}
  {{- end }}
  {{- with .metadata }}
  mlmdDb: {{ . | quote }}
  {{- end }}
  {{- end }}
{{- end -}}

{{- define "keelson.translate.database.credentials" -}}
# purpose: {{ .deployment }} reads the MySQL user name and password from the user's Secret, not upstream's mysql-secret literals
# upstream: none
# remove-when: upstream ships an external-database overlay for applications/pipeline
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .deployment }}
spec:
  template:
    metadata:
      annotations:
        keelson.io/database-config: {{ .hash | quote }}
    spec:
      containers:
        - name: {{ .container }}
          env:
            {{- range .env }}
            - name: {{ . }}
              valueFrom:
                secretKeyRef:
                  name: {{ $.ext.secretRef.name | quote }}
                  key: {{ if hasSuffix "PASSWORD" . }}{{ $.password | quote }}{{ else }}{{ $.user | quote }}{{ end }}
            {{- end }}
{{- end -}}

{{/*
The bundled MySQL objects. A delete patch needs one target per object, so the target above
matches them by name (a regex) and by upstream's application label. kustomize applies the
patch to each match, and `$patch: delete` removes it. Kinds differ, so the patch names none.
*/}}
{{- define "keelson.translate.database.deleteBundled" -}}
# purpose: remove bundled MySQL (Deployment, Service, ServiceAccount, PVC, Secret, AuthorizationPolicy, DestinationRule) when database.mode is external
# upstream: none
# remove-when: upstream ships an external-database overlay for applications/pipeline
$patch: delete
apiVersion: v1
kind: Unused
metadata:
  name: unused
{{- end -}}
