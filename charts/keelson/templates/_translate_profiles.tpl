{{/*
Translation: `profiles[]` → Kubeflow `Profile` resources (design 0001 §5.2).
Rendered in component mode by the `keelson-profiles` module (ADR 0004), not
as patches. The profile controller (dashboard module) creates each namespace
and the owner's RoleBinding and AuthorizationPolicy.
*/}}

{{/*
keelson.profiles.check: what the schema can't express. Runs in both render
modes, so a bad profile fails at `helm install`, not at sync time.
*/}}
{{- define "keelson.profiles.check" -}}
{{- $seen := dict -}}
{{- /* argocd.namespace is a parent-only value: the component render sees the default, so the parent render checks it. */ -}}
{{- $reserved := list "kubeflow" "istio-system" "auth" "oauth2-proxy" "cert-manager" -}}
{{- if not .Values.component -}}{{- $reserved = append $reserved .Values.argocd.namespace -}}{{- end -}}
{{- range $i, $p := .Values.profiles -}}
{{- $w := printf "profiles[%d]" $i -}}
{{- if hasKey $p "groups" -}}
{{- fail (printf "%s.groups: group → profile mapping is not supported yet; see https://github.com/abhishekpcnair/keelson/issues/28" $w) -}}
{{- end -}}
{{- if or (has $p.name $reserved) (hasPrefix "kube-" $p.name) -}}
{{- fail (printf "%s.name: %q is a system namespace" $w $p.name) -}}
{{- end -}}
{{- if hasKey $seen $p.name -}}
{{- fail (printf "%s.name: %q is already used by profiles[%d]" $w $p.name (get $seen $p.name)) -}}
{{- end -}}
{{- $_ := set $seen $p.name $i -}}
{{- end -}}
{{- end -}}

{{/* keelson.profiles.resources: one Profile per profiles[] entry. */}}
{{- define "keelson.profiles.resources" -}}
{{- range .Values.profiles }}
---
apiVersion: kubeflow.org/v1
kind: Profile
metadata:
  name: {{ .name | quote }}
  labels:
    app.kubernetes.io/part-of: keelson
    keelson.io/module: keelson-profiles
  annotations:
    argocd.argoproj.io/sync-wave: "0"
    # Removing a profile from values must never delete its namespace or data.
    argocd.argoproj.io/sync-options: Prune=false
spec:
  owner:
    kind: User
    name: {{ .owner | quote }}
{{- end }}
{{- end -}}
