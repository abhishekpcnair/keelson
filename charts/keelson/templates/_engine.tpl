{{/*
Engine (design 0001 §5.1): module registry → AppProject + Applications.
Module files live in modules/*.yaml and hold data only (contract: §7).
*/}}

{{/*
keelson.modules: every registry module with `enabled` and `resolvedPath` set.
Returns YAML `{modules: [...]}`; use with fromYaml. Fails on unknown module
names, unmet dependsOn, a wave not above its dependencies' waves, and
non-kustomize sources.
*/}}
{{- define "keelson.modules" -}}
{{- $registry := dict -}}
{{- range $path, $_ := .Files.Glob "modules/*.yaml" -}}
{{- $m := $.Files.Get $path | fromYaml -}}
{{- if hasKey $m "Error" -}}
{{- fail (printf "%s: invalid YAML: %s" $path $m.Error) -}}
{{- end -}}
{{- range $f := list "name" "wave" "namespace" "source" -}}
{{- if not (hasKey $m $f) -}}{{- fail (printf "%s: missing required field %q" $path $f) -}}{{- end -}}
{{- end -}}
{{- if not (or (kindIs "float64" $m.wave) (kindIs "int64" $m.wave)) -}}
{{- fail (printf "%s: wave must be a number" $path) -}}
{{- end -}}
{{- if ne (float64 $m.wave) (floor $m.wave) -}}
{{- fail (printf "%s: wave must be an integer" $path) -}}
{{- end -}}
{{- if not (and (kindIs "string" $m.namespace) $m.namespace) -}}
{{- fail (printf "%s: namespace must be a non-empty string" $path) -}}
{{- end -}}
{{- if not (kindIs "map" $m.source) -}}
{{- fail (printf "%s: source must be a map" $path) -}}
{{- end -}}
{{- if and (hasKey $m "ignoreDifferences") (not (kindIs "slice" $m.ignoreDifferences)) -}}
{{- fail (printf "%s: ignoreDifferences must be a list" $path) -}}
{{- end -}}
{{- range $i, $d := $m.ignoreDifferences -}}
{{- include "keelson.checkIgnoreDifference" (dict "where" (printf "%s.ignoreDifferences[%d]" $path $i) "entry" $d) -}}
{{- end -}}
{{- if not $m.source.path -}}{{- fail (printf "%s: missing required field \"source.path\"" $path) -}}{{- end -}}
{{- if ne (printf "modules/%s.yaml" $m.name) $path -}}
{{- fail (printf "%s: name %q must match the file name" $path $m.name) -}}
{{- end -}}
{{- $_ := set $registry $m.name $m -}}
{{- end -}}
{{- range $name, $_ := .Values.modules -}}
{{- if not (hasKey $registry $name) -}}
{{- fail (printf "modules.%s: unknown module (known: %s)" $name (keys $registry | sortAlpha | join ", ")) -}}
{{- end -}}
{{- end -}}
{{- range $name, $_ := (.Values.advanced).modules -}}
{{- if not (hasKey $registry $name) -}}
{{- fail (printf "advanced.modules.%s: unknown module" $name) -}}
{{- end -}}
{{- end -}}
{{- $out := list -}}
{{- range $name := keys $registry | sortAlpha -}}
{{- $m := get $registry $name -}}
{{- $enabled := $m.defaultEnabled -}}
{{- $v := get $.Values.modules $name | default dict -}}
{{- if hasKey $v "enabled" -}}{{- $enabled = $v.enabled -}}{{- end -}}
{{- if ne $m.source.type "kustomize" -}}
{{- fail (printf "module %s: source.type %q is not supported yet (ADR 0002)" $name $m.source.type) -}}
{{- end -}}
{{- $p := $m.source.path -}}
{{- $pp := $m.source.platformPaths | default dict -}}
{{- if hasKey $pp $.Values.platform -}}{{- $p = get $pp $.Values.platform -}}{{- end -}}
{{- $out = append $out (merge (dict "enabled" $enabled "resolvedPath" $p) $m) -}}
{{- end -}}
{{- $on := dict -}}
{{- range $out -}}{{- if .enabled -}}{{- $_ := set $on .name true -}}{{- end -}}{{- end -}}
{{- /* Registry rule (all modules, enabled or not): a wave must be strictly above its dependencies' waves. */ -}}
{{- range $m := $out -}}
{{- range $d := $m.dependsOn -}}
{{- with get $registry $d -}}
{{- if le (float64 $m.wave) (float64 .wave) -}}
{{- fail (printf "module %s (wave %v) depends on %s (wave %v): its wave must be higher" $m.name $m.wave $d .wave) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- range $out -}}
{{- if .enabled -}}
{{- $m := . -}}
{{- range .dependsOn -}}
{{- if not (hasKey $registry .) -}}
{{- fail (printf "module %s depends on %s, which is an unknown module" $m.name .) -}}
{{- end -}}
{{- if not (hasKey $on .) -}}
{{- fail (printf "module %s depends on %s, which is disabled" $m.name .) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- dict "modules" $out | toYaml -}}
{{- end -}}

