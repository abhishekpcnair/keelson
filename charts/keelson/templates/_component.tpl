{{/*
Component mode (ADR 0004). A component Application renders this chart with
`component: <name>` plus a copy of only the values keys that component needs.
The chart then renders that component's resources and nothing else.
*/}}

{{/*
keelson.component.check: fail unless `component` names a registered
`source.type: keelson` module and no parent-only key is set. The second
check rejects `component` set on a parent release.
*/}}
{{- define "keelson.component.check" -}}
{{- $mod := dict -}}
{{- $known := list -}}
{{- range $path, $_ := .Files.Glob "modules/*.yaml" -}}
{{- $m := $.Files.Get $path | fromYaml -}}
{{- if eq ($m.source).type "keelson" -}}
{{- $known = append $known $m.source.component -}}
{{- if eq $m.source.component $.Values.component -}}{{- $mod = $m -}}{{- end -}}
{{- end -}}
{{- end -}}
{{- if not $mod -}}
{{- fail (printf "component %q: unknown component (known: %s). It is internal; do not set it" .Values.component (join ", " ($known | sortAlpha))) -}}
{{- end -}}
{{- /* Parent-only keys default to empty; the engine never copies them into valuesObject. */ -}}
{{- $parent := dict "modules" .Values.modules "advanced.modules" (.Values.advanced).modules "domain" .Values.domain "argocd.extraSourceRepos" .Values.argocd.extraSourceRepos -}}
{{- range $k := keys $parent | sortAlpha -}}
{{- if get $parent $k -}}
{{- fail (printf "component %q: %s is set, so this looks like a parent release. `component` is internal; only the engine sets it (ADR 0004)" $.Values.component $k) -}}
{{- end -}}
{{- end -}}
{{- end -}}
