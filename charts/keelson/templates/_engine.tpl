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
{{- if not (and (kindIs "string" $m.namespace) $m.namespace) -}}
{{- fail (printf "%s: namespace must be a non-empty string" $path) -}}
{{- end -}}
{{- if not (kindIs "map" $m.source) -}}
{{- fail (printf "%s: source must be a map" $path) -}}
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
  retry:
    limit: 10
    backoff:
      duration: 10s
      factor: 2
      maxDuration: 5m
{{- end -}}


{{/*
keelson.checkOverride: appSpecOverride is an allow-list, so new ArgoCD spec
fields (for example sourceHydrator) are rejected by default.
Top level: syncPolicy, ignoreDifferences, info, revisionHistoryLimit, source.
Inside source: path, kustomize, directory. kustomize.images and inline patches
that set an image are rejected (hard rule 2). Call with (dict "module" $name "override" $o).
*/}}
{{- define "keelson.checkOverride" -}}
{{- $o := .override -}}
{{- $where := printf "advanced.modules.%s.appSpecOverride" .module -}}
{{- $top := list "syncPolicy" "ignoreDifferences" "info" "revisionHistoryLimit" "source" -}}
{{- range $k := keys $o | sortAlpha -}}
{{- if not (has $k $top) -}}
{{- fail (printf "%s.%s: not allowed (allowed: %s)" $where $k (join ", " $top)) -}}
{{- end -}}
{{- end -}}
{{- if hasKey $o "source" -}}
{{- if not (kindIs "map" $o.source) -}}
{{- fail (printf "%s.source: must be a map" $where) -}}
{{- end -}}
{{- $src := list "path" "kustomize" "directory" -}}
{{- range $k := keys $o.source | sortAlpha -}}
{{- if not (has $k $src) -}}
{{- fail (printf "%s.source.%s: not allowed (allowed: %s)" $where $k (join ", " $src)) -}}
{{- end -}}
{{- end -}}
{{- $kz := $o.source.kustomize -}}
{{- if and (hasKey $o.source "kustomize") (not (kindIs "map" $kz)) -}}
{{- fail (printf "%s.source.kustomize: must be a map" $where) -}}
{{- end -}}
{{- if hasKey ($kz | default dict) "images" -}}
{{- fail (printf "%s.source.kustomize.images: not allowed (no image overrides, hard rule 2)" $where) -}}
{{- end -}}
{{- range ($kz | default dict).patches -}}
{{- if and (kindIs "map" .) (contains "image:" (toString .patch)) -}}
{{- fail (printf "%s.source.kustomize.patches: a patch may not set an image (hard rule 2)" $where) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