{{/* keelson.enabledModules: enabled modules, sorted by wave then name. */}}
{{- define "keelson.enabledModules" -}}
{{- $byKey := dict -}}
{{- range (include "keelson.modules" . | fromYaml).modules -}}
{{- if .enabled -}}
{{- /* Sort key "<wave+100000 zero-padded>-<name>": string sort == numeric wave order, then name. Valid for waves > -100000. */ -}}
{{- $_ := set $byKey (printf "%06d-%s" (add (int .wave) 100000) .name) . -}}
{{- end -}}
{{- end -}}
{{- $out := list -}}
{{- range $k := keys $byKey | sortAlpha -}}{{- $out = append $out (get $byKey $k) -}}{{- end -}}
{{- dict "modules" $out | toYaml -}}
{{- end -}}

{{/* keelson.sourceRepos: the AppProject source allowlist. */}}
{{- define "keelson.sourceRepos" -}}
{{- $repos := list .Values.upstream.manifestsRepo -}}
{{- range .Values.argocd.extraSourceRepos -}}{{- $repos = append $repos . -}}{{- end -}}
{{- uniq $repos | toYaml -}}
{{- end -}}

{{/* keelson.destinationNamespaces: union of namespaces written by enabled modules. */}}
{{- define "keelson.destinationNamespaces" -}}
{{- $ns := list -}}
{{- range (include "keelson.enabledModules" . | fromYaml).modules -}}
{{- $ns = append $ns .namespace -}}
{{- range .namespaces -}}{{- $ns = append $ns . -}}{{- end -}}
{{- end -}}
{{- uniq $ns | sortAlpha | toYaml -}}
{{- end -}}

{{/*
keelson.translations: run every helper in the module's `translations` list
(design 0001 §5.2) and collect its patches. Each name maps to a
`keelson.translate.<name>` helper. Call with (dict "root" $ "module" $m).
Returns YAML `{patches: [...]}`.
*/}}
{{- define "keelson.translations" -}}
{{- $known := list "domain" -}}
{{- $patches := list -}}
{{- range .module.translations -}}
{{- if not (has . $known) -}}
{{- fail (printf "module %s: unknown translation %q (known: %s)" $.module.name . (join ", " $known)) -}}
{{- end -}}
{{- $out := include (printf "keelson.translate.%s" .) $ | fromYaml -}}
{{- $patches = concat $patches ($out.patches | default list) -}}
{{- end -}}
{{- dict "patches" $patches | toYaml -}}
{{- end -}}

{{/*
keelson.defaultAppSpec: the shared Application spec for one module.
Call with (dict "root" $ "module" $m).
*/}}
{{- define "keelson.defaultAppSpec" -}}
{{- $v := .root.Values -}}
project: {{ $v.argocd.project }}
destination:
  server: {{ $v.argocd.destinationServer }}
  namespace: {{ .module.namespace }}
source:
  repoURL: {{ $v.upstream.manifestsRepo }}
  targetRevision: {{ $v.upstream.manifestsRef | quote }}
  path: {{ .module.resolvedPath }}
  {{- with include "keelson.translations" . | fromYaml | dig "patches" list }}
  kustomize:
    patches:
      {{- toYaml . | nindent 6 }}
  {{- end }}
