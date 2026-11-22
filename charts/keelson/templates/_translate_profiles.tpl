{{/*
Translation: `profiles[]` → Kubeflow `Profile` resources (design 0001 §5.2).
Rendered in component mode by the `keelson-profiles` module (ADR 0004), not
as patches. The profile controller (dashboard module) creates each namespace
and the owner's RoleBinding and AuthorizationPolicy. Keelson adds contributor
and viewer access in KFAM's exact shape (kubeflow/dashboard v2.0.1,
components/access-management/kfam/bindings.go), so the dashboard lists it and
"Manage contributors" can remove it (ArgoCD selfHeal then restores it: git wins).
*/}}

{{/*
KFAM constants at the pinned dashboard version. Upstream params.env:
applications/dashboard/upstream/profile-controller/overlays/kubeflow/params.env
(USERID_HEADER, USERID_PREFIX, *_PRINCIPAL). Check them at every upstream bump.
*/}}
{{- define "keelson.profiles.kfam" -}}
userIdHeader: kubeflow-userid
userIdPrefix: ""
principals:
  - cluster.local/ns/istio-system/sa/istio-ingressgateway-service-account
  - cluster.local/ns/kubeflow/sa/ml-pipeline-ui
{{- end -}}

{{/*
keelson.profiles.bindingName: KFAM getBindingName for (dict "email" e "role" edit|view):
lower("User-" + email + "-ClusterRole-" + role), each run of [^a-zA-Z0-9] → "-".
*/}}
{{- define "keelson.profiles.bindingName" -}}
{{- printf "User-%s-ClusterRole-%s" (regexReplaceAll "[^a-zA-Z0-9]+" .email "-") .role | lower | regexReplaceAll "[^a-zA-Z0-9]+" "-" -}}
{{- end -}}

{{/* keelson.profiles.members: (dict "profile" $p) → YAML list of {email, role} for contributors and viewers. */}}
{{- define "keelson.profiles.members" -}}
{{- $out := list -}}
{{- range .profile.contributors -}}{{- $out = append $out (dict "email" . "role" "edit") -}}{{- end -}}
{{- range .profile.viewers -}}{{- $out = append $out (dict "email" . "role" "view") -}}{{- end -}}
{{- toYaml $out -}}
{{- end -}}

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
{{- $emails := dict (lower $p.owner) "owner" -}}
{{- $names := dict -}}
{{- range (include "keelson.profiles.members" (dict "profile" $p) | fromYamlArray) -}}
{{- $e := lower .email -}}
{{- if hasKey $emails $e -}}
{{- fail (printf "%s: %s is listed more than once (owner, contributors, viewers); give each person one role" $w .email) -}}
{{- end -}}
{{- $_ := set $emails $e .role -}}
{{- $n := include "keelson.profiles.bindingName" . -}}
{{- if hasKey $names $n -}}
{{- fail (printf "%s: %s and %s give the same KFAM binding name %q; KFAM can't tell them apart" $w (get $names $n) .email $n) -}}
{{- end -}}
{{- $_ := set $names $n .email -}}
{{- end -}}
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
{{- $ns := .name }}
{{- range (include "keelson.profiles.members" (dict "profile" .) | fromYamlArray) }}
{{- $n := include "keelson.profiles.bindingName" . }}
{{- $kfam := include "keelson.profiles.kfam" $ | fromYaml }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ $n }}
  namespace: {{ $ns | quote }}
  labels:
    app.kubernetes.io/part-of: keelson
    keelson.io/module: keelson-profiles
  annotations:
    argocd.argoproj.io/sync-wave: "1"
    # KFAM lists bindings by these two annotations.
    user: {{ .email | quote }}
    role: {{ .role }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kubeflow-{{ .role }}
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: {{ .email | quote }}
---
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  # KFAM deletes by name: same name as the RoleBinding.
  name: {{ $n }}
  namespace: {{ $ns | quote }}
  labels:
    app.kubernetes.io/part-of: keelson
    keelson.io/module: keelson-profiles
  annotations:
    argocd.argoproj.io/sync-wave: "1"
    user: {{ .email | quote }}
    role: {{ .role }}
spec:
  rules:
    - from:
        - source:
            principals:
              {{- toYaml $kfam.principals | nindent 14 }}
      when:
        - key: request.headers[{{ $kfam.userIdHeader }}]
          values:
            - {{ printf "%s%s" $kfam.userIdPrefix .email | quote }}
{{- end }}
{{- end }}
{{- end -}}
