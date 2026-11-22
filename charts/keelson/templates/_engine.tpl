{{/*
Engine (design 0001 §5.1): module registry → AppProject + Applications.
Module files live in modules/*.yaml and hold data only (contract: §7).
*/}}

{{/*
keelson.modules: every registry module with `enabled` and `resolvedPath` set.
Returns YAML `{modules: [...]}`; use with fromYaml. Fails on unknown module
names, unmet dependsOn, and non-kustomize sources.
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
syncPolicy:
  automated:
    prune: true
    selfHeal: true
  syncOptions:
    - ServerSideApply=true
    - CreateNamespace=true
    {{- if .module.ignoreDifferences }}
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
{{- define "keelson.checkOverride" -}}
{{- $where := printf "advanced.modules.%s.appSpecOverride" .module -}}
{{- include "keelson.checkKeys" (dict "where" $where "obj" .override "allowed" (list "syncPolicy" "ignoreDifferences" "info" "revisionHistoryLimit" "source")) -}}
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