syncPolicy:
  automated:
    prune: true
    selfHeal: true
  syncOptions:
    - ServerSideApply=true
    - CreateNamespace=true
    {{- if .module.ignoreDifferences }}
    {{- /* applications.yaml re-applies this (and ignoreDifferences) after any appSpecOverride. */}}
    - RespectIgnoreDifferences=true
    {{- end }}
  retry:
    limit: 10
    backoff:
      duration: 10s
      factor: 2
      maxDuration: 5m
{{- with .module.ignoreDifferences }}
ignoreDifferences:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}


{{/*
keelson.checkIgnoreDifference: one ignoreDifferences entry, from the registry or from an
appSpecOverride. It must be a map with a kind, and name at least one field to ignore
(jsonPointers, jqPathExpressions or managedFieldsManagers) as a non-empty list.
Call with (dict "where" "<location>" "entry" $d).
*/}}
{{- define "keelson.checkIgnoreDifference" -}}
{{- $d := .entry -}}
{{- $where := .where -}}
{{- if not (and (kindIs "map" $d) (kindIs "string" $d.kind) $d.kind) -}}
{{- fail (printf "%s: must be a map with a kind" $where) -}}
{{- end -}}
{{- $named := false -}}
{{- range $f := list "jsonPointers" "jqPathExpressions" "managedFieldsManagers" -}}
{{- if hasKey $d $f -}}
{{- $v := get $d $f -}}
{{- if not (kindIs "slice" $v) -}}{{- fail (printf "%s.%s: must be a list" $where $f) -}}{{- end -}}
{{- if gt (len $v) 0 -}}{{- $named = true -}}{{- end -}}
{{- end -}}
{{- end -}}
{{- if not $named -}}
{{- fail (printf "%s: must name jsonPointers, jqPathExpressions or managedFieldsManagers" $where) -}}
{{- end -}}
{{- end -}}


{{/*
keelson.checkOverride: appSpecOverride is an allow-list at every level, so new
ArgoCD or Kustomize fields (sourceHydrator, kustomize.components, ...) are
rejected by default and sources stay pinned (hard rule 3).
  spec:             syncPolicy, ignoreDifferences, info, revisionHistoryLimit, source
  source:           path, kustomize
  source.kustomize: patches, commonLabels, commonAnnotations, namePrefix, nameSuffix, replicas
  each patch:       patch (string, required), target, options
Allowed keys may not be null. A patch may not touch an image (hard rule 2).
Call with (dict "module" $name "override" $o).
*/}}
{{- /*
Merge syncOptions by key (the text before the first "="). Start with base, in order.
An override entry replaces the entry with the same key, or is added at the end.
force entries then apply the same way, so an override can't change them.
Example: base [ServerSideApply=true, CreateNamespace=true] + override [CreateNamespace=false, PruneLast=true]
  -> [ServerSideApply=true, CreateNamespace=false, PruneLast=true]
Call with (dict "base" list "override" list "force" list). Returns YAML {items: [...]}.
*/}}
{{- define "keelson.mergeSyncOptions" -}}
{{- $keys := list -}}
{{- $vals := dict -}}
{{- range $o := concat (.base | default list) (.override | default list) (.force | default list) -}}
{{- $k := regexReplaceAll "=.*$" (toString $o) "" -}}
{{- if not (hasKey $vals $k) -}}{{- $keys = append $keys $k -}}{{- end -}}
{{- $_ := set $vals $k (toString $o) -}}
{{- end -}}
{{- $out := list -}}
{{- range $keys -}}{{- $out = append $out (get $vals .) -}}{{- end -}}
{{- toYaml (dict "items" $out) -}}
{{- end -}}

