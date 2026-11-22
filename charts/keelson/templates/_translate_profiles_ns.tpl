{{/*
Translation: `profileNamespaceLabels` → extra labels on every profile namespace
(design 0001 §9). The profile controller (dashboard module) reads its labels
from the generated ConfigMap `profiles-namespace-labels-data`. Upstream builds it
with `behavior: replace`, so the patch replaces the whole file: upstream's labels
(restated/profile-namespace-labels.yaml) unchanged, plus the user's labels.
The controller adds a label only when the namespace does not have the key. It never
changes an existing value (docs/configuration/profile-namespaces.md, "Change or remove a label").
Call with (dict "root" $ "module" $m). Returns YAML `{patches: [...]}`; empty
when profileNamespaceLabels is empty.
*/}}
{{- define "keelson.translate.profileNamespaceLabels" -}}
{{- $user := .root.Values.profileNamespaceLabels | default dict -}}
{{- $patches := list -}}
{{- if $user -}}
{{- $upstream := .root.Files.Get "restated/profile-namespace-labels.yaml" | fromYaml -}}
{{- range $k := keys $user | sortAlpha -}}
{{- if hasPrefix "pod-security.kubernetes.io/" $k -}}
{{- fail (printf "profileNamespaceLabels.%s: Pod Security labels can't be set here; upstream enforces baseline" $k) -}}
{{- end -}}
{{- if hasKey $upstream $k -}}
{{- fail (printf "profileNamespaceLabels.%s: upstream already sets this label (%s); it can't be overridden" $k (join ", " (keys $upstream | sortAlpha))) -}}
{{- end -}}
{{- end -}}
{{- $p := include "keelson.translate.profileNamespaceLabels.patch" (dict "labels" (merge (deepCopy $user) $upstream)) -}}
{{- $patches = append $patches (dict "patch" $p "target" (dict "version" "v1" "kind" "ConfigMap" "name" "profiles-namespace-labels-data")) -}}
{{- end -}}
{{- dict "patches" $patches | toYaml -}}
{{- end -}}

{{- define "keelson.translate.profileNamespaceLabels.patch" -}}
# purpose: add profileNamespaceLabels to every profile namespace
# upstream: none
# remove-when: never (Keelson intent: profileNamespaceLabels)
- op: replace
  path: /data/namespace-labels.yaml
  value: |
    {{- range $k := keys .labels | sortAlpha }}
    {{ $k }}: {{ get $.labels $k | quote }}
    {{- end }}
{{- end -}}
