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
keelson.checkOverride: fail if an appSpecOverride touches a field that the
hard rules and the AppProject allowlist depend on. Call with (dict "module" $name "override" $o).
*/}}
{{- define "keelson.checkOverride" -}}
{{- $o := .override -}}
{{- $where := printf "advanced.modules.%s.appSpecOverride" .module -}}
{{- range $f := list "project" "sources" -}}
{{- if hasKey $o $f -}}{{- fail (printf "%s.%s: not allowed (pinned source and AppProject are fixed)" $where $f) -}}{{- end -}}
{{- end -}}
{{- range $f := list "repoURL" "targetRevision" -}}
{{- if hasKey ($o.source | default dict) $f -}}{{- fail (printf "%s.source.%s: not allowed (pinned source and AppProject are fixed)" $where $f) -}}{{- end -}}
{{- end -}}
{{- if hasKey ($o.destination | default dict) "server" -}}{{- fail (printf "%s.destination.server: not allowed (use argocd.destinationServer)" $where) -}}{{- end -}}
{{- end -}}