{{- define "keelson.checkOverride" -}}
{{- $where := printf "advanced.modules.%s.appSpecOverride" .module -}}
{{- include "keelson.checkKeys" (dict "where" $where "obj" .override "allowed" (list "syncPolicy" "ignoreDifferences" "info" "revisionHistoryLimit" "source")) -}}
{{- if and (hasKey .override "ignoreDifferences") (not (kindIs "slice" .override.ignoreDifferences)) -}}
{{- fail (printf "%s.ignoreDifferences: must be a list" $where) -}}
{{- end -}}
{{- range $i, $d := .override.ignoreDifferences -}}
{{- include "keelson.checkIgnoreDifference" (dict "where" (printf "%s.ignoreDifferences[%d]" $where $i) "entry" $d) -}}
{{- end -}}
{{- if and (hasKey .override "syncPolicy") (not (kindIs "map" .override.syncPolicy)) -}}
{{- fail (printf "%s.syncPolicy: must be a map" $where) -}}
{{- end -}}
{{- if and (kindIs "map" .override.syncPolicy) (hasKey .override.syncPolicy "syncOptions") (not (kindIs "slice" .override.syncPolicy.syncOptions)) -}}
{{- fail (printf "%s.syncPolicy.syncOptions: must be a list" $where) -}}
{{- end -}}
{{- range $i, $o := (dig "syncPolicy" "syncOptions" list .override) -}}
{{- if not (and (kindIs "string" $o) (regexMatch "^[A-Za-z]+=.+$" $o)) -}}
{{- fail (printf "%s.syncPolicy.syncOptions[%d]: must be Key=Value, got %v" $where $i $o) -}}
{{- end -}}
{{- end -}}
{{- if and (hasKey .override "source") (not (kindIs "map" .override.source)) -}}{{- fail (printf "%s.source: must be a map" $where) -}}{{- end -}}
{{- if and (kindIs "map" .override.source) (hasKey .override.source "kustomize") (not (kindIs "map" .override.source.kustomize)) -}}{{- fail (printf "%s.source.kustomize: must be a map" $where) -}}{{- end -}}
{{- with .override.source -}}
{{- include "keelson.checkKeys" (dict "where" (printf "%s.source" $where) "obj" . "allowed" (list "path" "kustomize")) -}}
{{- with .kustomize -}}
{{- $kw := printf "%s.source.kustomize" $where -}}
{{- include "keelson.checkKeys" (dict "where" $kw "obj" . "allowed" (list "patches" "commonLabels" "commonAnnotations" "namePrefix" "nameSuffix" "replicas")) -}}
{{- if hasKey . "patches" -}}
{{- if not (kindIs "slice" .patches) -}}{{- fail (printf "%s.patches: must be a list" $kw) -}}{{- end -}}
{{- range $i, $pt := .patches -}}
{{- $pw := printf "%s.patches[%d]" $kw $i -}}
{{- if not (kindIs "map" $pt) -}}{{- fail (printf "%s: must be a map" $pw) -}}{{- end -}}
{{- include "keelson.checkKeys" (dict "where" $pw "obj" $pt "allowed" (list "patch" "target" "options")) -}}
{{- if not (and (kindIs "string" $pt.patch) $pt.patch) -}}{{- fail (printf "%s.patch: must be a non-empty string" $pw) -}}{{- end -}}
{{- include "keelson.checkPatchImage" (dict "where" $pw "patch" $pt.patch) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* keelson.checkKeys: fail on keys outside `allowed`, and on null values. */}}
{{- define "keelson.checkKeys" -}}
{{- $c := . -}}
{{- range $k := keys .obj | sortAlpha -}}
{{- if not (has $k $c.allowed) -}}
{{- fail (printf "%s.%s: not allowed (allowed: %s)" $c.where $k (join ", " $c.allowed)) -}}
{{- end -}}
{{- if kindIs "invalid" (get $c.obj $k) -}}
{{- fail (printf "%s.%s: must not be null" $c.where $k) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
keelson.checkPatchImage: fail if an inline patch touches a container image.
Checks the raw text (YAML or JSON key `image`, or a JSON6902 path ending in
/image) and, when it parses, the canonical JSON of the patch.
*/}}
{{- define "keelson.checkPatchImage" -}}
{{- $re := `(^|[^A-Za-z0-9_])["']?image["']?\s*:|/image($|[^A-Za-z0-9_])` -}}
{{- $raw := .patch -}}
{{- $canon := "" -}}
{{- $asMap := fromYaml $raw -}}
{{- if not (hasKey $asMap "Error") -}}{{- $canon = toJson $asMap -}}
{{- else -}}
{{- $asList := fromYamlArray $raw -}}
{{- if not (and (eq (len $asList) 1) (kindIs "string" (first $asList)) (hasPrefix "error" (first $asList))) -}}{{- $canon = toJson $asList -}}{{- end -}}
{{- end -}}
{{- if or (regexMatch $re $raw) (regexMatch `"image":|/image"` $canon) -}}
{{- fail (printf "%s.patch: may not change an image (hard rule 2)" .where) -}}
{{- end -}}
{{- end -}}
