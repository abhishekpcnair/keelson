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
Dex and Kind constants for group access (#66, #28). Upstream sources at 26.10.0:
- Dex issuer: common/oauth2-proxy/components/istio-external-auth/requestauthentication.dex-jwt.yaml
  (JWKS is <issuer>/keys, served in-cluster by the dex Service).
- Kind service-account issuers: common/oauth2-proxy/overlays/m2m-dex-and-kind/kustomization.yaml.
Check them at every upstream bump.
*/}}
{{- define "keelson.profiles.groupAuth" -}}
dex:
  issuer: http://dex.auth.svc.cluster.local:5556/dex
  jwksUri: http://dex.auth.svc.cluster.local:5556/dex/keys
kindServiceAccountIssuers:
  - issuer: https://kubernetes.default.svc.cluster.local
    jwksUri: http://cluster-jwks-proxy.istio-system.svc.cluster.local/openid/v1/jwks
  - issuer: https://kubernetes.default.svc
    jwksUri: http://cluster-jwks-proxy.istio-system.svc.cluster.local/openid/v1/jwks
{{- end -}}

{{/*
keelson.profiles.serviceAccountIssuers: auth.serviceAccountIssuers, or the two
Kind issuers when it is empty and platform is kind (#66 D3). YAML list.
*/}}
{{- define "keelson.profiles.serviceAccountIssuers" -}}
{{- $sa := (.Values.auth).serviceAccountIssuers | default list -}}
{{- if and (not $sa) (eq .Values.platform "kind") -}}
{{- $sa = (include "keelson.profiles.groupAuth" . | fromYaml).kindServiceAccountIssuers -}}
{{- end -}}
{{- toYaml $sa -}}
{{- end -}}

{{/*
keelson.profiles.groupBindingName: (dict "name" group "role" edit|view) →
keelson-group-<sanitized>-<hash8>-<role>. The hash of the exact group name keeps
names that sanitize the same apart (GitHub org:team and org-team).
*/}}
{{- define "keelson.profiles.groupBindingName" -}}
{{- $s := regexReplaceAll "[^a-z0-9]+" (lower .name) "-" | trimAll "-" | trunc 40 | trimSuffix "-" -}}
{{- $h := sha256sum .name | trunc 8 -}}
{{- if $s -}}
{{- printf "keelson-group-%s-%s-%s" $s $h .role -}}
{{- else -}}
{{- printf "keelson-group-%s-%s" $h .role -}}
{{- end -}}
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
{{- if and $p.groups (not (include "keelson.profiles.serviceAccountIssuers" $ | fromYamlArray)) -}}
{{- fail (printf "%s.groups: set auth.serviceAccountIssuers on platform %s (kubectl get --raw /.well-known/openid-configuration shows the issuer); without it m2m tokens to this namespace get 401" $w $.Values.platform) -}}
{{- end -}}
{{- $groups := dict -}}
{{- range $j, $g := $p.groups -}}
{{- if hasKey $groups $g.name -}}
{{- fail (printf "%s.groups[%d]: group %q is listed more than once; give each group one role" $w $j $g.name) -}}
{{- end -}}
{{- $_ := set $groups $g.name $j -}}
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
{{- $kfam := include "keelson.profiles.kfam" $ | fromYaml }}
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
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ $n }}
  namespace: {{ $ns }}
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
  namespace: {{ $ns }}
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
{{- with .groups }}
{{- include "keelson.profiles.groupResources" (dict "root" $ "namespace" $ns "groups" .) }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
keelson.profiles.groupResources: group access for one profile namespace (#66,
option a from #28). Call with (dict "root" $ "namespace" ns "groups" list).
Rendered only for a profile with groups: a namespace RequestAuthentication
rejects tokens from issuers it does not list (#66 D2).
- A RoleBinding for each group: Kubernetes RBAC, and Workspaces (GROUPS_HEADER).
- RequestAuthentication: the sidecars verify the Dex JWT, so request.auth.claims
  holds its groups. It also lists the service-account issuers, or m2m tokens get 401.
- AuthorizationPolicy: ALLOW for each group. ALLOW policies combine with OR, so
  this adds to the profile controller's ns-owner-access-istio.
KFAM and the dashboard do not read any of these (#28).
*/}}
{{- define "keelson.profiles.groupResources" -}}
{{- $ga := include "keelson.profiles.groupAuth" .root | fromYaml -}}
{{- $sa := include "keelson.profiles.serviceAccountIssuers" .root | fromYamlArray -}}
{{- $ns := .namespace -}}
{{- range .groups }}
{{- $role := .role | default "edit" }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ include "keelson.profiles.groupBindingName" (dict "name" .name "role" $role) }}
  namespace: {{ $ns }}
  labels:
    app.kubernetes.io/part-of: keelson
    keelson.io/module: keelson-profiles
  annotations:
    argocd.argoproj.io/sync-wave: "1"
    keelson.io/group: {{ .name | quote }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kubeflow-{{ $role }}
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: {{ .name | quote }}
{{- end }}
---
apiVersion: security.istio.io/v1beta1
kind: RequestAuthentication
metadata:
  name: keelson-groups
  namespace: {{ $ns }}
  labels:
    app.kubernetes.io/part-of: keelson
    keelson.io/module: keelson-profiles
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  # No selector: every workload in the namespace.
  jwtRules:
    - issuer: {{ $ga.dex.issuer | quote }}
      jwksUri: {{ $ga.dex.jwksUri | quote }}
      forwardOriginalToken: true
{{- range $sa }}
    - issuer: {{ .issuer | quote }}
{{- with .jwksUri }}
      jwksUri: {{ . | quote }}
{{- end }}
      forwardOriginalToken: true
{{- end }}
---
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: keelson-groups
  namespace: {{ $ns }}
  labels:
    app.kubernetes.io/part-of: keelson
    keelson.io/module: keelson-profiles
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  action: ALLOW
  rules:
{{- range .groups }}
    - from:
        - source:
            requestPrincipals:
              - {{ printf "%s/*" $ga.dex.issuer | quote }}
      when:
        - key: request.auth.claims[groups]
          values:
            - {{ .name | quote }}
{{- end }}
{{- end -}}
